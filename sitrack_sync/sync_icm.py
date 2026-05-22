"""Ingiere el ICM OFICIAL de Sitrack (lo que audita YPF) desde el portal site5
→ ICM_OFICIAL/{periodo} en Firestore. Lo lee el módulo ICM de la app.

Por qué: Sitrack calcula el ICM con su cartografía de segmento vial (urbano/
no-urbano), dato que nosotros NO tenemos. Ingerimos SU número en vez de
recalcular CESVI mal. Escala invertida: MÁS BAJO = MEJOR (ver parser.py).

Flujo (mismo patrón que volvo_sync):
  1. Login Playwright (claves.json) — sesión reusable (storage_state.json).
  2. Navega al tablero ICM e intercepta get_ranking_data → extrae clientId+grant
     (lo que usa la propia página; robusto a cambios).
  3. Fetch in-page de get_ranking_data por chofer (scopeDriver) y por unidad
     (scopeHolder) para el período pedido.
  4. parser.construir_doc_icm → escribe ICM_OFICIAL/{periodo}.

Sitrack actualiza el ICM en batch DIARIO (el día en curso no está hasta que
cierra). Por eso conviene correr 1 vez al día (madrugada). Doc id = periodo
(YYYY-MM por defecto), se reescribe a medida que el mes acumula.

SEGURIDAD: dry-run por defecto. Solo escribe con --commit. La contraseña vive
en claves.json (gitignoreado); el script la lee, nadie la tipea.

Uso:
  python sync_icm.py                       # dry-run, mes actual
  python sync_icm.py --commit              # escribe ICM_OFICIAL/{mes actual}
  python sync_icm.py --desde 2026-05-01 --hasta 2026-05-22 --periodo 2026-05 --commit
"""
import argparse
import datetime as dt
import json
import os
import sys
from urllib.parse import urlparse, parse_qs

import firebase_admin
from firebase_admin import credentials, firestore
from playwright.sync_api import sync_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from parser import construir_doc_icm  # noqa: E402

_DIR = os.path.dirname(os.path.abspath(__file__))
_SAK = os.path.join(_DIR, "..", "serviceAccountKey.json")
_CLAVES = os.path.join(_DIR, "claves.json")
_STATE = os.path.join(_DIR, "storage_state.json")
BASE = "https://www.sitrack.com"
ICM_URL = BASE + "/site5/rankings/ICM/"
CLIENT_ID_DEFAULT = "41629"  # cuenta VECCHI (ws41629VecchiSRL)


def _db():
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    return firestore.client()


def _login(page, cfg):
    """Asegura sesión iniciada en el portal site5. Devuelve True si quedó
    logueado. El login es cross-origin (host aparte) — usamos selectores
    resilientes en vez de hardcodear la URL."""
    page.goto(ICM_URL, wait_until="domcontentloaded", timeout=60000)
    page.wait_for_timeout(3500)
    # Si ya hay sesión (storage_state), el tablero carga directo.
    if "/rankings/ICM" in page.url and page.query_selector("input[type=password]") is None:
        return True
    # Login: esperar el campo de contraseña (esté donde esté el form).
    try:
        page.wait_for_selector("input[type=password]", timeout=25000)
    except Exception:
        print(f"    (no encontré form de login. url={page.url} title={page.title()!r})")
        return False
    # Usuario: primer input de texto/email visible.
    usuario_sel = ("input[type=email]:visible, input[type=text]:visible, "
                   "input[name*=user i]:visible, input[id*=user i]:visible")
    u = page.query_selector(usuario_sel)
    p = page.query_selector("input[type=password]")
    if not u or not p:
        print(f"    (faltan campos de login. url={page.url})")
        return False
    u.fill(cfg["usuario"])
    p.fill(cfg["password"])
    # Submit: botón submit, o Enter en el password.
    btn = page.query_selector("button[type=submit], input[type=submit], "
                              "button:has-text('Ingresar'), button:has-text('Iniciar')")
    if btn:
        btn.click()
    else:
        p.press("Enter")
    try:
        page.wait_for_url(lambda url: "/rankings/ICM" in url
                          or page.query_selector("input[type=password]") is None,
                          timeout=35000)
    except Exception:
        pass
    page.wait_for_timeout(4000)
    return page.query_selector("input[type=password]") is None


