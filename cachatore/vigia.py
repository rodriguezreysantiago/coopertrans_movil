"""vigia.py — daemon 24/7 del sniper de turnos YPF (cachatore).

A diferencia de `orquestador.py` (one-shot: espera el drop, caza y cierra),
este proceso queda **LATENTE las 24 hs** en la PC dedicada del bot:

- **Latente** (todo el día): barre cada ~5 s TODA la worklist — tanto agendar a
  los que no tienen turno como reagendar a los marcados. Si alguien CANCELA y se
  libera un turno en la franja de un chofer que lo necesita, lo agarra al toque
  — sin esperar al drop de las 10:30.
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

Logs con formato "[dd/mm HH:MM:SS] TAG [quien] msg" (TAG = LOG/EXITO/ERROR,
lo colorea el visor). Mismo arranque que el auto-update (fecha primero).
La hora local del equipo se asume ART (igual que el bot en la PC dedicada).
"""
import json
import os
import random
import sys
import threading
import time
from datetime import datetime, timedelta, timezone

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
POLL_LATENTE_SEG = 5.0       # barre la worklist cada ~5 s (único ritmo del bot)
JITTER_LATENTE_SEG = 1.0     # + ruido chico (para no pegar siempre al mismo seg)

LOGIN_REINTENTOS = 3
REFRESH_CONFIG_SEG = 30      # cada cuánto releer la worklist (Firestore/archivo)
REFRESH_TURNOS_SEG = 600     # cada cuánto re-chequear mis_turnos de cada chofer
REFRESH_DATOS_SEG = 600      # cada cuánto re-traer unidad/mail de Firestore
HEARTBEAT_SEG = 5            # sleep base del loop en idle/pausado
LATIDO_SEG = 30             # cada cuánto ESCRIBIR el latido a Firestore. La UI
                            # considera vivo si latió hace <120 s, asi que no
                            # hace falta cada ciclo (serian ~17k writes/dia).
LATIDO_LOG_SEG = 60         # cada cuánto LOGUEAR un latido VISIBLE en la ventana
                            # (1 por minuto, igual que el heartbeat del bot de
                            # WhatsApp). El de arriba (30 s) es para la app; este
                            # es para que un humano que mira los logs vea "sigo
                            # vivo y laburando" sin abrir la app. En latente el
                            # loop barre cada ~5 s pero solo logueaba al CAMBIAR
                            # de modo -> podia quedar mudo horas y daba dudas.
BUSQUEDA_LOG_SEG = 30       # cada cuánto LOGUEAR la búsqueda latente (reserva):
                            # cuando hay choferes SIN turno, mostrar que el bot
                            # está buscando huecos y QUÉ ve (agenda vacía / huecos
                            # fuera de franja). Más seguido que el latido (60 s)
                            # porque con el latido solo, entre barridos de ~5 s
                            # "parecía colgado" (Santiago 2026-05-22). Misma idea
                            # que el log de reagendar, pero a nivel ciclo.
BACKOFF_MAX_SEG = 120       # tope del backoff cuando el scanner no puede loguear
MAX_REFRESH_POR_CICLO = 2    # cuántos mis_turnos refrescar por ciclo (no bloquear)
MAX_CHEQUEOS_POR_CICLO = 3   # cuántos chequeos one-shot procesar por ciclo (no
                             # bloquear el latente: cada chequeo es 1 login +
                             # 1 mis_turnos, ~3-8 s contra Cloudflare).
CHEQUEO_TTL_SEG = 120        # tras resolver un chequeo, la UI tiene 2 min para
                             # leerlo y borrarlo; si no, lo limpia el bot.
HORA_RESUMEN = 8             # hora ART del resumen diario de turnos al encargado
ESPERA_SIN_CONFIG_SEG = 30   # si falta config / no hay choferes / pausado

_log_lock = threading.Lock()
_scanner = {"cli": None, "logueado": False, "dni": None}  # escaneo: un chofer SIN turno
_ultimo_log_busqueda = 0.0   # throttle del log "buscando turno" (reserva latente)

# Seteados en main() según los flags.
_USAR_NUBE = True            # leer config de Firestore (False = drop.json)
_ESCRIBIR_ESTADO = False     # escribir latido/estado a Firestore


def log(tag: str, quien: str, msg: str):
    # Formato unificado con el auto-update: fecha PRIMERO entre corchetes
    # (dd/mm, sin anio), despues el tag (LOG/EXITO/ERROR, lo colorea el visor)
    # y el quien. Asi todas las lineas (cachatore + auto-update) arrancan igual.
    with _log_lock:
        print(f"[{datetime.now():%d/%m %H:%M:%S}] {tag} [{quien}] {msg}", flush=True)


def _log_reagendar_motivo(t, msg: str):
    """Loguea POR QUÉ el reagendar de `t` no avanza, throttled ~cada 2 min por
    chofer (con el barrido de ~5 s, sin throttle inundaría la ventana). Antes
    estos casos eran SILENCIOSOS → 'no hizo nada' sin explicación."""
    if time.time() - t.reagendar_ultimo_log < 120:
        return
    t.reagendar_ultimo_log = time.time()
    log("LOG", t.nombre, f"reagendar: {msg}")


def _etiqueta_pendientes(pendientes) -> str:
    """Texto corto de a quién le buscamos turno (para el log de búsqueda)."""
    if len(pendientes) == 1:
        t = pendientes[0]
        return f"{t.nombre} (franja '{t.franja}', {t.fecha or 'cualquier fecha'})"
    return f"{len(pendientes)} chofer(es) sin turno"


