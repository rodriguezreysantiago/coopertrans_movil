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
import parser as parser_mod  # noqa: E402
from parser import (  # noqa: E402
    construir_doc_icm, _rango_semana_actual, _rango_semana_anterior,
    _rango_mes_anterior,
)

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


def _ruta(url: str) -> str:
    """Solo el path de una URL (NUNCA loguear el query — el form de login es
    GET y mete usuario/contraseña en la query string)."""
    try:
        return urlparse(url).path
    except Exception:
        return "?"


def _login(page, cfg):
    """Asegura sesión iniciada en el portal site5 (login en /site5/login/,
    campos #userName / #password, botón INGRESAR, form GET). Hace UN intento
    de login normal: llena credenciales y manda. NO interactúa con el
    reCAPTCHA — si el portal lo exige, el login falla y devolvemos False
    (no se intenta resolver/saltear el CAPTCHA)."""
    page.goto(ICM_URL, wait_until="domcontentloaded", timeout=45000)
    page.wait_for_timeout(2500)
    # Si ya hay sesión válida (storage_state reusado), no redirige a /login.
    if "/login" not in page.url:
        return True
    try:
        page.wait_for_selector("#password", timeout=20000)
    except Exception:
        print(f"    (no encontré form de login en {_ruta(page.url)})")
        return False
    page.fill("#userName", cfg["usuario"])
    page.fill("#password", cfg["password"])
    # Submit normal (botón INGRESAR). Esperamos la navegación resultante.
    try:
        with page.expect_navigation(wait_until="domcontentloaded", timeout=30000):
            page.click("button:has-text('INGRESAR'), input[type=submit], "
                       "button[type=submit]")
    except Exception:
        pass
    page.wait_for_timeout(3000)
    ok = "/login" not in page.url
    if not ok:
        # Quedó en /login → credenciales rechazadas o reCAPTCHA exigido.
        print(f"    (sigue en login: {_ruta(page.url)} — ¿reCAPTCHA o credenciales?)")
    return ok


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


def _fetch_top_infractions(page, client_id, grant, desde, hasta, limit=10000):
    """GET get_top_infractions: hotspots de infracciones agregados por
    ubicación cartográfica única. Devuelve lista o []. Alimenta el mapa de
    calor de la app."""
    url = (f"{ICM_URL}get_top_infractions?limit={limit}&clientId={client_id}"
           f"&scope=scopeDriver&dateTo={hasta}&dateFrom={desde}&grant={grant}")
    try:
        out = page.evaluate(
            """async (u) => { const r = await fetch(u, {credentials:'include'});
               if (!r.ok) return {__err: r.status}; return await r.json(); }""",
            url,
        )
        if isinstance(out, list):
            return out
        if isinstance(out, dict) and "__err" in out:
            print(f"    (get_top_infractions HTTP {out['__err']})")
        return []
    except Exception as e:
        print(f"    (get_top_infractions falló: {str(e)[:90]})")
        return []


def _fetch_infractions_chofer(page, client_id, grant, scope_id, desde, hasta,
                              limit=1000):
    """POST get_infractions: lista individual de las infracciones del chofer
    `scope_id` (ID interno Sitrack, NO DNI — viene del response de
    get_ranking_data como `scopeId`). Devuelve lista o [].

    Sitrack normalmente devuelve `limit=10` por defecto (paginado); pedimos
    1000 que cubre cualquier chofer en un período mensual (el más malo ronda
    50-100 infracciones)."""
    js = (
        "async (args) => {\n"
        "  const body = new URLSearchParams({\n"
        "    limit: String(args.limit),\n"
        "    scope: 'scopeDriver',\n"
        "    scopeId: String(args.scopeId),\n"
        "    dateFrom: args.dateFrom,\n"
        "    dateTo: args.dateTo,\n"
        "    fleetId: '',\n"
        "    suffix: '',\n"
        "    grant: args.grant,\n"
        "    clientId: String(args.clientId),\n"
        "  });\n"
        "  const r = await fetch(args.url, {\n"
        "    method: 'POST',\n"
        "    credentials: 'include',\n"
        "    headers: {'Content-Type': 'application/x-www-form-urlencoded'},\n"
        "    body: body.toString(),\n"
        "  });\n"
        "  if (!r.ok) return {__err: r.status};\n"
        "  return await r.json();\n"
        "}"
    )
    args = {
        "url": f"{ICM_URL}get_infractions",
        "limit": limit,
        "scopeId": scope_id,
        "dateFrom": desde,
        "dateTo": hasta,
        "grant": grant,
        "clientId": client_id,
    }
    try:
        out = page.evaluate(js, args)
        if isinstance(out, list):
            return out
        if isinstance(out, dict):
            # Sitrack a veces envuelve la lista en {items:[...]} o {data:[...]}
            for k in ("items", "data", "rows", "infractions"):
                if isinstance(out.get(k), list):
                    return out[k]
            if "__err" in out:
                print(f"      (get_infractions HTTP {out['__err']} para scopeId {scope_id})")
        return []
    except Exception as e:
        print(f"      (get_infractions falló scopeId {scope_id}: {str(e)[:90]})")
        return []