def _extraer_client_grant(page):
    """Navega al tablero ICM e intercepta su propia llamada get_ranking_data
    para extraer clientId y grant (los que usa la página). Robusto a cambios."""
    try:
        with page.expect_response(
            lambda r: "rankings/ICM/get_ranking_data" in r.url, timeout=30000
        ) as info:
            page.goto(ICM_URL, wait_until="domcontentloaded", timeout=60000)
        q = parse_qs(urlparse(info.value.url).query)
        client_id = (q.get("clientId") or [CLIENT_ID_DEFAULT])[0]
        grant = (q.get("grant") or [""])[0]
        return client_id, grant
    except Exception as e:
        print(f"    (no pude interceptar get_ranking_data: {str(e)[:90]})")
        return CLIENT_ID_DEFAULT, ""


def _fetch_ranking(page, client_id, scope, grant, desde, hasta):
    """Fetch in-page (con la cookie de sesión) de get_ranking_data. Devuelve
    el JSON parseado o {} si falla."""
    url = (f"{ICM_URL}get_ranking_data?clientId={client_id}&scope={scope}"
           f"&dateFrom={desde}&dateTo={hasta}&grant={grant}")
    try:
        return page.evaluate(
            """async (u) => { const r = await fetch(u, {credentials:'include'});
               if (!r.ok) return {__err: r.status}; return await r.json(); }""",
            url,
        ) or {}
    except Exception as e:
        print(f"    (fetch {scope} falló: {str(e)[:90]})")
        return {}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true", help="escribe Firestore (sin esto = dry-run)")
    ap.add_argument("--desde", help="fecha desde YYYY-MM-DD (default: 1° del mes actual ART)")
    ap.add_argument("--hasta", help="fecha hasta YYYY-MM-DD (default: hoy ART)")
    ap.add_argument("--periodo", help="id del doc (default: YYYY-MM del mes actual)")
    args = ap.parse_args()

    # Período por defecto: mes en curso, en hora Argentina (UTC-3).
    hoy_art = (dt.datetime.utcnow() - dt.timedelta(hours=3)).date()
    desde = args.desde or hoy_art.replace(day=1).isoformat()
    hasta = args.hasta or hoy_art.isoformat()
    periodo = args.periodo or hoy_art.strftime("%Y-%m")

    cfg = json.load(open(_CLAVES, encoding="utf-8"))
    if not cfg.get("password"):
        print("FALTAN CREDENCIALES en claves.json (password vacío) — abortando")
        return 1

    modo = "COMMIT" if args.commit else "DRY-RUN"
    print(f"=== sync_icm [{modo}] | período {periodo} ({desde} → {hasta}) ===")

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

        client_id, grant = _extraer_client_grant(page)
        print(f"clientId={client_id} grant={grant[:40]}{'...' if len(grant) > 40 else ''}")

        raw_driver = _fetch_ranking(page, client_id, "scopeDriver", grant, desde, hasta)
        raw_holder = _fetch_ranking(page, client_id, "scopeHolder", grant, desde, hasta)
        browser.close()

    n_drv = len((raw_driver or {}).get("rankingItemsByScope", {}))
    if not n_drv:
        print("get_ranking_data por chofer vino vacío — abortando (revisar grant/sesión)")
        return 1

    doc = construir_doc_icm(raw_driver, raw_holder, periodo, desde, hasta)
    print(f"ICM general flota: {doc['icm_general']}  | choferes activos: "
          f"{doc['choferes_activos']}/{doc['choferes_total']}  | "
          f"vehículos: {len(doc['vehiculos'])}  | km: {doc['distancia_total_km']:,.0f}")
    print("  peores 5 choferes:")
    for c in doc["choferes"][:5]:
        print(f"    {c['icm']:6.2f}  {c['severidad_label']:14s}  {c['nombre']}")

    if args.commit:
        db = _db()
        db.collection("ICM_OFICIAL").document(periodo).set({
            **doc,
            "sincronizado_en": firestore.SERVER_TIMESTAMP,
        })
        print(f"\n=== COMMIT OK → ICM_OFICIAL/{periodo} ===")
    else:
        print("\n=== DRY-RUN (no escribió). Agregá --commit para guardar. ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