def _log_busqueda(msg: str):
    """Loguea la búsqueda latente (reserva) throttled ~cada BUSQUEDA_LOG_SEG.
    Muestra que el bot sigue buscando huecos y qué encuentra, para que entre
    latidos NO parezca colgado. Mismo espíritu que _log_reagendar_motivo, pero
    a nivel ciclo (no por chofer)."""
    global _ultimo_log_busqueda
    if time.time() - _ultimo_log_busqueda < BUSQUEDA_LOG_SEG:
        return
    _ultimo_log_busqueda = time.time()
    log("LOG", "sistema", msg)


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


def semanas_a_escanear(pendientes, max_semanas=4, hoy=None):
    """Fechas-ancla (un día por semana) que el scanner debe consultar en la
    agenda de reserva.

    iTurnos pagina la agenda POR SEMANA: `abrir_agenda(None)` trae la semana
    actual y `abrir_agenda('AAAA-MM-DD')` la semana que contiene esa fecha (?d=).
    Sin esto el scanner solo miraba la semana actual y NO tomaba los turnos que
    caían en la siguiente (bug 2026-05-30 "los turnos aparecen la semana que viene").

    Siempre incluye la semana actual (None). Por cada pendiente con fecha PUNTUAL
    a futuro suma la semana de esa fecha; si hay alguno con fecha 'cualquiera'
    (None) suma las próximas 2 semanas para darle opciones hacia adelante. Dedup
    por semana (lunes) y cap en `max_semanas` GETs por ciclo (gentil con
    Cloudflare). Devuelve p.ej. [None, '2026-06-01', ...] (None = semana actual)."""
    hoy = hoy or datetime.now().date()

    def lunes(d):
        return d - timedelta(days=d.weekday())

    lunes_hoy = lunes(hoy)
    semanas = {lunes_hoy}
    hay_cualquiera = False
    for t in pendientes:
        f = resolver_fecha(getattr(t, "fecha", None))
        if f is None:
            hay_cualquiera = True
            continue
        try:
            d = datetime.strptime(f, "%Y-%m-%d").date()
        except (ValueError, TypeError):
            continue
        if d >= hoy:
            semanas.add(lunes(d))
    if hay_cualquiera:
        semanas.add(lunes(hoy + timedelta(days=7)))
        semanas.add(lunes(hoy + timedelta(days=14)))
    anclas = []
    for l in sorted(semanas)[:max_semanas]:
        anclas.append(None if l == lunes_hoy else l.strftime("%Y-%m-%d"))
    return anclas


def fecha_objetivo_pasada(fecha_str) -> bool:
    """True si la fecha del objetivo es ESTRICTAMENTE anterior a hoy local.

    Post-mortem 2026-05-28 (corte de luz 27-may): 2 objetivos vencidos
    (CELIZ + VOGEL, ambos con `fecha=2026-05-27`) quedaron en loop "buscando"
    cuando volvió el bot. `mis_turnos()` no devuelve los CONCRETADOS, el
    flag en memoria `turno_conseguido` se perdió en el reinicio, y la fecha
    pasada hizo que `slot_es_futuro` filtre todo → loop infinito sin chance
    de cerrar ciclo.

    Tratamiento: en `sincronizar_targets` descartamos los objetivos con
    fecha pasada (borra de Firestore + saca de la worklist viva).

    Casos:
    - None / '' → False (`cualquier fecha` — no cierra).
    - 'hoy' / 'manana' → False (siempre se resuelven en el día).
    - 'AAAA-MM-DD' → True si < hoy local.
    - Cualquier otro string que no parsee → False (no romper por dato raro).
    """
    if not fecha_str:
        return False
    v = str(fecha_str).strip().lower()
    if v in ("hoy", "today", "manana", "mañana", "tomorrow"):
        return False
    hoy = datetime.now().strftime("%Y-%m-%d")
    return v < hoy


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


class Target:
    """Estado de un chofer vigilado. Objetivo: tener un turno en su franja."""
    __slots__ = ("dni", "nombre", "email", "clave", "patente", "fecha",
                 "franja", "reagendar", "cli", "logueado", "tiene_turno", "uuid",
                 "reagendar_hecho", "ultimo_check", "estado_reportado", "notificar",
                 "turno_hora", "turno_cuando", "turno_conseguido", "vacios_seguidos",
                 "ciclo_completo", "cancelar_pedido", "reagendar_ultimo_log")

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
        self.notificar = None   # None | 'reservado' | 'reagendado' (aviso pendiente)
        self.turno_hora = None      # 'HH:MM' del turno actual (si tiene)
        self.turno_cuando = None    # texto legible del turno actual
        self.turno_conseguido = False  # ¿alguna vez consiguió turno en este ciclo?
        self.vacios_seguidos = 0       # lecturas de mis_turnos vacías seguidas
        self.ciclo_completo = False    # turno usado/finalizado → sacarlo del ciclo
        self.cancelar_pedido = False   # la app pidió cancelar el turno (+ iTurnos)
        self.reagendar_ultimo_log = 0.0  # throttle del log "por qué no reagenda"

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