MAX_INFRAC_POR_CHOFER = 100
"""Tope de infracciones individuales que guardamos por chofer en el doc del
período. El doc serializado supera ~700 KB para un mes normal de la flota
Vecchi (50 choferes activos × ~33 infracciones promedio). Firestore limita
los docs a 1 MB → para no explotar en meses largos / choferes outlier (vimos
casos reales de 91 infrac/mes) capamos en 100 y dejamos margen del ~30%.
Si en algún chofer se supera, loguemos y queda como señal de que conviene
migrar a subcolección antes de seguir creciendo."""


def _enriquecer_con_infracciones(page, client_id, grant, doc, desde, hasta):
    """Para cada chofer activo, llama get_infractions(scopeId).

    HARDENING 1 MiB (2026-06-13): antes embebía el array en
    `doc['choferes'][i]['infracciones']`, lo que hacía crecer el doc mensual
    hasta rozar el límite de 1 MiB de Firestore (si se pasa, el .set FALLA y se
    pierde el número oficial del mes). Ahora NO embebe: DEVUELVE un dict
    `{scope_id(str): {scope_id, dni, nombre, infracciones[]}}` para que el caller
    lo escriba en la subcolección `infracciones_chofer/{scope_id}`. El doc
    principal queda liviano (choferes con dni/score/severidad, sin el array).

    Cap de MAX_INFRAC_POR_CHOFER por chofer. La clave es `scope_id` (no `dni`,
    que Sitrack a veces manda vacío). Si alguno supera el cap, log warning."""
    infrac_por_scope = {}
    if not doc or not doc.get("choferes"):
        return infrac_por_scope
    activos = [c for c in doc["choferes"]
               if c.get("severidad") != "UNAVAILABLE_NO_ACTIVITY"
               and int(c.get("scope_id") or 0) > 0]
    # Aviso (review 2026-06-13): un chofer ACTIVO sin scope_id no puede tener
    # subcolección de infracciones (el detalle queda vacío). No afecta el número
    # oficial (icm_general/score), pero conviene detectarlo si Sitrack deja de
    # mandar el scopeId.
    sin_scope = [c for c in doc["choferes"]
                 if c.get("severidad") != "UNAVAILABLE_NO_ACTIVITY"
                 and int(c.get("scope_id") or 0) <= 0]
    if sin_scope:
        nombres = ", ".join(c.get("nombre", "?") for c in sin_scope[:5])
        print(f"      ⚠ {len(sin_scope)} chofer(es) activo(s) SIN scope_id "
              f"(quedan sin detalle de infracciones): {nombres}")
    print(f"      → trayendo infracciones individuales de "
          f"{len(activos)} chofer(es) activo(s)…")
    total_infrac = 0
    capeados = 0
    for idx, c in enumerate(activos):
        raw = _fetch_infractions_chofer(
            page, client_id, grant, c["scope_id"], desde, hasta,
            limit=MAX_INFRAC_POR_CHOFER + 1)  # +1 para detectar overflow
        items = [parser_mod.parsear_infraccion_individual(i)
                 for i in raw if isinstance(i, dict)]
        if len(items) > MAX_INFRAC_POR_CHOFER:
            capeados += 1
            print(f"        ⚠ {c.get('nombre')}: {len(items)} infrac. "
                  f"(capeado a {MAX_INFRAC_POR_CHOFER})")
            items = items[:MAX_INFRAC_POR_CHOFER]
        # NO se embebe en el doc — se junta por scope_id para la subcolección.
        infrac_por_scope[str(c["scope_id"])] = {
            "scope_id": c["scope_id"],
            "dni": c.get("dni", ""),
            "nombre": c.get("nombre", ""),
            "infracciones": items,
        }
        total_infrac += len(items)
        if (idx + 1) % 10 == 0:
            print(f"        ({idx+1}/{len(activos)} procesados, "
                  f"{total_infrac} infrac. acumuladas)")
        # Pequeño jitter para no martillar el WAF de Sitrack.
        page.wait_for_timeout(120)
    suf = f" ({capeados} chofer(es) capeados al tope)" if capeados else ""
    print(f"      ← total {total_infrac} infracciones individuales mapeadas{suf}")
    return infrac_por_scope


