"""Tests del parser PURO del ICM oficial de Sitrack. Datos SINTÉTICOS (sin PII
real). Correr: python test_parser.py  (sin dependencias externas).

Estructura espejada de respuestas reales del endpoint get_ranking_data.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parser import (  # noqa: E402
    parsear_chofer, parsear_vehiculo, construir_doc_icm,
    _patente_de_scope, SEVERIDAD_ES, _tendencia_diaria,
)


def _chofer_raw(dni, nombre, score, sev, time_seg=36000, dist=1000.0,
                low=0, med=0, high=0, over=0, agg=0,
                urb=0.0, nourb=0.0):
    return {
        "scopeId": int(dni) % 1000000, "scope": nombre, "document": dni,
        "ownerId": 41629, "ownerName": "Vecchi",
        "time": time_seg, "timeOnUrban": 0, "timeOnNonUrban": 0,
        "distance": dist, "distanceOnUrban": 0, "distanceOnNonUrban": 0,
        "score": score, "scoreOnUrban": urb, "scoreOnNonUrban": nourb,
        "scoreOverspeedCount": over, "scoreAggressiveActivityCount": agg,
        "lowInfractionsCount": low, "mediumInfractionsCount": med,
        "highInfractionsCount": high, "severity": sev,
    }


def _wrap(items, overall_score=17.62, overall_dist=144756.0, overall_time=1492.1,
          low=185, med=123, high=141):
    return {
        "rankingItemsByScope": {str(i["scopeId"]): i for i in items},
        "overallScore": overall_score, "overallDistance": overall_dist,
        "overallTime": overall_time, "overallScoreSum": 2629.86,
        "lowInfractionsCount": low, "mediumInfractionsCount": med,
        "highInfractionsCount": high,
    }


def test_parsear_chofer_mapeo():
    item = _chofer_raw("36645855", "BAJENETA JULIAN ISMAEL", 53.48, "HIGH",
                       time_seg=124423, dist=3708.94, low=8, med=3, high=17,
                       over=8, agg=18, urb=8.58, nourb=69.94)
    c = parsear_chofer(item)
    assert c["dni"] == "36645855", c
    assert c["nombre"] == "BAJENETA JULIAN ISMAEL"
    assert c["icm"] == 53.48
    assert c["icm_urbano"] == 8.58 and c["icm_no_urbano"] == 69.94
    assert c["distancia_km"] == 3708.9, c["distancia_km"]
    # time en SEGUNDOS → horas: 124423/3600 = 34.6
    assert c["tiempo_h"] == 34.6, c["tiempo_h"]
    assert c["inf_leves"] == 8 and c["inf_medias"] == 3 and c["inf_altas"] == 17
    assert c["excesos_velocidad"] == 8 and c["conduccion_agresiva"] == 18
    assert c["severidad"] == "HIGH" and c["severidad_label"] == "Alto"


def test_severidad_labels():
    for k, v in SEVERIDAD_ES.items():
        c = parsear_chofer(_chofer_raw("1", "X", 0, k))
        assert c["severidad_label"] == v, (k, c["severidad_label"])


def test_parsear_vehiculo_patente():
    assert _patente_de_scope(" - AB493CP") == "AB493CP"
    assert _patente_de_scope("- ai162yt") == "AI162YT"
    assert _patente_de_scope("AB123CD") == "AB123CD"
    v = parsear_vehiculo({"scope": " - AB493CP", "score": 4.51,
                          "distance": 1801.98, "time": 79443, "severity": "LOW"})
    assert v["patente"] == "AB493CP", v
    assert v["icm"] == 4.51
    assert v["severidad_label"] == "Bajo"


def test_construir_doc_orden_peor_primero():
    items = [
        _chofer_raw("100", "BUENO", 2.0, "LOW"),
        _chofer_raw("200", "PESIMO", 53.0, "HIGH"),
        _chofer_raw("300", "SIN ACT", 0.0, "UNAVAILABLE_NO_ACTIVITY", time_seg=0, dist=0),
        _chofer_raw("400", "LIMPIO", 0.0, "NO"),
        _chofer_raw("500", "MEDIO", 20.0, "MEDIUM"),
    ]
    doc = construir_doc_icm(_wrap(items), None, "2026-05", "2026-05-01", "2026-05-22")
    orden = [c["nombre"] for c in doc["choferes"]]
    # HIGH → MEDIUM → LOW → NO → SIN ACTIVIDAD (al final)
    assert orden == ["PESIMO", "MEDIO", "BUENO", "LIMPIO", "SIN ACT"], orden
    assert doc["choferes_total"] == 5
    assert doc["choferes_activos"] == 4  # excluye SIN ACTIVIDAD
    assert doc["icm_general"] == 17.62
    assert doc["distancia_total_km"] == 144756.0
    assert doc["tiempo_total_h"] == 1492.1  # overallTime ya en horas
    assert doc["infracciones_altas"] == 141
    assert doc["fuente"] == "sitrack_icm_oficial"
    assert doc["periodo"] == "2026-05"


def test_construir_doc_con_vehiculos():
    drv = _wrap([_chofer_raw("100", "A", 5.0, "LOW")])
    hold = _wrap([
        {"scopeId": 1, "scope": " - AB111AA", "score": 30.0, "distance": 500.0,
         "time": 7200, "severity": "HIGH", "lowInfractionsCount": 1,
         "mediumInfractionsCount": 0, "highInfractionsCount": 5},
        {"scopeId": 2, "scope": " - AB222BB", "score": 1.0, "distance": 800.0,
         "time": 9000, "severity": "LOW"},
    ])
    doc = construir_doc_icm(drv, hold, "2026-05", "2026-05-01", "2026-05-22")
    assert len(doc["vehiculos"]) == 2
    # peor primero: AB111AA (HIGH) antes que AB222BB (LOW)
    assert doc["vehiculos"][0]["patente"] == "AB111AA"
    assert doc["vehiculos"][0]["inf_altas"] == 5
    assert doc["vehiculos"][1]["patente"] == "AB222BB"


def test_defensivo_campos_faltantes():
    # Item con campos faltantes / None no debe romper.
    c = parsear_chofer({"scope": "X", "document": "9"})
    assert c["icm"] == 0.0 and c["tiempo_h"] == 0.0 and c["inf_altas"] == 0
    assert c["severidad_label"] == "—"
    # Doc con ranking vacío.
    doc = construir_doc_icm({"rankingItemsByScope": {}}, None,
                            "2026-05", "2026-05-01", "2026-05-22")
    assert doc["choferes"] == [] and doc["choferes_activos"] == 0
    assert doc["icm_general"] == 0.0


def test_tendencia_diaria():
    raw = {
        "rankingItemsByScope": {},
        "rankingItemsByDay": {
            # desordenados a propósito para verificar el sort por fecha
            "1777680000000": {"scope": "2026-05-02", "score": 11.81,
                              "distance": 11494.6, "lowInfractionsCount": 10,
                              "mediumInfractionsCount": 10,
                              "highInfractionsCount": 10},
            "1777593600000": {"scope": "2026-05-01", "score": 26.14,
                              "distance": 18050.17, "lowInfractionsCount": 34,
                              "mediumInfractionsCount": 20,
                              "highInfractionsCount": 23},
            # día en curso sin actividad (Sitrack lo da en 0) → se excluye
            "1779408000000": {"scope": "2026-05-22", "score": 0, "distance": 0},
        },
    }
    t = _tendencia_diaria(raw)
    assert len(t) == 2, t  # el día sin actividad queda fuera
    assert t[0]["fecha"] == "2026-05-01", t  # ordenado ascendente
    assert t[0]["icm"] == 26.14 and t[0]["km"] == 18050.2
    assert t[0]["infracciones"] == 77, t[0]
    assert t[1]["fecha"] == "2026-05-02"
    # También sale dentro del doc completo.
    doc = construir_doc_icm(raw, None, "2026-05", "2026-05-01", "2026-05-22")
    assert len(doc["tendencia_diaria"]) == 2


def main():
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    fallos = 0
    for t in tests:
        try:
            t()
            print(f"  OK  {t.__name__}")
        except AssertionError as e:
            fallos += 1
            print(f"  FAIL {t.__name__}: {e}")
        except Exception as e:  # noqa: BLE001
            fallos += 1
            print(f"  ERR  {t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(tests) - fallos}/{len(tests)} OK")
    return 1 if fallos else 0


if __name__ == "__main__":
    raise SystemExit(main())