def _avisar_turno(t, evento: str, cuando):
    """Encola los avisos WhatsApp (chofer + encargado de logística) al conseguir
    (`reservado`) o reprogramar (`reagendado`) el turno. No-op en dry/--archivo."""
    if not _ESCRIBIR_ESTADO:
        return
    try:
        nube.avisar_turno(t.dni, t.nombre, cuando, evento)
        log("EXITO", t.nombre, f"aviso WhatsApp encolado ({evento})")
    except Exception as e:
        log("LOG", t.nombre, f"no pude encolar aviso WhatsApp: {e}")


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
    """Sesión para el escaneo latente de la agenda. CLAVE (verificado en vivo
    2026-05-21): iTurnos muestra disponibilidad POR USUARIO — un chofer que YA
    tiene turno ve CERO huecos libres. Por eso el scanner DEBE loguearse como un
    chofer SIN turno (pendiente); si no, queda ciego y el bot nunca reserva para
    los que esperan ("hay lugares y no toma ninguno"). Entre los pendientes la
    agenda se ve igual (todos sin turno) → basta UNO de scanner y no
    multiplicamos requests a Cloudflare."""
    # El scanner cacheado solo sirve si su chofer SIGUE sin turno (si sacó turno
    # mientras era scanner, ahora ve 0 → hay que re-loguear con otro pendiente).
    if (_scanner["cli"] is not None and _scanner["logueado"]
            and any(t.dni == _scanner["dni"] and not t.tiene_turno
                    for t in targets.values())):
        return _scanner["cli"]
    cred = next((t for t in targets.values()
                 if t.credenciales_ok and not t.tiene_turno), None)
    if cred is None:
        # nadie sin turno → no hay nada para reservar; soltar la sesión vieja.
        _scanner.update(cli=None, logueado=False, dni=None)
        return None
    cli = iturnos.IturnosClient()
    for _ in range(LOGIN_REINTENTOS):
        try:
            if cli.login(cred.email, cred.clave):
                _scanner.update(cli=cli, logueado=True, dni=cred.dni)
                return cli
        except Exception as e:
            log("LOG", "scanner", f"login error: {e}")
        time.sleep(1.5)
    log("ERROR", "scanner", "no pudo loguear")
    return None


# ---- reserva / reagendar --------------------------------------------------
def _marcar_reservado(t: Target, hora, fecha=None, cuando=None):
    """Deja al target marcado con turno tras una reserva exitosa y prepara el
    próximo refrescar_estado para que publique el turno real (uuid) y dispare
    el aviso de WhatsApp."""
    t.tiene_turno = True
    if cuando is None and fecha:
        cuando = _fmt_cuando(fecha, hora)
    _reportar_estado(t, "reservado", hora=hora, cuando=cuando)
    t.notificar = "reservado"   # refrescar_estado dispara el aviso WhatsApp
    t.ultimo_check = 0.0   # forzar refrescar_estado → publica el turno real (uuid)


def intentar_reservar(t: Target, slot: dict, dry: bool) -> bool:
    """Reserva `slot` para `t`. reservar() hace el GET /reservar/{ISO} que toma
    el slot en la sesión de ESTE chofer + el POST con patente/DNI/empresa.

    La heurística de éxito del POST es FRÁGIL (depende del HTML de respuesta).
    Cuando no puede confirmar ('revisar') NO re-intentamos a ciegas: le
    preguntamos a mis_turnos(), que es la fuente autoritativa. Sin esto, un
    falso negativo dejaba al bot reservando en loop cada ~5 s (bug 2026-05-20)
    — con riesgo de doble reserva si la reserva en realidad SÍ había entrado."""
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
        _marcar_reservado(t, slot["hora"], fecha=slot["fecha"])
        return True
    if r.get("motivo") == "tomado":
        log("LOG", t.nombre, f"{slot['hora']} lo tomaron, sigo buscando")
        return False
    # 'revisar': el POST no confirmó por el HTML. Antes de re-intentar (y
    # arriesgar doblar la reserva), preguntamos la VERDAD a mis_turnos.
    try:
        turnos = t.cli.mis_turnos()
    except Exception:
        turnos = None
    if turnos:
        turno = turnos[0]
        t.uuid = turno.get("uuid")
        log("EXITO", t.nombre, f"RESERVADO {turno.get('cuando') or slot['hora']} "
            f"(confirmado por mis_turnos) — unidad {t.patente}")
        _marcar_reservado(t, turno.get("hora") or slot["hora"],
                          cuando=turno.get("cuando"))
        return True
    log("LOG", t.nombre,
        f"reserva sin confirmar (motivo={r.get('motivo')}, status={r.get('status')})")
    return False


def _reservar_async(t: Target, slot: dict, dry: bool):
    if not asegurar_login(t):
        _reportar_estado(t, "login_fallo")
        return
    if intentar_reservar(t, slot, dry) and t.reagendar:
        t.reagendar_hecho = True   # ya quedó en franja al reservar; no hay que mover


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
        t.turno_hora = turno.get("hora")
        t.turno_cuando = turno.get("cuando")
        t.turno_conseguido = True
        t.vacios_seguidos = 0
        if not t.tiene_turno:
            log("LOG", t.nombre, f"ya tiene turno ({turno.get('cuando') or 'detectado'})")
        t.tiene_turno = True
        _reportar_estado(t, "reagendado" if t.reagendar_hecho else "reservado",
                         hora=turno.get("hora"), cuando=turno.get("cuando"))
        _publicar_turno(t.dni, t.nombre, turno)   # → "Turnos concretados"
        if t.notificar:   # el bot recién consiguió/reprogramó → avisar (1 vez)
            _avisar_turno(t, t.notificar, turno.get("cuando"))
            t.notificar = None
    elif t.turno_conseguido:
        # Tenía turno y ya NO aparece en mis_turnos → se concretó/ausentó/canceló
        # (cualquier estado que NO sea "reagendado", que seguiría como reservado).
        # La lista es CÍCLICA: cerramos el ciclo y el chofer DESAPARECE (lo saca
        # el loop principal). Confirmamos con 2 lecturas vacías seguidas para no
        # cerrar por un blip puntual; NO volvemos a "buscando" (no re-reservar).
        t.vacios_seguidos += 1
        if t.vacios_seguidos >= 2:
            t.ciclo_completo = True
    else:
        t.tiene_turno = False
        t.uuid = None
        t.turno_hora = None
        t.turno_cuando = None
        _reportar_estado(t, "buscando")
        _despublicar_turno(t.dni)
        t.notificar = None   # perdió el turno antes de avisar → cancelar aviso
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