def _persistir_infracciones_subcol(db, coleccion, periodo, infrac_por_scope):
    """Escribe las infracciones por chofer en la subcolección
    `coleccion/periodo/infracciones_chofer/{scope_id}` (batched). Hardening 1 MiB
    (2026-06-13): saca el peso del doc principal. La app lee el detalle de un
    chofer desde acá (con fallback al array embebido de docs viejos). Idempotente
    (set por scope_id)."""
    if not infrac_por_scope:
        return
    base = (db.collection(coleccion).document(periodo)
            .collection("infracciones_chofer"))
    batch = db.batch()
    n = 0
    for scope_id, payload in infrac_por_scope.items():
        batch.set(base.document(str(scope_id)), {
            **payload, "sincronizado_en": firestore.SERVER_TIMESTAMP,
        })
        n += 1
        if n % 450 == 0:  # límite de 500 ops/batch en Firestore
            batch.commit()
            batch = db.batch()
    if n % 450 != 0:  # evita un commit de batch vacío si n fue múltiplo exacto
        batch.commit()
    print(f"      subcol infracciones_chofer: {len(infrac_por_scope)} chofer(es)")


def _persistir(raw_driver, raw_holder, raw_hotspots, periodo, desde, hasta,
               alcance, coleccion, commit, db, page, client_id, grant):
    """Construye el doc ICM (incluye hotspots de mapa de calor), enriquece
    los choferes activos con sus infracciones individuales (get_infractions
    por scopeId) y, si commit, lo escribe en coleccion/periodo. Devuelve
    True si había data de choferes."""
    n = len((raw_driver or {}).get("rankingItemsByScope", {}))
    if not n:
        print(f"  [{coleccion}/{periodo}] driver vacío — salteado")
        return False
    doc = construir_doc_icm(raw_driver, raw_holder, periodo, desde, hasta,
                            alcance, raw_hotspots=raw_hotspots)
    print(f"  [{coleccion}/{periodo}] ICM flota {doc['icm_general']} | "
          f"activos {doc['choferes_activos']}/{doc['choferes_total']} | "
          f"veh {len(doc['vehiculos'])} | km {doc['distancia_total_km']:,.0f} | "
          f"días {len(doc['tendencia_diaria'])} | "
          f"hotspots {len(doc['infracciones_heatmap'])}")
    peor = doc["choferes"][0] if doc["choferes"] else None
    if peor:
        print(f"      peor: {peor['icm']:.2f} {peor['severidad_label']} "
              f"{peor['nombre']}")
    # Enriquecer con infracciones individuales por chofer (1 fetch por activo).
    # Van a la subcolección (no embebidas en el doc) — hardening 1 MiB.
    infrac_por_scope = _enriquecer_con_infracciones(
        page, client_id, grant, doc, desde, hasta)
    if commit:
        db.collection(coleccion).document(periodo).set({
            **doc, "sincronizado_en": firestore.SERVER_TIMESTAMP,
        })
        _persistir_infracciones_subcol(db, coleccion, periodo, infrac_por_scope)
        print(f"      COMMIT OK -> {coleccion}/{periodo}")
    return True


