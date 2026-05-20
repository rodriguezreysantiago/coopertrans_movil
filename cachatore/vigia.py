"""vigia.py — daemon 24/7 del sniper de turnos YPF (cachatore).

A diferencia de `orquestador.py` (one-shot: espera el drop, caza y cierra),
este proceso queda **LATENTE las 24 hs** en la PC dedicada del bot:

- **Latente** (todo el día): barre cada ~5 s TODA la worklist (lo que dejamos
  en drop.json) — tanto agendar a los que no tienen turno como reagendar a los
  marcados. Si alguien CANCELA y se libera un turno en la franja de un chofer
  que lo necesita, lo agarra al toque — sin esperar al drop de las 10:30.
- **Agresivo** (alrededor de `hora_inicio`): cada chofer sin turno escanea su
  propia agenda a full y reserva apenas aparece un slot en su franja (igual que
  el orquestador, para ganar la pulseada del drop). Pasada la ventana, vuelve
  solo a latente.
- **Reagendar**: si un chofer tiene `reagendar:true`, mueve su turno a un slot
  de su franja apenas se libere uno (sin formulario, lo reasigna directo).

Todo el día además:
- Re-lee `drop.json` en caliente (no hace falta reiniciar el servicio).
- Re-trae de Firestore (cada ~10 min) la unidad/mail de cada chofer: si en la
  app le reasignan el camión, el vigía lo toma solo.
- Re-chequea `mis_turnos` (de a poco, para no bloquear): así sabe quién ya tiene
  turno y nunca dobla reserva ni pierde el estado si el servicio se reinicia.

Uso:
    python vigia.py                 # daemon 24/7 (lo corre el servicio NSSM)
    python vigia.py --dry           # no reserva/reagenda, solo loguea qué haría
    python vigia.py --latente       # fuerza modo latente (ignora ventana drop)
    python vigia.py --agresivo      # fuerza modo agresivo (testeo)

Logs con prefijo LOG:/EXITO:/ERROR: (la UI los parsea y colorea).
La hora local del equipo se asume ART (igual que el bot en la PC dedicada).
"""
import json
import os
import random
import sys
import threading
import time
from datetime import datetime, timedelta

import iturnos
import choferes

_DIR = os.path.dirname(os.path.abspath(__file__))
DROP_CONFIG = os.path.join(_DIR, "drop.json")

# Cadencias (se pueden pisar desde drop.json).
POLL_AGRESIVO_SEG = 1.5      # en la ventana del drop: re-escaneo rápido por chofer
POLL_LATENTE_SEG = 5.0       # resto del día: barre la worklist cada ~5 s
JITTER_LATENTE_SEG = 1.0     # + ruido chico (para no pegar siempre al mismo seg)
DROP_DURACION_MIN = 20       # largo de la ventana agresiva si no se especifica

LOGIN_REINTENTOS = 3
REFRESH_TURNOS_SEG = 600     # cada cuánto re-chequear mis_turnos de cada chofer
REFRESH_DATOS_SEG = 600      # cada cuánto re-traer unidad/mail de Firestore
MAX_REFRESH_POR_CICLO = 2    # cuántos mis_turnos refrescar por ciclo (no bloquear)
ESPERA_SIN_CONFIG_SEG = 30   # si falta/está vacío drop.json

_log_lock = threading.Lock()
_scanner = {"cli": None, "logueado": False}   # sesión dedicada al escaneo latente


def log(tag: str, quien: str, msg: str):
    with _log_lock:
        print(f"{tag}:[{datetime.now():%Y-%m-%d %H:%M:%S}] [{quien}] {msg}", flush=True)


def resolver_fecha(valor):
    """drop.json `fecha`: null=cualquier fecha en la franja; 'hoy'/'manana' se
    re-resuelven cada día (útil 24/7); o una fecha puntual 'AAAA-MM-DD'."""
    if not valor:
        return None
    v = str(valor).strip().lower()
    if v in ("hoy", "today"):
        return datetime.now().strftime("%Y-%m-%d")
    if v in ("manana", "mañana", "tomorrow"):
        return (datetime.now() + timedelta(days=1)).strftime("%Y-%m-%d")
    return str(valor)


