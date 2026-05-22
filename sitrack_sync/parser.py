"""Parser PURO del ICM oficial de Sitrack (endpoint `get_ranking_data` del
portal site5) → doc `ICM_OFICIAL/{periodo}` en Firestore. Sin I/O, testeable.

Este es el ICM que audita YPF: lo calcula Sitrack con su cartografía de
segmento vial (urbano / no-urbano) — dato que nosotros NO tenemos. Por eso
ingerimos SU número en vez de recalcular CESVI nosotros.

OJO con la escala: el ICM de Sitrack es **al revés** del CESVI 0-100 que
teníamos. Acá **MÁS BAJO = MEJOR** (0 = sin infracciones; la flota Vecchi
ronda ~16-18; un chofer malo supera 50). La severidad la da Sitrack
directamente (NO / LOW / MEDIUM / HIGH / UNAVAILABLE_NO_ACTIVITY).

Estructura del item crudo (rankingItemsByScope[scopeId]):
  - scope: nombre del chofer ("APELLIDO NOMBRE") o " - PATENTE" (vehículo)
  - document: DNI del chofer (clave de match con EMPLEADOS)
  - time: SEGUNDOS conducidos · distance: km (float)
  - score / scoreOnUrban / scoreOnNonUrban: el ICM (más bajo = mejor)
  - low/medium/highInfractionsCount · scoreOverspeedCount ·
    scoreAggressiveActivityCount · severity
Top-level: overallScore (ICM flota), overallDistance (km),
  overallTime (HORAS), low/medium/highInfractionsCount.
"""

import datetime as dt

# Sitrack `severity` → etiqueta en español para la UI.
SEVERIDAD_ES = {
    "NO": "Sin infracciones",
    "LOW": "Bajo",
    "MEDIUM": "Medio",
    "HIGH": "Alto",
    "UNAVAILABLE_NO_ACTIVITY": "Sin actividad",
}

# Orden de severidad para ranking (peor primero; sin actividad al final).
_ORDEN_SEVERIDAD = {"HIGH": 0, "MEDIUM": 1, "LOW": 2, "NO": 3,
                    "UNAVAILABLE_NO_ACTIVITY": 9}

# Entradas del ranking de Sitrack que NO son choferes y hay que ocultar:
# contactos/sistema que no se pueden borrar del portal (vienen como "scope"
# sin DNI). BUSCIO GUILLERMO es el contacto admin de Sitrack
# (guillermo.buscio@sitrack.com, atado a reglas → no se puede deshabilitar).
_NO_CHOFERES_NOMBRES = {
    "BUSCIO GUILLERMO",
    "TALLER TALLER",
    "LAVADERO GOMERIA",
}


def _es_no_chofer(item: dict) -> bool:
    """True si el item NO es un chofer real (contacto admin, taller, lavadero,
    unidad-dispositivo de Sitrack). Se excluye del doc para que no ensucie el
    ranking ni los conteos. Criterio:
      - nombre en la lista negra explícita, o
      - sin DNI + nombre de unidad-dispositivo ("Vecchi Ariel 012E..."), o
      - sin DNI + sin actividad (entrada de sistema, no una persona).
    Un chofer real SIN DNI cargado pero CON actividad NO se filtra (se ve
    grisado para que se note y se le cargue el DNI en Sitrack)."""
    nombre = (item.get("scope") or "").strip().upper()
    dni = (item.get("document") or "").strip()
    sev = (item.get("severity") or "").strip().upper()
    if nombre in _NO_CHOFERES_NOMBRES:
        return True
    if not dni and nombre.startswith("VECCHI ARIEL "):
        return True
    if not dni and sev == "UNAVAILABLE_NO_ACTIVITY":
        return True
    return False


def _num(v, default=0.0):
    """Coerce defensivo a float (los campos vienen como number, pero por las
    dudas toleramos string/None)."""
    if v is None:
        return default
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _r(v, n=2):
    """Redondeo a n decimales."""
    return round(_num(v), n)


def _patente_de_scope(scope: str) -> str:
    """El `scope` de un vehículo viene como ' - AB493CP' (con guión y espacios).
    Devuelve la patente limpia en mayúsculas."""
    s = (scope or "").strip()
    if s.startswith("-"):
        s = s[1:].strip()
    return s.upper()


def parsear_chofer(item: dict) -> dict:
    """Item crudo (scope=scopeDriver) → dict del chofer para Firestore."""
    sev = (item.get("severity") or "").strip().upper()
    return {
        "dni": (item.get("document") or "").strip(),
        "nombre": (item.get("scope") or "").strip(),
        "icm": _r(item.get("score")),
        "icm_urbano": _r(item.get("scoreOnUrban")),
        "icm_no_urbano": _r(item.get("scoreOnNonUrban")),
        "distancia_km": _r(item.get("distance"), 1),
        "tiempo_h": _r(_num(item.get("time")) / 3600.0, 1),  # time en SEGUNDOS
        "inf_leves": int(_num(item.get("lowInfractionsCount"))),
        "inf_medias": int(_num(item.get("mediumInfractionsCount"))),
        "inf_altas": int(_num(item.get("highInfractionsCount"))),
        "excesos_velocidad": int(_num(item.get("scoreOverspeedCount"))),
        "conduccion_agresiva": int(_num(item.get("scoreAggressiveActivityCount"))),
        "severidad": sev,
        "severidad_label": SEVERIDAD_ES.get(sev, sev or "—"),
    }


