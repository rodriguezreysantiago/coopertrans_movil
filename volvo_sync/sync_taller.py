"""Sincroniza el ÚLTIMO SERVICE (km + fecha) de cada unidad desde el historial
de taller de Volvo Connect → VEHICULOS en Firestore. Lo usa el módulo de
mantenimiento de la app (intervalo 50.000 km).

Flujo:
  1. Login Playwright (claves.json) — sesión reusable (storage_state.json).
  2. /assets → lista de la flota (id ↔ patente ↔ VIN) vía multidomainservices.
  3. Por unidad: /workshop/vehicle/{id} → intercepta ecs-workshophistory →
     parser.ultimo_service_programado (último service de mantenimiento, no la
     última visita ni por visitReason — ver parser.py).
  4. Escribe ULTIMO_SERVICE_KM / ULTIMO_SERVICE_FECHA en VEHICULOS/{patente}.

SEGURIDAD: dry-run por defecto. Solo escribe con --commit. La contraseña vive
en claves.json (gitignoreado), el script la lee — nadie la tipea.

Uso:
  python sync_taller.py                 # dry-run, toda la flota
  python sync_taller.py --solo AB421DP  # dry-run, una unidad
  python sync_taller.py --commit        # escribe Firestore (toda la flota)
  python sync_taller.py --solo AB421DP --commit
"""
import argparse
import json
import os
import sys

import firebase_admin
from firebase_admin import credentials, firestore
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parser import ultimo_service_programado, normalizar_servicios  # noqa: E402

_DIR = os.path.dirname(os.path.abspath(__file__))
_SAK = os.path.join(_DIR, "..", "serviceAccountKey.json")
_CLAVES = os.path.join(_DIR, "claves.json")
_STATE = os.path.join(_DIR, "storage_state.json")
BASE = "https://volvoconnect.com"

# Historial de taller: lo pedimos con fetch DIRECTO al graphql (no esperando
# que la SPA de /workshop lo dispare). Bajo la Scheduled Task esa SPA no
# renderiza y el graphql nunca sale -> timeout por unidad (confirmado
# 2026-05-22). El fetch directo no depende del render — mismo enfoque que
# sitrack_sync, que nunca falla. Endpoint + query capturados del request real.
# Auth: reusamos el Bearer del request de /assets (multidomainservices), que SI
# sale bajo la tarea.
ECS_WORKSHOP_URL = "https://api.eu.vgcs.volvo.com/ecs-workshophistory/graphql"
FETCH_PAST_SERVICES_QUERY = (
    "query FetchPastServices($input: PastServicesInput!, $languageId: ID!, "
    "$vehicleId: ID, $measurementSystem: MeasurementSystem) {\n"
    "  pastServices(input: $input, languageId: $languageId, "
    "vehicleId: $vehicleId, measurementSystem: $measurementSystem) {\n"
    "    ...PastServiceFields\n  }\n}\n\n"
    "fragment PastServiceFields on PastService {\n"
    "  serviceId\n  orderNumber\n  visitDate\n  visitReason\n"
    "  dealer { id name city countryCode }\n"
    "  vehicle { chassisId mileage }\n"
    "  credit\n  source\n  engineHours\n  description\n"
    "  serviceDetails {\n    sortOrder\n    lineNumber\n    type\n"
    "    operationCode\n    description\n    quantity\n    functionGroup\n"
    "    paymentType\n    unit\n  }\n}"
)


def _db():
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    return firestore.client()