def _cerrar_si_falta(page, client_id, grant, db, coleccion, periodo, desde,
                     hasta, alcance, commit):
    """Snapshot INMUTABLE de cierre: crea coleccion/periodo UNA sola vez (si no
    existe) con la data del período ya cerrado. NUNCA sobreescribe → la
    liquidación de premios se hace sobre un número que no cambia aunque Sitrack
    reprocese. En dry-run solo reporta qué congelaría.

    El cierre también trae hotspots + infracciones individuales (mismo
    enriquecimiento que la corrida diaria del período en curso) para que el
    snapshot sea autónomo y la app pueda mostrar el detalle aunque Sitrack
    pierda la data."""
    doc_ref = db.collection(coleccion).document(periodo)
    doc_existe = False
    if commit:
        doc_existe = doc_ref.get().exists
        if doc_existe:
            # Recuperación (review 2026-06-13): si el doc ya está congelado PERO
            # la subcolección quedó vacía (una corrida previa escribió el doc y
            # falló antes de la subcol), NO re-escribimos el doc inmutable pero sí
            # completamos la subcolección (idempotente, no toca el número oficial).
            subcol_vacia = len(
                doc_ref.collection("infracciones_chofer").limit(1).get()) == 0
            if not subcol_vacia:
                return  # doc + subcol OK — nada que hacer
            print(f"  [cierre {coleccion}/{periodo}] doc congelado pero subcol "
                  f"VACÍA — completo solo la subcolección (no re-escribo el doc)")
    drv = _fetch_ranking(page, client_id, "scopeDriver", grant, desde, hasta)
    if not (drv or {}).get("rankingItemsByScope"):
        print(f"  [cierre {coleccion}/{periodo}] sin data ({desde}→{hasta}) — salteado")
        return
    hold = _fetch_ranking(page, client_id, "scopeHolder", grant, desde, hasta)
    hotspots = _fetch_top_infractions(page, client_id, grant, desde, hasta)
    doc = construir_doc_icm(drv, hold, periodo, desde, hasta, alcance,
                            raw_hotspots=hotspots)
    print(f"  [cierre {coleccion}/{periodo}] {desde}→{hasta} ICM {doc['icm_general']} "
          f"activos {doc['choferes_activos']}/{doc['choferes_total']} | "
          f"hotspots {len(doc['infracciones_heatmap'])}")
    infrac_por_scope = _enriquecer_con_infracciones(
        page, client_id, grant, doc, desde, hasta)
    if commit:
        if not doc_existe:
            doc_ref.set({
                **doc,
                "sincronizado_en": firestore.SERVER_TIMESTAMP,
                "congelado": True,
            })
            print(f"      CIERRE CONGELADO -> {coleccion}/{periodo}")
        # Subcolección: en doc nuevo va junto al cierre; en recuperación va sola
        # (el doc inmutable no se toca). Firestore no copia subcolecciones.
        _persistir_infracciones_subcol(db, coleccion, periodo, infrac_por_scope)
        if doc_existe:
            print(f"      subcol del cierre COMPLETADA -> {coleccion}/{periodo}")
    else:
        print("      (dry-run: no congela)")


def _cerrar_mensual_si_corresponde(page, client_id, grant, db, hoy, commit):
    """Congela el mes anterior a partir del día 4 (Sitrack ya lo cerró)."""
    if hoy.day < 4:
        return
    desde, hasta, pid = _rango_mes_anterior(hoy)
    _cerrar_si_falta(page, client_id, grant, db, "ICM_OFICIAL_CIERRE", pid,
                     desde, hasta, "cierre_mensual", commit)


