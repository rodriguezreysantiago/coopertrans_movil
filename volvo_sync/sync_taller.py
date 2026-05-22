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
    """Navega a /assets y devuelve la lista de vehículos
    [{id, registrationNumber, vin}, ...] de multidomainservices."""
    capturas = []

    def on_resp(r):
        try:
            if r.request.method == "POST" and "multidomainservices/graphql" in r.url:
                body = r.text()
                if '"vehicles"' in body and len(body) > 500:
                    capturas.append(body)
        except Exception:
            pass

    page.on("response", on_resp)
    page.goto(BASE + "/assets", wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(9000)
    page.remove_listener("response", on_resp)
    if not capturas:
        return []
    big = max(capturas, key=len)
    data = json.loads(big).get("data") or {}
    return data.get("vehicles") or []


def _fetch_taller(page, vehicle_id):
    """Navega al historial de taller de una unidad y espera (expect_response) la
    respuesta de ecs-workshophistory. Rango de fechas amplio para traer todo."""
    url = (f"{BASE}/workshop/vehicle/{vehicle_id}"
           "?sort=date-desc&dateRange=2018-01-01--2030-01-01")
    try:
        with page.expect_response(
            lambda r: "ecs-workshophistory/graphql" in r.url, timeout=35000
        ) as info:
            page.goto(url, wait_until="domcontentloaded", timeout=60000)
        j = info.value.json()
        return (j.get("data") or {}).get("pastServices") or []
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
        browser = p.chromium.launch(headless=True)
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

        flota = _fetch_flota(page)
        print(f"flota Volvo: {len(flota)} unidades")
        if not flota:
            print("no se pudo leer la flota — abortando")
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
            past = _fetch_taller(page, vid)
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
