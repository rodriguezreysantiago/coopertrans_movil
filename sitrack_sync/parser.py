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


def construir_doc_icm(raw_driver: dict, raw_holder: dict | None,
                      periodo: str, desde: str, hasta: str,
                      alcance: str = "mensual") -> dict:
    """Arma el doc `ICM_OFICIAL/{periodo}` desde las respuestas crudas del
    endpoint por chofer (raw_driver, obligatorio) y por vehículo (raw_holder,
    opcional). `periodo` ej. '2026-05'. Devuelve dict listo para Firestore
    (sin serverTimestamp — eso lo agrega el caller)."""
    items_d = list((raw_driver or {}).get("rankingItemsByScope", {}).values())
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
        "fuente": "sitrack_icm_oficial",
    }