# ---- sincronización de targets con la config (hot reload) -----------------
def sincronizar_targets(cfg: dict, targets: dict):
    deseados = {c["dni"]: c for c in cfg.get("choferes", []) if c.get("dni")}

    # Guard fecha pasada (post-mortem corte de luz 2026-05-28): si un
    # objetivo quedó colgado con `fecha < hoy`, cerramos el ciclo solos.
    # Sin esto, el bot intenta reservar para una fecha pasada — `slot_es_futuro`
    # filtra todo → loop infinito "buscando" sin posibilidad de cerrar (porque
    # `mis_turnos()` no trae los CONCRETADOS y el flag `turno_conseguido` es
    # in-memory y se pierde al reiniciar).
    for dni in list(deseados):
        if fecha_objetivo_pasada(deseados[dni].get("fecha")):
            nombre = deseados[dni].get("nombre") or dni
            fecha = deseados[dni].get("fecha")
            log("LOG", nombre,
                f"objetivo con fecha pasada ({fecha}) → cierro ciclo")
            try:
                nube.eliminar_objetivo(dni)
            except Exception as e:
                log("LOG", "sistema",
                    f"no pude borrar objetivo de {nombre} ({dni}): {e}")
            _despublicar_turno(dni)
            deseados.pop(dni)
            # Si estaba en targets vivos, sacarlo también.
            if dni in targets:
                del targets[dni]

    for dni in list(targets):                       # sacar los que ya no están
        if dni not in deseados:
            log("LOG", "sistema", f"saco a {targets[dni].nombre} (ya no está en la lista)")
            del targets[dni]
            _despublicar_turno(dni)   # ya no lo vigilamos → fuera de "Concretados"

    # actualizar franja/reagendar de los que siguen
    for dni, spec in deseados.items():
        t = targets.get(dni)
        if not t:
            continue
        nf = spec.get("franja")
        if iturnos.franja_valida(nf) and nf != t.franja:
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
            if not iturnos.franja_valida(franja):
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

    # flag de cancelación (lo setea la app en el objetivo; lo procesa el loop
    # principal: cancela en iTurnos y saca al chofer del ciclo).
    for dni, spec in deseados.items():
        t = targets.get(dni)
        if t is not None:
            t.cancelar_pedido = bool(spec.get("cancelar"))

    # barrido de estado de los recién agregados (evita doble reserva / arranca
    # sabiendo quién ya tiene turno; corre en paralelo para no demorar).
    sin_chequear = [t for t in targets.values() if t.ultimo_check == 0.0]
    if sin_chequear:
        log("LOG", "sistema", f"chequeando turnos actuales de {len(sin_chequear)} chofer(es)…")
        _en_paralelo(sin_chequear, refrescar_estado, max_hilos=10)


# ---- chequeos one-shot ----------------------------------------------------
def _procesar_chequeo(ch: dict, dry: bool):
    """Procesa un pedido manual de la app: ¿este chofer (que NO está en la
    lista del cachatore) tiene un turno preexistente sacado por la web?
    Caso real: un compañero del chofer reserva turno desde iTurnos sin pasar
    por el bot — sin esto, el operador no puede reagendar/cancelar ese turno
    desde la app porque no aparece en ningún lado.

    Login + mis_turnos one-shot (cliente nuevo, sin tocar scanner ni targets
    vivos). Si tiene turno: publica TURNO + crea OBJETIVO 'detectado_externo';
    si no: solo escribe `resultado='sin_turno'`. En ambos casos la UI escucha
    el doc CACHATORE_CHEQUEOS/{dni} y le muestra el resultado al operador."""
    dni = ch["dni"]
    nombre = ch.get("nombre") or dni
    log("LOG", nombre, "chequeo manual pedido desde la app (one-shot)")
    # Traer credenciales del chofer (mismo helper que para los targets vivos).
    try:
        datos = next(iter(choferes.cargar_choferes(solo_dnis=[dni])), None)
    except Exception as e:
        log("ERROR", nombre, f"chequeo: no pude traer datos del chofer: {e}")
        nube.escribir_resultado_chequeo(
            dni, "error", detalle=f"no pude traer datos del chofer: {e}")
        return
    if not datos:
        log("ERROR", nombre,
            "chequeo: chofer no está en la base (tanque/excluido/inactivo)")
        nube.escribir_resultado_chequeo(
            dni, "error",
            detalle="el chofer no está en la base (tanque/excluido/inactivo)")
        return
    email = datos.get("email")
    clave = datos.get("clave")
    patente = datos.get("patente")
    if not email or not clave:
        nube.escribir_resultado_chequeo(
            dni, "error", detalle="el chofer no tiene mail/clave cargada")
        return
    if dry:
        log("EXITO", nombre, "[DRY] chequearía sin tocar iTurnos")
        nube.escribir_resultado_chequeo(dni, "sin_turno", detalle="[DRY]")
        return
    # Cliente one-shot: NO usa la sesión cacheada del scanner ni la de ningún
    # target vivo. Es 1 login extra a iTurnos por chequeo manual (frecuencia
    # baja); a cambio no enredamos el cache del bot ni rompemos al scanner.
    cli = iturnos.IturnosClient()
    logueado = False
    for _ in range(LOGIN_REINTENTOS):
        try:
            if cli.login(email, clave):
                logueado = True
                break
        except Exception as e:
            log("LOG", nombre, f"chequeo: login error transitorio: {e}")
        time.sleep(1.5)
    if not logueado:
        nube.escribir_resultado_chequeo(
            dni, "error",
            detalle="no pude loguear en iTurnos (¿Cloudflare bloqueando?)")
        return
    try:
        turnos = cli.mis_turnos()
    except Exception as e:
        nube.escribir_resultado_chequeo(
            dni, "error", detalle=f"error leyendo mis_turnos: {e}")
        return
    if turnos:
        turno = turnos[0]
        cuando = turno.get("cuando")
        # Publicar el turno y dar de alta al chofer en OBJETIVOS marcándolo
        # como detectado externo. Sin el OBJETIVO los botones Reagendar/
        # Cancelar de la card de Concretados no funcionan (escriben al
        # OBJETIVO). El bot, en el próximo refresh de config, lo va a ver y
        # como ya tiene turno NO le busca otro (refrescar_estado marca
        # tieneTurno=True y ciclo_latente solo procesa pendientes).
        try:
            nube.escribir_turno(dni, nombre, cuando, turno.get("hora"),
                                turno.get("uuid"))
        except Exception as e:
            log("LOG", nombre, f"chequeo: no pude publicar turno: {e}")
        try:
            nube.crear_objetivo_externo(dni, nombre, patente=patente)
        except Exception as e:
            log("LOG", nombre, f"chequeo: no pude crear objetivo externo: {e}")
        log("EXITO", nombre, f"chequeo: YA TIENE TURNO → {cuando}")
        nube.escribir_resultado_chequeo(dni, "con_turno", detalle=cuando)
    else:
        log("LOG", nombre, "chequeo: SIN TURNOS preexistentes en iTurnos")
        nube.escribir_resultado_chequeo(dni, "sin_turno")