def leer_config(ultimo):
    """Lee drop.json tolerando que esté a medio escribir (devuelve la última
    config buena en ese caso). None = no existe."""
    try:
        with open(DROP_CONFIG, encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except Exception as e:
        log("LOG", "sistema", f"drop.json ilegible ({e}); sigo con la última config")
        return ultimo


def en_ventana_drop(cfg) -> bool:
    """¿Estamos dentro de la ventana agresiva [hora_inicio, +duracion_min]?"""
    hi = cfg.get("hora_inicio")
    if not hi:
        return False
    try:
        h, m = map(int, str(hi).split(":"))
    except Exception:
        return False
    ahora = datetime.now()
    ini = ahora.replace(hour=h, minute=m, second=0, microsecond=0)
    dur = cfg.get("duracion_min", DROP_DURACION_MIN) or DROP_DURACION_MIN
    return ini <= ahora <= ini + timedelta(minutes=dur)


class Target:
    """Estado de un chofer vigilado. Objetivo: tener un turno en su franja."""
    __slots__ = ("dni", "nombre", "email", "clave", "patente", "franja",
                 "reagendar", "cli", "logueado", "tiene_turno", "uuid",
                 "reagendar_hecho", "ultimo_check")

    def __init__(self, ch: dict, franja: str, reagendar: bool):
        self.dni = ch["dni"]
        self.nombre = ch.get("nombre") or ch["dni"]
        self.email = (ch.get("email") or "").strip().lower()
        self.clave = ch.get("clave")
        self.patente = ch.get("patente")
        self.franja = franja
        self.reagendar = reagendar
        self.cli = None
        self.logueado = False
        self.tiene_turno = False
        self.uuid = None
        self.reagendar_hecho = False
        self.ultimo_check = 0.0

    @property
    def credenciales_ok(self) -> bool:
        return bool(self.email and self.clave)


# ---- login (con reintento por los blips de Cloudflare) --------------------
def asegurar_login(t: Target) -> bool:
    if t.cli is not None and t.logueado:
        return True
    if not t.credenciales_ok:
        return False
    t.cli = iturnos.IturnosClient()
    for _ in range(LOGIN_REINTENTOS):
        try:
            if t.cli.login(t.email, t.clave):
                t.logueado = True
                return True
        except Exception as e:
            log("LOG", t.nombre, f"login error transitorio: {e}")
        time.sleep(1.5)
    log("ERROR", t.nombre, "no pudo loguear tras reintentos")
    t.logueado = False
    return False


def ensure_scanner(targets: dict):
    """Sesión única (cualquier chofer sirve: la clave es común y la agenda se
    ve igual) usada SOLO para el escaneo latente — así no pegamos N veces."""
    if _scanner["cli"] is not None and _scanner["logueado"]:
        return _scanner["cli"]
    cred = next((t for t in targets.values() if t.credenciales_ok), None)
    if cred is None:
        return None
    cli = iturnos.IturnosClient()
    for _ in range(LOGIN_REINTENTOS):
        try:
            if cli.login(cred.email, cred.clave):
                _scanner["cli"], _scanner["logueado"] = cli, True
                return cli
        except Exception as e:
            log("LOG", "scanner", f"login error: {e}")
        time.sleep(1.5)
    log("ERROR", "scanner", "no pudo loguear")
    return None


# ---- reserva / reagendar --------------------------------------------------
def intentar_reservar(t: Target, slot: dict, dry: bool) -> bool:
    """Reserva `slot` para `t`. reservar() hace el GET /reservar/{ISO} que toma
    el slot en la sesión de ESTE chofer + el POST con patente/DNI/empresa."""
    if dry:
        log("EXITO", t.nombre, f"[DRY] reservaría {slot['fecha']} {slot['hora']}")
        t.tiene_turno = True   # simula éxito para no repetir el log en bucle
        return True
    try:
        r = t.cli.reservar(slot, patente=t.patente, dni=t.dni)
    except Exception as e:
        log("LOG", t.nombre, f"error en reserva: {e}")
        return False
    if r.get("ok"):
        log("EXITO", t.nombre,
            f"RESERVADO {slot['fecha']} {slot['hora']} — unidad {t.patente}")
        t.tiene_turno = True
        return True
    if r.get("motivo") == "tomado":
        log("LOG", t.nombre, f"{slot['hora']} lo tomaron, sigo buscando")
    else:
        log("LOG", t.nombre, f"reserva sin confirmar ({r.get('motivo')})")
    return False


def _reservar_async(t: Target, slot: dict, dry: bool):
    if not asegurar_login(t):
        return
    if intentar_reservar(t, slot, dry) and t.reagendar:
        t.reagendar_hecho = True   # ya quedó en franja al reservar; no hay que mover


def _agresivo_async(t: Target, fecha, dry: bool):
    if not asegurar_login(t):
        return
    try:
        html = t.cli.abrir_agenda()
    except Exception as e:
        log("LOG", t.nombre, f"error leyendo agenda: {e}")
        return
    if 'id="login-form"' in html:
        t.logueado = False
        return
    slots = iturnos.slots_en_franja(iturnos.parsear_disponibilidad(html)["slots"], t.franja)
    if fecha:
        slots = [s for s in slots if s["fecha"] == fecha]
    if not slots:
        return
    log("LOG", t.nombre, f"slot LIBRE {slots[0]['fecha']} {slots[0]['hora']} → reservando")
    if intentar_reservar(t, slots[0], dry) and t.reagendar:
        t.reagendar_hecho = True


def _en_paralelo(items, func, max_hilos=10, timeout=30):
    items = list(items)
    for i in range(0, len(items), max_hilos):
        lote = [threading.Thread(target=func, args=(x,), daemon=True)
                for x in items[i:i + max_hilos]]
        for h in lote:
            h.start()
        for h in lote:
            h.join(timeout=timeout)


# ---- estado (mis_turnos) --------------------------------------------------
def refrescar_estado(t: Target):
    """Mira mis_turnos: marca tiene_turno y guarda el UUID (para reagendar)."""
    if not asegurar_login(t):
        return
    try:
        turnos = t.cli.mis_turnos()
    except Exception as e:
        log("LOG", t.nombre, f"error leyendo mis turnos: {e}")
        return
    if turnos:
        t.uuid = turnos[0]["uuid"]
        if not t.tiene_turno:
            log("LOG", t.nombre, "ya tiene turno (detectado en mis turnos)")
        t.tiene_turno = True
    else:
        t.tiene_turno = False
        t.uuid = None
    t.ultimo_check = time.time()


def refrescar_datos_firestore(targets: dict):
    """Re-trae unidad/mail/clave de la app. Si reasignaron el camión, lo toma."""
    if not targets:
        return
    try:
        datos = {c["dni"]: c for c in choferes.cargar_choferes(solo_dnis=list(targets))}
    except Exception as e:
        log("LOG", "sistema", f"error releyendo Firestore: {e}")
        return
    for dni, t in targets.items():
        ch = datos.get(dni)
        if not ch:
            continue
        nueva = ch.get("patente")
        if nueva and nueva != t.patente:
            log("LOG", t.nombre, f"unidad actualizada en la app: {t.patente} → {nueva}")
            t.patente = nueva
        if ch.get("email"):
            t.email = ch["email"].strip().lower()
        if ch.get("clave"):
            t.clave = ch["clave"]


# ---- sincronización de targets con drop.json (hot reload) -----------------
def sincronizar_targets(cfg: dict, targets: dict):
    deseados = {c["dni"]: c for c in cfg.get("choferes", []) if c.get("dni")}

    for dni in list(targets):                       # sacar los que ya no están
        if dni not in deseados:
            log("LOG", "sistema", f"saco a {targets[dni].nombre} (ya no está en drop.json)")
            del targets[dni]

    # actualizar franja/reagendar de los que siguen
    for dni, spec in deseados.items():
        t = targets.get(dni)
        if not t:
            continue
        nf = spec.get("franja")
        if nf in iturnos.FRANJAS and nf != t.franja:
            log("LOG", "sistema", f"{t.nombre}: franja {t.franja} → {nf}")
            t.franja = nf
        nr = bool(spec.get("reagendar"))
        if nr != t.reagendar:
            t.reagendar = nr
            t.reagendar_hecho = False

    nuevos = [dni for dni in deseados if dni not in targets]
    if nuevos:
        try:
            datos = {c["dni"]: c for c in choferes.cargar_choferes(solo_dnis=nuevos)}
        except Exception as e:
            log("ERROR", "sistema", f"no pude traer choferes de Firestore: {e}")
            datos = {}
        for dni in nuevos:
            ch = datos.get(dni)
            spec = deseados[dni]
            if not ch:
                log("ERROR", dni, "no está en la base (¿tanque/excluido/inactivo?)")
                continue
            franja = spec.get("franja")
            if franja not in iturnos.FRANJAS:
                log("ERROR", ch.get("nombre") or dni, f"franja inválida: {franja!r}")
                continue
            t = Target(ch, franja, bool(spec.get("reagendar")))
            if not t.credenciales_ok:
                log("ERROR", t.nombre, "sin email/clave (revisar en la app/claves.json)")
                continue
            if not t.patente:
                log("ERROR", t.nombre, "sin patente/unidad asignada en la app")
                continue
            targets[dni] = t
            log("LOG", "sistema", f"vigilando {t.nombre} — franja '{t.franja}'"
                + (" (reagendar)" if t.reagendar else ""))

    # barrido de estado de los recién agregados (evita doble reserva / arranca
    # sabiendo quién ya tiene turno; corre en paralelo para no demorar).
    sin_chequear = [t for t in targets.values() if t.ultimo_check == 0.0]
    if sin_chequear:
        log("LOG", "sistema", f"chequeando turnos actuales de {len(sin_chequear)} chofer(es)…")
        _en_paralelo(sin_chequear, refrescar_estado, max_hilos=10)


# ---- ciclos ---------------------------------------------------------------
def ciclo_agresivo(targets: dict, fecha, dry: bool):
    necesitan = [t for t in targets.values()
                 if not t.tiene_turno and t.credenciales_ok and t.patente]
    if necesitan:
        _en_paralelo(necesitan, lambda t: _agresivo_async(t, fecha, dry),
                     max_hilos=len(necesitan), timeout=15)


def ciclo_latente(targets: dict, fecha, dry: bool):
    cli = ensure_scanner(targets)
    if cli is None:
        return
    try:
        html = cli.abrir_agenda()
    except Exception as e:
        log("LOG", "scanner", f"error leyendo agenda: {e}")
        _scanner["logueado"] = False
        return
    if 'id="login-form"' in html:
        _scanner["logueado"] = False
        return

    libres = iturnos.parsear_disponibilidad(html)["slots"]
    if fecha:
        libres = [s for s in libres if s["fecha"] == fecha]
    if not libres:
        return

    # asignar slots LIBRES a los choferes que necesitan turno (uno por slot)
    usados, asignaciones = set(), []
    for t in targets.values():
        if t.tiene_turno or not t.credenciales_ok or not t.patente:
            continue
        cand = [s for s in libres
                if s["iso"] not in usados and iturnos.hora_en_franja(s["hora"], t.franja)]
        if cand:
            usados.add(cand[0]["iso"])
            asignaciones.append((t, cand[0]))
    if asignaciones:
        log("LOG", "sistema",
            f"latente: {len(asignaciones)} slot(s) libre(s) en franja → reservando")
        _en_paralelo(asignaciones, lambda a: _reservar_async(a[0], a[1], dry),
                     max_hilos=len(asignaciones), timeout=25)

    # reagendar: mover el turno de quien lo pidió, si hay slot libre en su franja
    for t in targets.values():
        if not (t.reagendar and t.tiene_turno and t.uuid and not t.reagendar_hecho):
            continue
        if not any(iturnos.hora_en_franja(s["hora"], t.franja) for s in libres):
            continue
        if dry:
            log("EXITO", t.nombre, f"[DRY] reagendaría a un slot de '{t.franja}'")
            t.reagendar_hecho = True
            continue
        if not asegurar_login(t):
            continue
        try:
            r = t.cli.reagendar(t.uuid, t.franja)
        except Exception as e:
            log("LOG", t.nombre, f"error reagendando: {e}")
            continue
        if r.get("ok"):
            log("EXITO", t.nombre, f"REAGENDADO a {r.get('hora')} (franja '{t.franja}')")
            t.reagendar_hecho = True
        elif r.get("motivo") == "tomado":
            log("LOG", t.nombre, f"{r.get('hora')} lo tomaron al reagendar, sigo")
        elif r.get("motivo") != "sin_slot_en_franja":
            log("LOG", t.nombre, f"reagendar sin confirmar ({r.get('motivo')})")


# ---- loop principal -------------------------------------------------------
def main():
    dry = "--dry" in sys.argv
    forzar_latente = "--latente" in sys.argv
    forzar_agresivo = "--agresivo" in sys.argv

    log("LOG", "sistema", f"vigía 24/7 arrancando{' [DRY]' if dry else ''} (pid {os.getpid()})")
    targets: dict = {}
    cfg = None
    ultimo_refresh_datos = 0.0
    modo_anterior = None

    while True:
        try:
            nueva = leer_config(cfg)
            if nueva is None:
                log("LOG", "sistema", "falta drop.json (ver drop.ejemplo.json); espero")
                time.sleep(ESPERA_SIN_CONFIG_SEG)
                continue
            cfg = nueva
            sincronizar_targets(cfg, targets)
            if not targets:
                time.sleep(ESPERA_SIN_CONFIG_SEG)
                continue

            # re-traer unidad/mail de Firestore (refleja reasignaciones de la app)
            if time.time() - ultimo_refresh_datos > REFRESH_DATOS_SEG:
                refrescar_datos_firestore(targets)
                ultimo_refresh_datos = time.time()

            # re-chequear mis_turnos de a poco (sin bloquear el ciclo)
            vencidos = sorted(
                (t for t in targets.values()
                 if time.time() - t.ultimo_check > REFRESH_TURNOS_SEG),
                key=lambda t: t.ultimo_check)[:MAX_REFRESH_POR_CICLO]
            for t in vencidos:
                refrescar_estado(t)

            fecha = resolver_fecha(cfg.get("fecha"))
            agresivo = forzar_agresivo or (not forzar_latente and en_ventana_drop(cfg))
            modo = "agresivo" if agresivo else "latente"
            if modo != modo_anterior:
                pendientes = sum(1 for t in targets.values() if not t.tiene_turno)
                log("LOG", "sistema", f"modo {modo.upper()} — {len(targets)} chofer(es), "
                    f"{pendientes} sin turno"
                    + (f" — objetivo {fecha}" if fecha else " — cualquier fecha en franja"))
                modo_anterior = modo

            if agresivo:
                ciclo_agresivo(targets, fecha, dry)
                espera = cfg.get("poll_agresivo_seg", POLL_AGRESIVO_SEG)
            else:
                ciclo_latente(targets, fecha, dry)
                espera = cfg.get("poll_latente_seg", POLL_LATENTE_SEG) \
                    + random.uniform(0, JITTER_LATENTE_SEG)
            time.sleep(espera)

        except KeyboardInterrupt:
            log("LOG", "sistema", "detenido (KeyboardInterrupt)")
            break
        except Exception as e:
            log("ERROR", "sistema", f"error en el ciclo: {e}; sigo")
            time.sleep(5)


if __name__ == "__main__":
    main()
