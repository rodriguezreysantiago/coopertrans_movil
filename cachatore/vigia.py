"""vigia.py — daemon 24/7 del sniper de turnos YPF (cachatore).

A diferencia de `orquestador.py` (one-shot: espera el drop, caza y cierra),
este proceso queda **LATENTE las 24 hs** en la PC dedicada del bot:

- **Latente** (todo el día): barre cada ~5 s TODA la worklist — tanto agendar a
  los que no tienen turno como reagendar a los marcados. Si alguien CANCELA y se
  libera un turno en la franja de un chofer que lo necesita, lo agarra al toque
  — sin esperar al drop de las 10:30.
- **Agresivo** (alrededor de `hora_inicio`): cada chofer sin turno escanea su
  propia agenda a full y reserva apenas aparece un slot en su franja (igual que
  el orquestador, para ganar la pulseada del drop). Pasada la ventana, vuelve
  solo a latente.
- **Reagendar**: si un chofer tiene `reagendar:true`, mueve su turno a un slot
  de su franja apenas se libere uno (sin formulario, lo reasigna directo).

**Config**: por defecto la lee de **Firestore** (lo que escribe la UI de la app:
`CACHATORE_CONFIG/global` + `CACHATORE_OBJETIVOS`), y le devuelve el estado en
vivo (latido `CACHATORE_ESTADO/bot` + estado por chofer). Con `--archivo` usa
`drop.json` local (sin escribir a Firestore) — para correr suelto/testeo. Si
Firestore no responde, cae a `drop.json` igual. La config se relee cada ~30 s
(el barrido de ~5 s pega contra iTurnos, NO contra Firestore).

Todo el día además:
- Re-trae de Firestore (cada ~10 min) la unidad/mail de cada chofer: si en la
  app le reasignan el camión, el vigía lo toma solo.
- Re-chequea `mis_turnos` (de a poco, para no bloquear): así sabe quién ya tiene
  turno y nunca dobla reserva ni pierde el estado si el servicio se reinicia.

Uso:
    python vigia.py                 # daemon 24/7 (config de Firestore / UI)
    python vigia.py --archivo       # config de drop.json local (no toca Firestore)
    python vigia.py --dry           # no reserva/reagenda ni escribe estado
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
import nube

# Logs en UTF-8: NSSM captura stdout a logs/vigia.log y la ventana de logs lo
# lee como UTF-8. Sin esto, en Windows el stdout redirigido sale en cp1252 y los
# acentos/ñ de los nombres de choferes salen como mojibake.
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

_DIR = os.path.dirname(os.path.abspath(__file__))
DROP_CONFIG = os.path.join(_DIR, "drop.json")

# Cadencias (se pueden pisar desde la config).
POLL_AGRESIVO_SEG = 1.5      # en la ventana del drop: re-escaneo rápido por chofer
POLL_LATENTE_SEG = 5.0       # resto del día: barre la worklist cada ~5 s
JITTER_LATENTE_SEG = 1.0     # + ruido chico (para no pegar siempre al mismo seg)
DROP_DURACION_MIN = 20       # largo de la ventana agresiva si no se especifica

LOGIN_REINTENTOS = 3
REFRESH_CONFIG_SEG = 30      # cada cuánto releer la worklist (Firestore/archivo)
REFRESH_TURNOS_SEG = 600     # cada cuánto re-chequear mis_turnos de cada chofer
REFRESH_DATOS_SEG = 600      # cada cuánto re-traer unidad/mail de Firestore
HEARTBEAT_SEG = 5            # latido del bot: SIEMPRE cada ~5 s
MAX_REFRESH_POR_CICLO = 2    # cuántos mis_turnos refrescar por ciclo (no bloquear)
MONITOR_BATCH = 10           # cuántos choferes del monitor escanear por ciclo
ESPERA_SIN_CONFIG_SEG = 30   # si falta config / no hay choferes / pausado

_log_lock = threading.Lock()
_scanner = {"cli": None, "logueado": False}   # sesión dedicada al escaneo latente
_monitor: dict = {}          # {dni: Monitor} — turnos reales de TODOS los choferes

# Seteados en main() según los flags.
_USAR_NUBE = True            # leer config de Firestore (False = drop.json)
_ESCRIBIR_ESTADO = False     # escribir latido/estado a Firestore


def log(tag: str, quien: str, msg: str):
    with _log_lock:
        print(f"{tag}:[{datetime.now():%Y-%m-%d %H:%M:%S}] [{quien}] {msg}", flush=True)


def resolver_fecha(valor):
    """`fecha`: null=cualquier fecha en la franja; 'hoy'/'manana' se re-resuelven
    cada día (útil 24/7); o una fecha puntual 'AAAA-MM-DD'."""
    if not valor:
        return None
    v = str(valor).strip().lower()
    if v in ("hoy", "today"):
        return datetime.now().strftime("%Y-%m-%d")
    if v in ("manana", "mañana", "tomorrow"):
        return (datetime.now() + timedelta(days=1)).strftime("%Y-%m-%d")
    return str(valor)


def _leer_config_archivo(ultimo):
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


def leer_config(ultimo):
    """Config (worklist) desde Firestore (UI de la app) o drop.json."""
    if _USAR_NUBE:
        try:
            return nube.leer_config_nube()
        except Exception as e:
            log("LOG", "sistema",
                f"no pude leer config de Firestore ({e}); pruebo drop.json")
            return _leer_config_archivo(ultimo)
    return _leer_config_archivo(ultimo)


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
    __slots__ = ("dni", "nombre", "email", "clave", "patente", "fecha",
                 "franja", "reagendar", "cli", "logueado", "tiene_turno", "uuid",
                 "reagendar_hecho", "ultimo_check", "estado_reportado")

    def __init__(self, ch: dict, fecha, franja: str, reagendar: bool):
        self.dni = ch["dni"]
        self.nombre = ch.get("nombre") or ch["dni"]
        self.email = (ch.get("email") or "").strip().lower()
        self.clave = ch.get("clave")
        self.patente = ch.get("patente")
        self.fecha = fecha          # 'AAAA-MM-DD' | 'hoy' | 'manana' | None
        self.franja = franja
        self.reagendar = reagendar
        self.cli = None
        self.logueado = False
        self.tiene_turno = False
        self.uuid = None
        self.reagendar_hecho = False
        self.ultimo_check = 0.0
        self.estado_reportado = None

    @property
    def credenciales_ok(self) -> bool:
        return bool(self.email and self.clave)


# ---- reporte de estado a Firestore (lo lee la UI) -------------------------
def _fmt_cuando(fecha_iso, hora):
    """'2026-05-20' + '17:00' → '20-05-2026 17:00 hs.' (formato AR legible)."""
    try:
        y, m, d = fecha_iso.split("-")
        return f"{d}-{m}-{y} {hora} hs."
    except Exception:
        return f"{fecha_iso} {hora}"


def _reportar_estado(t: "Target", estado: str, hora=None, detalle=None,
                     cuando=None):
    """Escribe el estado del chofer en Firestore (dedupe: solo si cambió, o si
    viene hora/cuando nuevos). `cuando` = texto legible del turno. No-op si no
    estamos escribiendo estado."""
    if estado == t.estado_reportado and hora is None and cuando is None:
        return
    t.estado_reportado = estado
    if not _ESCRIBIR_ESTADO:
        return
    try:
        nube.escribir_estado_chofer(t.dni, estado, hora=hora, detalle=detalle,
                                    cuando=cuando)
    except Exception as e:
        log("LOG", t.nombre, f"no pude escribir estado: {e}")


def _reportar_dni(dni: str, estado: str):
    """Igual que _reportar_estado pero para un DNI que NO llegó a ser Target
    (ej. sin credenciales/patente — se reporta para que la UI lo muestre)."""
    if not _ESCRIBIR_ESTADO:
        return
    try:
        nube.escribir_estado_chofer(dni, estado)
    except Exception:
        pass


def _publicar_turno(dni, nombre, turno: dict):
    """Publica el turno REAL del chofer en CACHATORE_TURNOS (lo lee la pantalla
    'Turnos concretados'). turno = item de mis_turnos()."""
    if not _ESCRIBIR_ESTADO:
        return
    try:
        nube.escribir_turno(dni, nombre, turno.get("cuando"), turno.get("hora"),
                            turno.get("uuid"))
    except Exception as e:
        log("LOG", nombre, f"no pude publicar turno: {e}")


def _despublicar_turno(dni):
    """El chofer ya no tiene turno → sacarlo de 'Turnos concretados'."""
    if not _ESCRIBIR_ESTADO:
        return
    try:
        nube.borrar_turno(dni)
    except Exception:
        pass


def _heartbeat(modo: str, targets: dict):
    if not _ESCRIBIR_ESTADO:
        return
    pendientes = sum(1 for t in targets.values() if not t.tiene_turno)
    try:
        nube.escribir_estado_bot(modo, len(targets), pendientes)
    except Exception as e:
        log("LOG", "sistema", f"no pude escribir latido: {e}")


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
        t.tiene_turno = True
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
        _reportar_estado(t, "reservado", hora=slot["hora"],
                         cuando=_fmt_cuando(slot["fecha"], slot["hora"]))
        t.ultimo_check = 0.0   # forzar refrescar_estado → publica el turno real (uuid)
        return True
    if r.get("motivo") == "tomado":
        log("LOG", t.nombre, f"{slot['hora']} lo tomaron, sigo buscando")
    else:
        log("LOG", t.nombre, f"reserva sin confirmar ({r.get('motivo')})")
    return False


def _reservar_async(t: Target, slot: dict, dry: bool):
    if not asegurar_login(t):
        _reportar_estado(t, "login_fallo")
        return
    if intentar_reservar(t, slot, dry) and t.reagendar:
        t.reagendar_hecho = True   # ya quedó en franja al reservar; no hay que mover


def _agresivo_async(t: Target, dry: bool):
    if not asegurar_login(t):
        _reportar_estado(t, "login_fallo")
        return
    try:
        html = t.cli.abrir_agenda()
    except Exception as e:
        log("LOG", t.nombre, f"error leyendo agenda: {e}")
        return
    if 'id="login-form"' in html:
        t.logueado = False
        return
    fobj = resolver_fecha(t.fecha)
    slots = iturnos.slots_en_franja(iturnos.parsear_disponibilidad(html)["slots"], t.franja)
    if fobj:
        slots = [s for s in slots if s["fecha"] == fobj]
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
        _reportar_estado(t, "login_fallo")
        return
    try:
        turnos = t.cli.mis_turnos()
    except Exception as e:
        log("LOG", t.nombre, f"error leyendo mis turnos: {e}")
        return
    if turnos:
        turno = turnos[0]
        t.uuid = turno["uuid"]
        if not t.tiene_turno:
            log("LOG", t.nombre, f"ya tiene turno ({turno.get('cuando') or 'detectado'})")
        t.tiene_turno = True
        _reportar_estado(t, "reagendado" if t.reagendar_hecho else "reservado",
                         hora=turno.get("hora"), cuando=turno.get("cuando"))
        _publicar_turno(t.dni, t.nombre, turno)   # → "Turnos concretados"
    else:
        t.tiene_turno = False
        t.uuid = None
        _reportar_estado(t, "buscando")
        _despublicar_turno(t.dni)
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


# ---- monitor: turnos REALES de TODOS los choferes -------------------------
# La pantalla "Turnos concretados" no sale de los vigilados: el bot chequea
# mis_turnos de CADA chofer (los saque o no el bot, incluso turnos cargados por
# fuera) y los publica en CACHATORE_TURNOS. Los vigilados los publica el Target
# (refrescar_estado); el resto, este monitor (sesión liviana por chofer).
class Monitor:
    __slots__ = ("dni", "nombre", "email", "clave", "cli", "logueado",
                 "ultimo_check", "tiene")

    def __init__(self, ch: dict):
        self.dni = ch["dni"]
        self.nombre = ch.get("nombre") or ch["dni"]
        self.email = (ch.get("email") or "").strip().lower()
        self.clave = ch.get("clave")
        self.cli = None
        self.logueado = False
        self.ultimo_check = 0.0
        self.tiene = None   # None=desconocido | False=sin turno | (uuid,cuando)

    @property
    def credenciales_ok(self) -> bool:
        return bool(self.email and self.clave)


def _login_generico(email, clave):
    cli = iturnos.IturnosClient()
    for _ in range(LOGIN_REINTENTOS):
        try:
            if cli.login(email, clave):
                return cli
        except Exception:
            pass
        time.sleep(1.5)
    return None


def _escanear_monitor_uno(m: "Monitor"):
    if m.cli is None or not m.logueado:
        m.cli = _login_generico(m.email, m.clave)
        m.logueado = m.cli is not None
    m.ultimo_check = time.time()
    if not m.logueado:
        return
    try:
        turnos = m.cli.mis_turnos()
    except Exception as e:
        log("LOG", m.nombre, f"monitor: error mis_turnos: {e}")
        m.logueado = False
        return
    if turnos:
        t0 = turnos[0]
        clave = (t0.get("uuid"), t0.get("cuando"))
        if m.tiene != clave:        # solo escribir si cambió (evita spam)
            m.tiene = clave
            _publicar_turno(m.dni, m.nombre, t0)
    elif m.tiene is not False:
        m.tiene = False
        _despublicar_turno(m.dni)


def sincronizar_monitor(roster: dict, targets: dict):
    """Monitor = roster (TODOS los choferes) MENOS los vigilados (esos los
    publica el Target). Una entrada Monitor por chofer no-vigilado."""
    for dni, ch in roster.items():
        if dni in targets:
            _monitor.pop(dni, None)        # pasó a vigilado → lo maneja el Target
            continue
        m = _monitor.get(dni)
        if m is None:
            _monitor[dni] = Monitor(ch)
        else:                              # refrescar mail/clave por si cambiaron
            if ch.get("email"):
                m.email = ch["email"].strip().lower()
            if ch.get("clave"):
                m.clave = ch["clave"]
            m.nombre = ch.get("nombre") or m.nombre
    for dni in list(_monitor):             # sacar los que ya no van
        if dni not in roster or dni in targets:
            del _monitor[dni]


def ciclo_monitor():
    """Escanea unos pocos choferes vencidos del monitor por ciclo (en paralelo),
    para no bloquear ni golpear de más a iTurnos. Solo si publicamos estado."""
    if not _ESCRIBIR_ESTADO:
        return
    ahora = time.time()
    vencidos = sorted(
        (m for m in _monitor.values()
         if m.credenciales_ok and ahora - m.ultimo_check > REFRESH_TURNOS_SEG),
        key=lambda m: m.ultimo_check)[:MONITOR_BATCH]
    if vencidos:
        _en_paralelo(vencidos, _escanear_monitor_uno, max_hilos=MONITOR_BATCH)


# ---- sincronización de targets con la config (hot reload) -----------------
def sincronizar_targets(cfg: dict, targets: dict):
    deseados = {c["dni"]: c for c in cfg.get("choferes", []) if c.get("dni")}

    for dni in list(targets):                       # sacar los que ya no están
        if dni not in deseados:
            log("LOG", "sistema", f"saco a {targets[dni].nombre} (ya no está en la lista)")
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
        if spec.get("fecha") != t.fecha:
            t.fecha = spec.get("fecha")
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
            t = Target(ch, spec.get("fecha"), franja, bool(spec.get("reagendar")))
            if not t.credenciales_ok:
                log("ERROR", t.nombre, "sin email/clave (revisar en la app/claves.json)")
                _reportar_dni(dni, "sin_credenciales")
                continue
            if not t.patente:
                log("ERROR", t.nombre, "sin patente/unidad asignada en la app")
                _reportar_dni(dni, "sin_patente")
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
def ciclo_agresivo(targets: dict, dry: bool):
    necesitan = [t for t in targets.values()
                 if not t.tiene_turno and t.credenciales_ok and t.patente]
    if necesitan:
        _en_paralelo(necesitan, lambda t: _agresivo_async(t, dry),
                     max_hilos=len(necesitan), timeout=15)


def ciclo_latente(targets: dict, dry: bool):
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
    if not libres:
        return

    # asignar slots LIBRES a los choferes que necesitan turno (uno por slot),
    # respetando la FECHA y la FRANJA de cada chofer.
    usados, asignaciones = set(), []
    for t in targets.values():
        if t.tiene_turno or not t.credenciales_ok or not t.patente:
            continue
        fobj = resolver_fecha(t.fecha)
        cand = [s for s in libres
                if s["iso"] not in usados
                and (fobj is None or s["fecha"] == fobj)
                and iturnos.hora_en_franja(s["hora"], t.franja)]
        if cand:
            usados.add(cand[0]["iso"])
            asignaciones.append((t, cand[0]))
    if asignaciones:
        log("LOG", "sistema",
            f"latente: {len(asignaciones)} slot(s) libre(s) en franja → reservando")
        _en_paralelo(asignaciones, lambda a: _reservar_async(a[0], a[1], dry),
                     max_hilos=len(asignaciones), timeout=25)

    # reagendar: mover el turno de quien lo pidió a su nueva fecha+franja. La
    # disponibilidad de reagendar está en OTRA página (calendario propio), así
    # que se consulta directo (no contra el `libres` de arriba).
    for t in targets.values():
        if not (t.reagendar and t.tiene_turno and t.uuid and not t.reagendar_hecho):
            continue
        if dry:
            log("EXITO", t.nombre, f"[DRY] reagendaría a '{t.franja}' / {t.fecha or 'cualquier fecha'}")
            t.reagendar_hecho = True
            continue
        if not asegurar_login(t):
            continue
        try:
            r = t.cli.reagendar(t.uuid, t.franja, resolver_fecha(t.fecha))
        except Exception as e:
            log("LOG", t.nombre, f"error reagendando: {e}")
            continue
        if r.get("ok"):
            log("EXITO", t.nombre, f"REAGENDADO a {r.get('hora')} (franja '{t.franja}')")
            t.reagendar_hecho = True
            _reportar_estado(t, "reagendado", hora=r.get("hora"))
            t.ultimo_check = 0.0   # refrescar_estado publica el turno nuevo
        elif r.get("motivo") == "tomado":
            log("LOG", t.nombre, f"{r.get('hora')} lo tomaron al reagendar, sigo")
        elif r.get("motivo") != "sin_slot_en_franja":
            log("LOG", t.nombre, f"reagendar sin confirmar ({r.get('motivo')})")


# ---- loop principal -------------------------------------------------------
def main():
    global _USAR_NUBE, _ESCRIBIR_ESTADO
    dry = "--dry" in sys.argv
    forzar_latente = "--latente" in sys.argv
    forzar_agresivo = "--agresivo" in sys.argv
    _USAR_NUBE = "--archivo" not in sys.argv
    _ESCRIBIR_ESTADO = _USAR_NUBE and not dry

    fuente = "Firestore (UI de la app)" if _USAR_NUBE else "drop.json (local)"
    log("LOG", "sistema", f"vigía 24/7 arrancando{' [DRY]' if dry else ''} "
        f"— config: {fuente} (pid {os.getpid()})")

    targets: dict = {}
    roster: dict = {}
    cfg = None
    ultimo_config = 0.0
    ultimo_datos = 0.0
    ultimo_roster = 0.0
    modo_anterior = None

    while True:
        try:
            # 1) refrescar la worklist (config / vigilados) cada REFRESH_CONFIG_SEG
            if cfg is None or time.time() - ultimo_config > REFRESH_CONFIG_SEG:
                nueva = leer_config(cfg)
                if nueva is not None:
                    cfg = nueva
                    sincronizar_targets(cfg, targets)
                ultimo_config = time.time()

            # 2) re-traer unidad/mail de los vigilados (refleja reasignaciones)
            if targets and time.time() - ultimo_datos > REFRESH_DATOS_SEG:
                refrescar_datos_firestore(targets)
                ultimo_datos = time.time()

            # 3) MONITOR: turnos reales de TODOS los choferes (no solo vigilados).
            #    Read-only, independiente de la config y del interruptor. Solo si
            #    publicamos estado (en dry/--archivo no).
            if _ESCRIBIR_ESTADO and (not roster
                                     or time.time() - ultimo_roster > REFRESH_DATOS_SEG):
                try:
                    roster = {c["dni"]: c for c in choferes.cargar_choferes()}
                except Exception as e:
                    log("LOG", "sistema", f"error cargando roster: {e}")
                sincronizar_monitor(roster, targets)
                ultimo_roster = time.time()
            ciclo_monitor()

            # 4) re-chequear mis_turnos de los vigilados de a poco (no bloquear)
            vencidos = sorted(
                (t for t in targets.values()
                 if time.time() - t.ultimo_check > REFRESH_TURNOS_SEG),
                key=lambda t: t.ultimo_check)[:MAX_REFRESH_POR_CICLO]
            for t in vencidos:
                refrescar_estado(t)

            activo = bool(cfg.get("activo", True)) if cfg else False

            # El drop time ya no importa: SIEMPRE latente (barre cada ~5 s).
            # `--agresivo` sigue disponible para testeo manual. La fecha y la
            # franja son POR CHOFER (no globales).
            en_drop = forzar_agresivo

            if not targets:
                modo = "idle"
            elif not activo:
                modo = "pausado"
            elif en_drop:
                modo = "agresivo"
            else:
                modo = "latente"

            if modo != modo_anterior:
                pend = sum(1 for t in targets.values() if not t.tiene_turno)
                log("LOG", "sistema", f"modo {modo.upper()} — {len(targets)} chofer(es), "
                    f"{pend} sin turno (fecha/franja por chofer)")
                modo_anterior = modo

            # 4) actuar según modo
            if modo == "agresivo":
                ciclo_agresivo(targets, dry)
                espera = cfg.get("poll_agresivo_seg", POLL_AGRESIVO_SEG)
            elif modo == "latente":
                ciclo_latente(targets, dry)
                espera = cfg.get("poll_latente_seg", POLL_LATENTE_SEG) \
                    + random.uniform(0, JITTER_LATENTE_SEG)
            else:  # idle / pausado: el bot no toca nada (pero late igual)
                espera = HEARTBEAT_SEG

            # 5) latido cada ciclo (~5 s) para que la UI sepa que está vivo
            _heartbeat(modo, targets)

            time.sleep(espera)

        except KeyboardInterrupt:
            log("LOG", "sistema", "detenido (KeyboardInterrupt)")
            break
        except Exception as e:
            log("ERROR", "sistema", f"error en el ciclo: {e}; sigo")
            time.sleep(5)


if __name__ == "__main__":
    main()