def parsear_vehiculo(item: dict) -> dict:
    """Item crudo (scope=scopeHolder) → dict del vehículo para Firestore."""
    sev = (item.get("severity") or "").strip().upper()
    return {
        "patente": _patente_de_scope(item.get("scope")),
        "icm": _r(item.get("score")),
        "icm_urbano": _r(item.get("scoreOnUrban")),
        "icm_no_urbano": _r(item.get("scoreOnNonUrban")),
        "distancia_km": _r(item.get("distance"), 1),
        "tiempo_h": _r(_num(item.get("time")) / 3600.0, 1),
        "inf_leves": int(_num(item.get("lowInfractionsCount"))),
        "inf_medias": int(_num(item.get("mediumInfractionsCount"))),
        "inf_altas": int(_num(item.get("highInfractionsCount"))),
        "severidad": sev,
        "severidad_label": SEVERIDAD_ES.get(sev, sev or "—"),
    }


def _ordenar_peor_primero(filas: list, clave_sev="severidad", clave_icm="icm"):
    """Ordena peor→mejor: por severidad (HIGH→NO), luego ICM desc. Los
    'sin actividad' quedan al final."""
    filas.sort(key=lambda f: (
        _ORDEN_SEVERIDAD.get(f.get(clave_sev), 8),
        -_num(f.get(clave_icm)),
    ))
    return filas


# ── Rangos de fecha (puros, testeables) ──────────────────────────────────
# `hoy` es un date en hora Argentina (UTC-3). La semana es lunes→domingo.

def _rango_semana_actual(hoy):
    """(desde, hasta, id) de la semana EN CURSO: lunes → hoy. id = lunes."""
    lunes = hoy - dt.timedelta(days=hoy.weekday())  # weekday(): lun=0
    return lunes.isoformat(), hoy.isoformat(), lunes.isoformat()


def _rango_semana_anterior(hoy):
    """(desde, hasta, id) de la semana ANTERIOR COMPLETA (lunes → domingo).
    id = lunes de esa semana. Se congela desde el martes, cuando Sitrack ya
    cerró el domingo previo."""
    lunes_actual = hoy - dt.timedelta(days=hoy.weekday())
    lunes_prev = lunes_actual - dt.timedelta(days=7)
    domingo_prev = lunes_actual - dt.timedelta(days=1)
    return lunes_prev.isoformat(), domingo_prev.isoformat(), lunes_prev.isoformat()


def _rango_mes_anterior(hoy):
    """(desde, hasta, periodo) del mes ANTERIOR completo. periodo = YYYY-MM."""
    primero_actual = hoy.replace(day=1)
    ultimo_prev = primero_actual - dt.timedelta(days=1)
    primero_prev = ultimo_prev.replace(day=1)
    return (primero_prev.isoformat(), ultimo_prev.isoformat(),
            primero_prev.strftime("%Y-%m"))


def _tendencia_diaria(raw: dict | None) -> list:
    """ICM de la flota DÍA por DÍA (`rankingItemsByDay` del endpoint), para el
    gráfico de tendencia de la app. Cada item es el agregado de TODA la flota
    ese día (no por chofer). Excluimos días sin actividad (distancia 0 — entre
    ellos el día en curso, que Sitrack todavía no cerró y vendría en 0)."""
    by_day = (raw or {}).get("rankingItemsByDay", {}) or {}
    filas = []
    for v in by_day.values():
        dist = _num(v.get("distance"))
        if dist <= 0:
            continue
        filas.append({
            "fecha": (v.get("scope") or "").strip(),  # "YYYY-MM-DD"
            "icm": _r(v.get("score")),
            "km": _r(dist, 1),
            "infracciones": int(_num(v.get("lowInfractionsCount")))
            + int(_num(v.get("mediumInfractionsCount")))
            + int(_num(v.get("highInfractionsCount"))),
        })
    filas.sort(key=lambda f: f["fecha"])
    return filas


def construir_doc_icm(raw_driver: dict, raw_holder: dict | None,
                      periodo: str, desde: str, hasta: str,
                      alcance: str = "mensual") -> dict:
    """Arma el doc `ICM_OFICIAL/{periodo}` desde las respuestas crudas del
    endpoint por chofer (raw_driver, obligatorio) y por vehículo (raw_holder,
    opcional). `periodo` ej. '2026-05'. Devuelve dict listo para Firestore
    (sin serverTimestamp — eso lo agrega el caller)."""
    items_d = [i for i in (raw_driver or {}).get("rankingItemsByScope", {}).values()
               if not _es_no_chofer(i)]
    choferes = _ordenar_peor_primero([parsear_chofer(i) for i in items_d])

    vehiculos = []
    if raw_holder:
        items_v = list(raw_holder.get("rankingItemsByScope", {}).values())
        vehiculos = _ordenar_peor_primero([parsear_vehiculo(i) for i in items_v])

    activos = [c for c in choferes if c["severidad"] != "UNAVAILABLE_NO_ACTIVITY"]

    return {
        "periodo": periodo,
        "alcance": alcance,
        "fecha_desde": desde,
        "fecha_hasta": hasta,
        # ICM flota (overallScore) — MÁS BAJO = MEJOR.
        "icm_general": _r(raw_driver.get("overallScore")),
        "distancia_total_km": _r(raw_driver.get("overallDistance"), 1),
        "tiempo_total_h": _r(raw_driver.get("overallTime"), 1),  # ya en HORAS
        "infracciones_leves": int(_num(raw_driver.get("lowInfractionsCount"))),
        "infracciones_medias": int(_num(raw_driver.get("mediumInfractionsCount"))),
        "infracciones_altas": int(_num(raw_driver.get("highInfractionsCount"))),
        "choferes_total": len(choferes),
        "choferes_activos": len(activos),
        "choferes": choferes,
        "vehiculos": vehiculos,
        # ICM de la flota día por día (para el gráfico de tendencia de la app).
        "tendencia_diaria": _tendencia_diaria(raw_driver),
        "fuente": "sitrack_icm_oficial",
    }