def _cerrar_semanal_si_corresponde(page, client_id, grant, db, hoy, commit):
    """Congela la semana anterior (lunes→domingo) a partir del MARTES, cuando
    la data del domingo previo ya está completa. weekday(): lun=0 ... dom=6."""
    if hoy.weekday() < 1:  # lunes → todavía no
        return
    desde, hasta, wid = _rango_semana_anterior(hoy)
    _cerrar_si_falta(page, client_id, grant, db, "ICM_OFICIAL_CIERRE_SEMANAL",
                     wid, desde, hasta, "cierre_semanal", commit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--commit", action="store_true", help="escribe Firestore (sin esto = dry-run)")
    ap.add_argument("--desde", help="fecha desde YYYY-MM-DD (default: 1° del mes actual ART)")
    ap.add_argument("--hasta", help="fecha hasta YYYY-MM-DD (default: hoy ART)")
    ap.add_argument("--periodo", help="id del doc (default: YYYY-MM del mes actual)")
    args = ap.parse_args()

    # Período por defecto: mes en curso, en hora Argentina (UTC-3).
    hoy_art = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=3)).date()
    desde = args.desde or hoy_art.replace(day=1).isoformat()
    hasta = args.hasta or hoy_art.isoformat()
    periodo = args.periodo or hoy_art.strftime("%Y-%m")

    cfg = json.load(open(_CLAVES, encoding="utf-8"))
    if not cfg.get("password"):
        print("FALTAN CREDENCIALES en claves.json (password vacío) — abortando")
        return 1

    modo = "COMMIT" if args.commit else "DRY-RUN"
    print(f"=== sync_icm [{modo}] | período {periodo} ({desde} → {hasta}) ===")

    db = _db() if args.commit else None

    with sync_playwright() as p:
        # Flags para chromium headless estable bajo la Scheduled Task (sesion
        # sin escritorio interactivo) — mismo motivo que volvo_sync.
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

        client_id, grant = _extraer_client_grant(page)
        print(f"clientId={client_id} grant={grant[:40]}{'...' if len(grant) > 40 else ''}")

        # Mensual (rango pedido / mes en curso).
        raw_driver = _fetch_ranking(page, client_id, "scopeDriver", grant,
                                    desde, hasta)
        raw_holder = _fetch_ranking(page, client_id, "scopeHolder", grant,
                                    desde, hasta)
        raw_hotspots = _fetch_top_infractions(page, client_id, grant,
                                              desde, hasta)
        # Semanal (lunes ART → hoy) — mismo request, otro rango. Para el
        # ranking semanal de la app (premios por semana).
        sem_desde, sem_hasta, sem_id = _rango_semana_actual(hoy_art)
        raw_drv_sem = _fetch_ranking(page, client_id, "scopeDriver", grant,
                                     sem_desde, sem_hasta)
        raw_hold_sem = _fetch_ranking(page, client_id, "scopeHolder", grant,
                                      sem_desde, sem_hasta)
        raw_hotspots_sem = _fetch_top_infractions(page, client_id, grant,
                                                  sem_desde, sem_hasta)

        # Cierres INMUTABLES (mes anterior desde el día 4; semana anterior
        # desde el martes). Crean el snapshot UNA vez para liquidar premios.
        _cerrar_mensual_si_corresponde(page, client_id, grant, db, hoy_art,
                                       args.commit)
        _cerrar_semanal_si_corresponde(page, client_id, grant, db, hoy_art,
                                       args.commit)

        # Persistir mensual + semanal con enriquecimiento de infracciones
        # POR CHOFER (1 fetch por activo, ~120ms entre cada uno). Hay que
        # hacerlo ANTES de cerrar el browser porque _enriquecer_con_infrac…
        # usa la sesión Playwright para cada fetch.
        ok = _persistir(raw_driver, raw_holder, raw_hotspots, periodo, desde,
                        hasta, "mensual", "ICM_OFICIAL", args.commit, db,
                        page, client_id, grant)
        if not ok:
            print("mensual vino vacío — abortando (revisar grant/sesión)")
            browser.close()
            return 1

        print(f"--- semanal {sem_id} ({sem_desde} → {sem_hasta}) ---")
        _persistir(raw_drv_sem, raw_hold_sem, raw_hotspots_sem, sem_id,
                   sem_desde, sem_hasta, "semanal", "ICM_OFICIAL_SEMANAL",
                   args.commit, db, page, client_id, grant)

        browser.close()

    if not args.commit:
        print("\n=== DRY-RUN (no escribió). Agregá --commit para guardar. ===")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