# ---- ciclos ---------------------------------------------------------------
def ciclo_latente(targets: dict, dry: bool):
    # --- RESERVA: escanear la agenda y asignar huecos a los que NO tienen turno.
    # El scanner se loguea como un chofer SIN turno (ensure_scanner): iTurnos
    # muestra disponibilidad POR USUARIO y un chofer con turno ve 0 huecos. Si no
    # hay pendientes (ensure_scanner devuelve None) o el scanner no puede leer,
    # NO cortamos acá: el bloque de reagendar de abajo corre igual (usa OTRA
    # página propia de cada chofer y el auto-cancel es un chequeo en memoria).
    # choferes que TODAVÍA necesitan turno (a quién/qué le estamos buscando).
    # Se calcula ANTES del scanner: define qué semanas de la agenda hay que mirar.
    pendientes = [t for t in targets.values()
                  if not t.tiene_turno and t.credenciales_ok and t.patente]

    libres = []
    scanner_ok = False
    cli = ensure_scanner(targets)
    if cli is not None:
        # iTurnos pagina la agenda por semana: barremos la semana actual + las
        # semanas de las fechas que pidieron los pendientes. Sin esto el scanner
        # quedaba ciego a los turnos de la semana siguiente (bug 2026-05-30).
        vistos = set()
        for ancla in semanas_a_escanear(pendientes):
            try:
                html = cli.abrir_agenda(ancla)
            except Exception as e:
                log("LOG", "scanner",
                    f"error leyendo agenda ({ancla or 'semana actual'}): {e}")
                _scanner["logueado"] = False
                break
            if 'id="login-form"' in html:
                _scanner["logueado"] = False
                break
            scanner_ok = True
            for s in iturnos.parsear_disponibilidad(html)["slots"]:
                if s["iso"] not in vistos:
                    vistos.add(s["iso"])
                    libres.append(s)

    # asignar slots LIBRES a los choferes que necesitan turno (uno por slot),
    # respetando la FECHA y la FRANJA de cada chofer.
    asignaciones = []
    if libres and pendientes:
        ahora = datetime.now()
        usados = set()
        for t in pendientes:
            fobj = resolver_fecha(t.fecha)
            # Último turno de la franja primero (ver ordenar_slots_preferidos).
            cand = iturnos.ordenar_slots_preferidos([
                s for s in libres
                if s["iso"] not in usados
                and (fobj is None or s["fecha"] == fobj)
                and iturnos.hora_en_franja(s["hora"], t.franja)
                and iturnos.slot_es_futuro(s, ahora)
            ])
            if cand:
                usados.add(cand[0]["iso"])
                asignaciones.append((t, cand[0]))
        if asignaciones:
            log("LOG", "sistema",
                f"latente: {len(asignaciones)} slot(s) libre(s) en franja → reservando")
            _en_paralelo(asignaciones, lambda a: _reservar_async(a[0], a[1], dry),
                         max_hilos=len(asignaciones), timeout=25)

    # Mostrar la BÚSQUEDA cuando hay alguien esperando turno pero no reservamos
    # nada: agenda vacía o huecos fuera de su franja/fecha. Throttled (sino el
    # barrido de ~5 s inundaría). Sin esto, entre latidos parecía colgado.
    if pendientes and not asignaciones:
        etiqueta = _etiqueta_pendientes(pendientes)
        if not scanner_ok:
            pass  # no logueó la agenda: el "sin login (¿Cloudflare?)" + backoff
                  # del loop principal ya cubre ese caso (no duplicar acá).
        elif libres:
            _log_busqueda(f"buscando turno para {etiqueta}: la agenda tiene "
                          f"{len(libres)} hueco(s) libre(s), pero ninguno en su "
                          f"franja/fecha todavía")
        else:
            _log_busqueda(f"buscando turno para {etiqueta}: la agenda no tiene "
                          f"huecos libres ahora (sigo barriendo cada ~5s)")

    # reagendar: mover el turno de quien lo pidió a su nueva fecha+franja. La
    # disponibilidad de reagendar está en OTRA página (calendario propio), así
    # que se consulta directo (no contra el `libres` de arriba).
    for t in targets.values():
        if not t.reagendar or t.reagendar_hecho:
            continue   # no pidió reagendar / ya se movió → ni lo miramos
        # Pidió reagendar pero falta algo para poder hacerlo → AVISAR (antes era
        # un skip silencioso que se veía como "no hace nada").
        if not t.tiene_turno:
            _log_reagendar_motivo(t, "todavía sin turno (primero hay que "
                                  "conseguir uno para poder moverlo)")
            continue
        if not t.uuid:
            _log_reagendar_motivo(t, "todavía no tengo el id del turno (se carga "
                                  "al chequear mis_turnos; si el bot recién "
                                  "arrancó, esperá un toque)")
            continue
        # ¿El turno actual YA cae en la franja/fecha pedida? Entonces no hay nada
        # que mover -> cancelamos solo el reagendar (y la UI deja de mostrar
        # "buscando reagendar"). Cubre el caso de reagendar a mano por fuera del
        # bot (Santiago 2026-05-21).
        if iturnos.turno_en_objetivo(t.turno_hora, t.turno_cuando, t.franja,
                                     resolver_fecha(t.fecha)):
            log("EXITO", t.nombre,
                "el turno ya esta en la franja/fecha pedida -> cancelo reagendar")
            t.reagendar_hecho = True
            t.reagendar = False
            if _ESCRIBIR_ESTADO:
                try:
                    nube.cancelar_reagendar(t.dni)
                except Exception as e:
                    log("LOG", t.nombre, f"no pude cancelar reagendar en la base: {e}")
            continue
        if dry:
            log("EXITO", t.nombre, f"[DRY] reagendaría a '{t.franja}' / {t.fecha or 'cualquier fecha'}")
            t.reagendar_hecho = True
            continue
        if not asegurar_login(t):
            continue
        try:
            # franja_actual: si la franja es 'cualquiera', excluye la franja del
            # turno actual → mover a OTRA franja (no quedarse donde ya está).
            r = t.cli.reagendar(t.uuid, t.franja, resolver_fecha(t.fecha),
                                franja_actual=iturnos.franja_de_hora(t.turno_hora))
        except Exception as e:
            log("LOG", t.nombre, f"error reagendando: {e}")
            continue
        if r.get("ok"):
            log("EXITO", t.nombre, f"REAGENDADO a {r.get('hora')} (franja '{t.franja}')")
            t.reagendar_hecho = True
            t.reagendar = False   # ya se movió → apagar el flag. CLAVE para
            if _ESCRIBIR_ESTADO:  # 'cualquiera' (que no auto-cancela): si no, al
                try:              # reiniciar el bot lo volvería a sacar de franja.
                    nube.cancelar_reagendar(t.dni)
                except Exception as e:
                    log("LOG", t.nombre, f"no pude apagar reagendar en la base: {e}")
            _reportar_estado(t, "reagendado", hora=r.get("hora"))
            t.notificar = "reagendado"
            t.ultimo_check = 0.0   # refrescar_estado publica el turno nuevo + avisa
        elif r.get("motivo") == "tomado":
            log("LOG", t.nombre, f"{r.get('hora')} lo tomaron al reagendar, sigo")
        elif r.get("motivo") == "sin_slot_en_franja":
            ofrece = r.get("ofrece") or []
            detalle = ("  El calendario de reagendar SÍ ofrece: "
                       + "; ".join(ofrece)) if ofrece else \
                "  El calendario de reagendar vino VACÍO (0 huecos para mover)."
            _log_reagendar_motivo(
                t, f"el calendario de reagendar NO tiene slot en franja "
                   f"'{t.franja}'{(' / ' + t.fecha) if t.fecha else ''}.{detalle}")
        else:
            log("LOG", t.nombre, f"reagendar sin confirmar ({r.get('motivo')})")


