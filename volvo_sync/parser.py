"""Parser PURO del historial de taller de Volvo Connect (GraphQL `pastServices`)
→ último SERVICE de mantenimiento por unidad. Sin I/O, testeable.

Alimenta `ULTIMO_SERVICE_KM` / `ULTIMO_SERVICE_FECHA` en VEHICULOS, que el módulo
de mantenimiento de la app YA usa para calcular el próximo service por km
(intervalo 50.000). Ver project_volvo_estado_fundacion / app_constants.AppMantenimiento.

DECISIÓN CLAVE (validada con datos reales de AB927WN, 68 visitas):
- `visitReason` NO sirve para distinguir service de reparación: el código "01"
  aparece en 22 visitas SIN service y "02" en 3 visitas CON service.
- La ÚLTIMA visita tampoco sirve: suele ser una reparación/repuesto POSTERIOR al
  service (ej. AB927WN: última visita 09-mar a 1.189.237 km fue "Falla de
  inyección", pero el último service real fue 13-feb a 1.178.204 km).
- El marcador ROBUSTO es la presencia de una operación cuyo `functionGroup` es de
  mantenimiento ("Servicio de mantenimiento, inspección básica, ..."). La
  descripción varía ("Servicio básico" / "Servicio anual"), por eso matcheamos el
  functionGroup, no la descripción.
"""
import re

# functionGroup/description que marca una operación de SERVICE de mantenimiento.
_MARCA_SERVICE = re.compile(r"servicio de mantenimiento|inspecci.n b.sica", re.I)


def es_visita_de_service(visita: dict) -> bool:
    """True si la visita incluyó al menos una operación de mantenimiento
    (service programado), no sólo reparaciones/repuestos."""
    for d in visita.get("serviceDetails") or []:
        txt = f"{d.get('functionGroup') or ''} {d.get('description') or ''}"
        if _MARCA_SERVICE.search(txt):
            return True
    return False


def parse_km(visita: dict):
    """`vehicle.mileage` viene como STRING (ej. "1178204"). Devuelve int o None."""
    v = (visita.get("vehicle") or {}).get("mileage")
    if v is None:
        return None
    digits = re.sub(r"[^\d]", "", str(v))
    return int(digits) if digits else None


def ultimo_service_programado(past_services: list) -> dict | None:
    """Del array `pastServices` (GraphQL), devuelve el ÚLTIMO service de
    mantenimiento:
        {"km": int, "fecha": "YYYY-MM-DD", "order_number": str|None,
         "engine_hours": <valor>|None}
    o None si la unidad no tiene ningún service de mantenimiento registrado.

    Ignora reparaciones, ventas de repuestos y notas de crédito (visitas sin
    operación de mantenimiento), y NO usa la última visita a secas.
    """
    candidatos = []
    for s in past_services or []:
        if not es_visita_de_service(s):
            continue
        km = parse_km(s)
        fecha = s.get("visitDate")
        if km is None or not fecha:
            continue
        candidatos.append({
            "km": km,
            "fecha": fecha,
            "order_number": s.get("orderNumber"),
            "engine_hours": s.get("engineHours"),
        })
    if not candidatos:
        return None
    # fecha ISO YYYY-MM-DD → orden lexicográfico = cronológico. Más reciente 1°.
    candidatos.sort(key=lambda c: c["fecha"], reverse=True)
    return candidatos[0]


def normalizar_servicios(past_services: list) -> list:
    """Normaliza TODO el historial de taller (services + reparaciones) para
    persistir en Firestore y mostrar en la app. Cada visita:
        {fecha, km, taller, order, es_service, operaciones:[{codigo,desc,grupo,cant}]}
    Ordenado por fecha desc. Cap defensivo de operaciones/visitas para no pasar
    el límite de 1 MB por documento de Firestore.
    """
    out = []
    for s in past_services or []:
        fecha = s.get("visitDate")
        if not fecha:
            continue
        ops = []
        for d in (s.get("serviceDetails") or [])[:40]:
            ops.append({
                "codigo": (d.get("operationCode") or "").strip(),
                "desc": (d.get("description") or "").strip(),
                "grupo": (d.get("functionGroup") or "").strip(),
                "cant": d.get("quantity"),
            })
        dealer = s.get("dealer") or {}
        out.append({
            "fecha": fecha,
            "km": parse_km(s),
            "taller": (dealer.get("name") or "").strip(),
            "order": (s.get("orderNumber") or "").strip(),
            "es_service": es_visita_de_service(s),
            "operaciones": ops,
        })
    out.sort(key=lambda x: x["fecha"], reverse=True)
    return out[:150]
