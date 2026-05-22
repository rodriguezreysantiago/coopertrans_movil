"""Tests del parser PURO del historial de taller. Fixture = datos REALES
capturados de AB927WN (Volvo Connect, 2026-05-22). Corre con pytest o directo:
    python test_parser.py
"""
from parser import (
    ultimo_service_programado,
    es_visita_de_service,
    parse_km,
)

# Datos reales de AB927WN (las 4 visitas más recientes). Las 3 primeras son
# reparaciones/repuestos POSTERIORES al último service real (13-feb).
FIXTURE_AB927WN = [
    {
        "visitDate": "2026-03-09", "visitReason": "01",
        "vehicle": {"mileage": "1189237"}, "engineHours": None,
        "serviceDetails": [
            {"functionGroup": "Pasador, perno sin roscar, remache, clavo", "description": "Falla de inyección"},
            {"functionGroup": "Bomba de combustible y filtro", "description": "FILTRO DE COMBUSTI"},
        ],
    },
    {
        "visitDate": "2026-02-26", "visitReason": "01",
        "vehicle": {"mileage": "1184270"}, "engineHours": None,
        "serviceDetails": [],
    },
    {
        "visitDate": "2026-02-25", "visitReason": "01",
        "vehicle": {"mileage": "1184107"}, "engineHours": None,
        "serviceDetails": [
            {"functionGroup": "Pasador, perno sin roscar, remache, clavo", "description": "Falla de urea"},
        ],
    },
    {
        "visitDate": "2026-02-13", "visitReason": "02",
        "vehicle": {"mileage": "1178204"}, "engineHours": None,
        "serviceDetails": [
            {"functionGroup": "Servicio de mantenimiento, inspección básica, camiones", "description": "Servicio anual. En lo referente a la lub"},
            {"functionGroup": "Filtro de aceite", "description": "FILTRO DE ACEITE"},
        ],
    },
    {  # service más viejo, no debe ganar
        "visitDate": "2025-08-04", "visitReason": "02",
        "vehicle": {"mileage": "1090000"}, "engineHours": None,
        "serviceDetails": [
            {"functionGroup": "Servicio de mantenimiento, inspección básica, camiones", "description": "Servicio básico"},
        ],
    },
]


def test_elige_ultimo_service_no_la_ultima_visita():
    r = ultimo_service_programado(FIXTURE_AB927WN)
    # El último service real es 13-feb / 1.178.204 — NO la última visita
    # (09-mar / 1.189.237, que fue una reparación).
    assert r is not None
    assert r["km"] == 1178204
    assert r["fecha"] == "2026-02-13"


def test_visit_reason_no_decide():
    # 13-feb tiene visitReason "02" (no "01") y aun así es el service correcto.
    r = ultimo_service_programado(FIXTURE_AB927WN)
    assert r["fecha"] == "2026-02-13"


def test_es_visita_de_service_por_functiongroup():
    # Matchea por functionGroup aunque la descripción diga "anual", no "básico".
    serv = FIXTURE_AB927WN[3]
    rep = FIXTURE_AB927WN[0]
    assert es_visita_de_service(serv) is True
    assert es_visita_de_service(rep) is False


def test_visita_sin_operaciones_no_es_service():
    assert es_visita_de_service(FIXTURE_AB927WN[1]) is False


def test_parse_km_string():
    assert parse_km({"vehicle": {"mileage": "1178204"}}) == 1178204
    assert parse_km({"vehicle": {"mileage": "1.178.204"}}) == 1178204  # defensivo
    assert parse_km({"vehicle": {"mileage": None}}) is None
    assert parse_km({"vehicle": {}}) is None


def test_sin_services_devuelve_none():
    solo_reparaciones = [FIXTURE_AB927WN[0], FIXTURE_AB927WN[1], FIXTURE_AB927WN[2]]
    assert ultimo_service_programado(solo_reparaciones) is None


def test_lista_vacia():
    assert ultimo_service_programado([]) is None
    assert ultimo_service_programado(None) is None


if __name__ == "__main__":
    fns = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    fallos = 0
    for fn in fns:
        try:
            fn()
            print(f"  ok  {fn.__name__}")
        except AssertionError as e:
            fallos += 1
            print(f"FAIL  {fn.__name__}: {e}")
    print(f"\n{len(fns) - fallos}/{len(fns)} tests OK")
    raise SystemExit(1 if fallos else 0)