# ---- loop principal -------------------------------------------------------
def main():
    global _USAR_NUBE, _ESCRIBIR_ESTADO
    dry = "--dry" in sys.argv
    _USAR_NUBE = "--archivo" not in sys.argv
    _ESCRIBIR_ESTADO = _USAR_NUBE and not dry

    fuente = "Firestore (UI de la app)" if _USAR_NUBE else "drop.json (local)"
    log("LOG", "sistema", f"vigía 24/7 arrancando{' [DRY]' if dry else ''} "
        f"— config: {fuente} (pid {os.getpid()})")

    targets: dict = {}
    cfg = None
    ultimo_config = 0.0
    ultimo_datos = 0.0
    ultimo_resumen = None     # 'YYYY-MM-DD' del último resumen diario al encargado
    modo_anterior = None
    ultimo_latido = 0.0       # último latido escrito (para throttlear el heartbeat)
    ultimo_latido_log = time.time()  # último latido LOGUEADO (visible en la ventana)
    fallos_scanner = 0        # logins fallidos seguidos del scanner (para backoff)
    reconciliado = False      # limpieza one-shot de turnos viejos de no-vigilados

    while True:
        try:
            # 1) refrescar la worklist (config / vigilados) cada REFRESH_CONFIG_SEG
            if cfg is None or time.time() - ultimo_config > REFRESH_CONFIG_SEG:
                nueva = leer_config(cfg)
                if nueva is not None:
                    cfg = nueva
                    sincronizar_targets(cfg, targets)
                ultimo_config = time.time()

            # 1.b) limpieza one-shot al arrancar: sacar de "Concretados" los
            #      turnos de choferes que YA NO vigilamos (quedaron de la versión
            #      vieja que monitoreaba a todos los choferes).
            if _ESCRIBIR_ESTADO and not reconciliado and cfg is not None:
                try:
                    for dni in nube.listar_dnis_turnos():
                        if dni not in targets:
                            _despublicar_turno(dni)
                    reconciliado = True
                except Exception as e:
                    log("LOG", "sistema", f"no pude reconciliar turnos viejos: {e}")

            # 2) re-traer unidad/mail de los vigilados (refleja reasignaciones)
            if targets and time.time() - ultimo_datos > REFRESH_DATOS_SEG:
                refrescar_datos_firestore(targets)
                ultimo_datos = time.time()

            # 3) re-chequear mis_turnos de los vigilados de a poco (no bloquear)
            vencidos = sorted(
                (t for t in targets.values()
                 if time.time() - t.ultimo_check > REFRESH_TURNOS_SEG),
                key=lambda t: t.ultimo_check)[:MAX_REFRESH_POR_CICLO]
            for t in vencidos:
                refrescar_estado(t)

            # 3.a.bis) PEDIDOS DE CANCELACIÓN (la app marcó cancelar_pedido):
            #          cancela el turno en iTurnos (si lo tiene) y saca al chofer
            #          del ciclo. ⚠️ destructivo. Single-thread acá (no mutar
            #          `targets` desde hilos). Si la cancelación falla, NO lo saca
            #          y reintenta en el próximo refresh de config (throttle).
            for dni in [d for d, t in targets.items() if t.cancelar_pedido]:
                t = targets[dni]
                if dry:
                    log("EXITO", t.nombre, "[DRY] cancelaría el turno en iTurnos")
                    ok = True
                elif not (t.tiene_turno and t.uuid):
                    ok = True   # no hay turno que cancelar → solo sacarlo del ciclo
                elif not asegurar_login(t):
                    log("LOG", t.nombre, "login falló para cancelar; reintento luego")
                    t.cancelar_pedido = False
                    ok = False
                else:
                    try:
                        # Capturar el turno ANTES de cancelarlo, para avisar.
                        cuando_cancelado = t.turno_cuando
                        r = t.cli.cancelar(t.uuid)
                        ok = bool(r.get("ok"))
                        if ok:
                            log("EXITO", t.nombre,
                                "turno CANCELADO en iTurnos (pedido de la app)")
                            # Avisar por WhatsApp al chofer + encargado de
                            # logística que el turno quedó cancelado (mismo
                            # canal que reservar/reagendar). Solo en cancelación
                            # REAL (no dry, no "sin turno"). 2026-05-22.
                            if _ESCRIBIR_ESTADO:
                                try:
                                    nube.avisar_turno(t.dni, t.nombre,
                                                      cuando_cancelado, "cancelado")
                                except Exception as e:
                                    log("LOG", t.nombre,
                                        f"no pude avisar la cancelación: {e}")
                        else:
                            log("LOG", t.nombre, "cancelación no confirmada "
                                f"({r.get('motivo') or r.get('status')}); reintento luego")
                            t.cancelar_pedido = False
                    except Exception as e:
                        log("LOG", t.nombre, f"error cancelando en iTurnos: {e}")
                        t.cancelar_pedido = False
                        ok = False
                if ok:
                    targets.pop(dni)
                    _despublicar_turno(dni)
                    if _ESCRIBIR_ESTADO:
                        try:
                            nube.eliminar_objetivo(dni)
                        except Exception as e:
                            log("LOG", "sistema", f"no pude sacar objetivo {dni}: {e}")

            # 3.b) cierre de ciclo: los que YA USARON su turno (concretado/
            #      ausente/etc — no reagendado) DESAPARECEN de la lista (es
            #      cíclica; se re-agregan a mano). Acá (single-thread) para no
            #      mutar `targets` desde los hilos de refrescar_estado.
            for dni in [d for d, t in targets.items() if t.ciclo_completo]:
                fin = targets.pop(dni)
                log("LOG", "sistema",
                    f"{fin.nombre}: turno usado/finalizado → lo saco del ciclo")
                _despublicar_turno(dni)
                if _ESCRIBIR_ESTADO:
                    try:
                        nube.eliminar_objetivo(dni)
                    except Exception as e:
                        log("LOG", "sistema", f"no pude sacar objetivo {dni}: {e}")

            # 3.c) CHEQUEOS one-shot pedidos desde el wizard "Agregar" de la
            #      app: ¿este chofer (que NO está en CACHATORE_OBJETIVOS) tiene
            #      un turno preexistente sacado por la web? Procesamos pocos
            #      por ciclo (cada uno hace 1 login + 1 mis_turnos contra
            #      Cloudflare, ~3-8 s). El cleanup TTL borra los resueltos que
            #      la UI no llegó a borrar (operador cerró la app antes).
            if _ESCRIBIR_ESTADO:
                try:
                    pendientes_chequeo = nube.leer_chequeos_pendientes()
                except Exception as e:
                    log("LOG", "sistema", f"no pude leer chequeos: {e}")
                    pendientes_chequeo = []
                for ch in pendientes_chequeo[:MAX_CHEQUEOS_POR_CICLO]:
                    try:
                        _procesar_chequeo(ch, dry)
                    except Exception as e:
                        log("ERROR", ch.get("nombre") or ch.get("dni"),
                            f"chequeo: error inesperado: {e}")
                        try:
                            nube.escribir_resultado_chequeo(
                                ch["dni"], "error",
                                detalle=f"error inesperado: {e}")
                        except Exception:
                            pass
                # Cleanup TTL: si la UI no borró un chequeo ya resuelto en
                # CHEQUEO_TTL_SEG, lo limpia el bot para que no se acumulen.
                try:
                    limite = (datetime.now(timezone.utc)
                              - timedelta(seconds=CHEQUEO_TTL_SEG))
                    for dni_viejo in nube.listar_chequeos_resueltos_viejos(limite):
                        nube.borrar_chequeo(dni_viejo)
                except Exception as e:
                    log("LOG", "sistema",
                        f"no pude limpiar chequeos viejos: {e}")

            activo = bool(cfg.get("activo", True)) if cfg else False

            # Modo simple: idle (sin choferes), pausado (apagado desde la app) o
            # latente. El latente barre cada ~5 s TODA la worklist y caza huecos
            # apenas se liberan — alcanza para el drop sin un modo "agresivo"
            # aparte (Santiago 2026-05-22: sacamos el barrido agresivo, el
            # latente saca bien los turnos).
            if not targets:
                modo = "idle"
            elif not activo:
                modo = "pausado"
            else:
                modo = "latente"

            cambio_modo = modo != modo_anterior
            if cambio_modo:
                pend = sum(1 for t in targets.values() if not t.tiene_turno)
                rea = sum(1 for t in targets.values()
                          if t.reagendar and t.tiene_turno and not t.reagendar_hecho)
                log("LOG", "sistema", f"modo {modo.upper()} — {len(targets)} chofer(es), "
                    f"{pend} sin turno, {rea} para reagendar (fecha/franja por chofer)")
                modo_anterior = modo

            # 4) actuar según modo
            if modo == "latente":
                ciclo_latente(targets, dry)
                espera = cfg.get("poll_latente_seg", POLL_LATENTE_SEG) \
                    + random.uniform(0, JITTER_LATENTE_SEG)
            else:  # idle / pausado: el bot no toca nada (pero late igual)
                espera = HEARTBEAT_SEG

            # 4.b) backoff si el scanner no logra loguear (Cloudflare bloqueando):
            #      no martillar el WAF cada ~5 s — esperar cada vez más (tope
            #      BACKOFF_MAX_SEG). Se resetea apenas vuelve a loguear.
            # solo "usa scanner" si hay choferes SIN turno (algo para reservar):
            # si todos tienen turno, que el scanner no esté logueado NO es falla
            # (no hay a quién reservarle) → no disparar el backoff de Cloudflare.
            hay_pendientes = any(not t.tiene_turno and t.credenciales_ok
                                 for t in targets.values())
            usa_scanner = hay_pendientes and modo == "latente"
            if usa_scanner and not _scanner["logueado"]:
                fallos_scanner += 1
                espera = min(espera * (2 ** min(fallos_scanner, 5)), BACKOFF_MAX_SEG)
                if fallos_scanner == 1 or fallos_scanner % 5 == 0:
                    log("LOG", "scanner",
                        f"sin login (¿Cloudflare?), backoff a {espera:.0f}s "
                        f"(fallo {fallos_scanner})")
            else:
                fallos_scanner = 0

            # 5) latido THROTTLED: ~cada LATIDO_SEG o al cambiar de modo. La UI
            #    considera vivo si latió hace <120 s, así que no escribimos cada
            #    ciclo (eran ~17k writes/día solo para el latido).
            if cambio_modo or time.time() - ultimo_latido >= LATIDO_SEG:
                _heartbeat(modo, targets)
                ultimo_latido = time.time()

            # 5.b) latido VISIBLE en el log (throttled ~cada LATIDO_LOG_SEG): para
            #     que mirando la ventana en vivo se vea que el vigía sigue
            #     laburando, sin tener que abrir la app. El cambio de modo ya
            #     loguea su propia línea, así que acá solo throttleamos por tiempo.
            if time.time() - ultimo_latido_log >= LATIDO_LOG_SEG:
                pend = sum(1 for t in targets.values() if not t.tiene_turno)
                rea = sum(1 for t in targets.values()
                          if t.reagendar and t.tiene_turno and not t.reagendar_hecho)
                con_turno = len(targets) - pend
                # Compacto a propósito: tiene que entrar en UNA línea de la
                # ventana de logs (Santiago 2026-05-29). "3/3 turno" = con
                # turno / total; el "sin turno" se deduce. `rea` = a reagendar.
                log("LOG", "sistema",
                    f"{modo.upper()} · {con_turno}/{len(targets)} turno"
                    f" · {rea} reag")
                ultimo_latido_log = time.time()

            # 6) resumen diario de turnos al encargado de logística (~8 AM ART).
            #    Idempotente por día (nube chequea doc determinístico) → un
            #    reinicio no duplica. Si la PC bootea tarde, igual lo manda.
            if _ESCRIBIR_ESTADO:
                hoy = datetime.now().strftime("%Y-%m-%d")
                if ultimo_resumen != hoy and datetime.now().hour >= HORA_RESUMEN:
                    try:
                        if nube.enviar_resumen_diario_turnos():
                            log("LOG", "sistema",
                                "resumen diario de turnos enviado al encargado")
                    except Exception as e:
                        log("LOG", "sistema", f"error en resumen diario: {e}")
                    ultimo_resumen = hoy

            # 6.b) flush de avisos al encargado AGRUPADOS. Si hay >=1 aviso
            #      con edad >= 90s en el buffer CACHATORE_AVISOS_ENCARGADO_PENDIENTES,
            #      manda UN solo mensaje con TODOS los pendientes. Esto resuelve
            #      el spam del drop de las 10:30 (7-10 turnos seguidos = 7-10
            #      mensajes a Errazu). Si todos son recientes, espera al
            #      próximo ciclo (la ventana se cierra cuando deja de haber
            #      avisos nuevos por 90s). Idempotente ante crash: los
            #      pendientes viven en Firestore, no en memoria.
            if _ESCRIBIR_ESTADO:
                try:
                    n_flush = nube.flushear_avisos_encargado()
                    if n_flush > 0:
                        log("LOG", "sistema",
                            f"flush avisos al encargado: {n_flush} "
                            f"turno(s) agrupado(s) en 1 mensaje")
                except Exception as e:
                    log("LOG", "sistema",
                        f"error flush avisos encargado: {e}")

            time.sleep(espera)

        except KeyboardInterrupt:
            log("LOG", "sistema", "detenido (KeyboardInterrupt)")
            break
        except Exception as e:
            log("ERROR", "sistema", f"error en el ciclo: {e}; sigo")
            time.sleep(5)


if __name__ == "__main__":
    main()