def _login(page, cfg):
    """Asegura sesión iniciada. Devuelve True si quedó logueado."""
    page.goto(BASE + "/", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(3000)
    if "/login" in page.url:
        page.wait_for_selector("#username", timeout=25000)
        page.fill("#username", cfg["usuario"])
        page.fill("#password", cfg["password"])
        page.click("button[type=submit]")
        try:
            page.wait_for_url(lambda u: "/login" not in u, timeout=35000)
        except Exception:
            return False
        page.wait_for_timeout(4000)
    return "/login" not in page.url


def _fetch_flota(page):
    """Navega a /assets y devuelve `(vehicles, auth)`:
      - vehicles: [{id, registrationNumber, vin}, ...] de multidomainservices.
      - auth: el header Authorization (Bearer) de ese request — lo REUSAMOS
        para los fetch directos del taller (mismo token sirve para los dos
        endpoints de api.eu.vgcs.volvo.com).

    Robusto a PCs lentas: pollea hasta ~45s y corta apenas captura `vehicles`.
    Lee `r.text()` FUERA del handler de 'response' (llamarlo dentro del handler
    sync de Playwright puede deadlockear)."""
    responses = []

    def on_resp(r):
        if r.request.method == "POST" and "multidomainservices/graphql" in r.url:
            responses.append(r)

    page.on("response", on_resp)
    page.goto(BASE + "/assets", wait_until="domcontentloaded", timeout=60000)
    vehicles = []
    auth = ""
    seen = 0
    for _ in range(45):  # hasta ~45s; corta apenas encuentra vehicles
        if vehicles:
            break
        page.wait_for_timeout(1000)
        while seen < len(responses):
            r = responses[seen]
            seen += 1
            try:
                body = r.text()
            except Exception:
                continue
            if '"vehicles"' in body and len(body) > 500:
                try:
                    data = json.loads(body).get("data") or {}
                    if data.get("vehicles"):
                        vehicles = data["vehicles"]
                        auth = r.request.headers.get("authorization", "")
                        break
                except Exception:
                    pass
    page.remove_listener("response", on_resp)
    return vehicles, auth


def _fetch_taller(page, vehicle_id, auth):
    """Pide el historial de taller con fetch DIRECTO al graphql (no navegando a
    la SPA de /workshop, que no renderiza bajo la tarea). Corre el fetch DENTRO
    de la página (origin volvoconnect.com) para que CORS/referer sean los que el
    server espera; reusa el Bearer capturado en _fetch_flota."""
    if not auth:
        return []
    body = {
        "query": FETCH_PAST_SERVICES_QUERY,
        "variables": {
            "input": {
                "dateFrom": "1970-01-01",
                "dateTo": "2086-04-20",
                "vehicleId": vehicle_id,
            },
            "languageId": "es-ES",
            "measurementSystem": "METRIC",
        },
    }
    url = f"{ECS_WORKSHOP_URL}?platformidentifier={vehicle_id}"
    try:
        result = page.evaluate(
            """async ([u, b, auth]) => {
                // SIN credentials:'include' — el API de Volvo autentica solo con
                // el Bearer (token-only, cross-origin); mandar cookies rompe el
                // preflight CORS ("Failed to fetch"). El browser agrega solo
                // origin/referer/user-agent (lo que el server espera).
                const r = await fetch(u, {
                    method: 'POST',
                    headers: {
                        'authorization': auth,
                        'content-type': 'application/json',
                        'accept': 'application/json',
                    },
                    body: JSON.stringify(b),
                });
                if (!r.ok) return { __status: r.status };
                return await r.json();
            }""",
            [url, body, auth],
        )
        if isinstance(result, dict) and result.get("__status"):
            print(f"    (taller HTTP {result['__status']})")
            return []
        return ((result or {}).get("data") or {}).get("pastServices") or []
    except Exception as e:
        print(f"    (fetch taller err: {str(e)[:90]})")
        return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true", help="escribe Firestore (sin esto = dry-run)")
    ap.add_argument("--solo", help="una sola patente")
    ap.add_argument("--limit", type=int, default=0, help="limitar N unidades (test)")
    args = ap.parse_args()

    cfg = json.load(open(_CLAVES, encoding="utf-8"))
    db = _db()

    # VEHICULOS por VIN y por patente (solo los que tenemos cargados).
    vehiculos_doc = {}   # patente -> doc.id (== patente)
    vin_a_patente = {}
    for d in db.collection("VEHICULOS").limit(5000).stream():
        x = d.to_dict() or {}
        vehiculos_doc[d.id.upper()] = d.id
        vin = (x.get("VIN") or "").strip().upper()
        if vin and vin != "-":
            vin_a_patente[vin] = d.id

    modo = "COMMIT" if args.commit else "DRY-RUN"
    print(f"=== sync_taller [{modo}] ===")

    with sync_playwright() as p:
        # Flags de estabilidad para chromium headless bajo la Scheduled Task
        # (sesion sin escritorio interactivo). El fix del timeout del taller NO
        # es esto sino el fetch directo de _fetch_taller; estos flags quedan por
        # higiene (evitan que el headless intente GPU que no tiene).
        browser = p.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-gpu", "--disable-dev-shm-usage"],
        )
        ctx_kwargs = {"locale": "es-ES"}
        if os.path.exists(_STATE):
            ctx_kwargs["storage_state"] = _STATE
        ctx = browser.new_context(**ctx_kwargs)
        page = ctx.new_page()

        if not _login(page, cfg):
            print("LOGIN FALLÓ — abortando")
            browser.close()
            return 1
        ctx.storage_state(path=_STATE)
        print("login OK")

        flota, auth = _fetch_flota(page)
        print(f"flota Volvo: {len(flota)} unidades")
        if not flota:
            print("no se pudo leer la flota — abortando")
            browser.close()
            return 1
        if not auth:
            print("no capturé el token de auth — abortando (taller necesita Bearer)")
            browser.close()
            return 1

        # Filtrar a las unidades que tenemos en VEHICULOS (por patente o VIN).
        objetivos = []
        for v in flota:
            pat = (v.get("registrationNumber") or "").strip().upper()
            vin = (v.get("vin") or "").strip().upper()
            doc = vehiculos_doc.get(pat) or vin_a_patente.get(vin)
            if doc and v.get("id"):
                objetivos.append((doc, v["id"], pat or vin))
        if args.solo:
            objetivos = [o for o in objetivos if o[0].upper() == args.solo.upper()]
        if args.limit:
            objetivos = objetivos[: args.limit]
        print(f"a procesar: {len(objetivos)} unidades")

        actualizados = sin_service = 0
        batch = db.batch()
        for doc_id, vid, etiqueta in objetivos:
            past = _fetch_taller(page, vid, auth)
            srv = ultimo_service_programado(past)
            if not srv:
                sin_service += 1
                print(f"  {etiqueta:10s} {doc_id:10s} visitas={len(past):3d}  → SIN service")
                continue
            print(f"  {etiqueta:10s} {doc_id:10s} visitas={len(past):3d}  → último service "
                  f"{srv['fecha']} @ {srv['km']:,} km")
            if args.commit:
                batch.set(db.collection("VEHICULOS").document(doc_id), {
                    "ULTIMO_SERVICE_KM": float(srv["km"]),
                    "ULTIMO_SERVICE_FECHA": srv["fecha"],
                    "ULTIMO_SERVICE_FUENTE": "volvo_taller",
                    "ULTIMO_SERVICE_SYNC_EN": firestore.SERVER_TIMESTAMP,
                }, merge=True)
                # Historial COMPLETO de taller (services + reparaciones) para la
                # pantalla de mantenimiento. Doc por unidad con array `servicios`.
                batch.set(db.collection("VEHICULOS_TALLER").document(doc_id), {
                    "patente": doc_id,
                    "actualizado_en": firestore.SERVER_TIMESTAMP,
                    "servicios": normalizar_servicios(past),
                })
                actualizados += 1
                if actualizados % 100 == 0:  # Firestore: máx 500 ops/batch.
                    batch.commit()
                    batch = db.batch()
        if args.commit and actualizados:
            batch.commit()
        browser.close()

        print(f"\n=== {modo} OK | con service: {len(objetivos) - sin_service} | "
              f"sin service: {sin_service} | escritos: {actualizados if args.commit else 0} ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
