"""Puente Firestore del cachatore: lee la config que escribe la UI de la app
y devuelve el estado en vivo. Reusa la conexión de choferes.py (mismo
serviceAccountKey).

Colecciones (ver lib/core/constants/app_constants.dart → AppCollections):
- CACHATORE_CONFIG/global      : {activo, fecha, hora_inicio, duracion_min,
                                  poll_latente_seg}  ← la app lo edita
- CACHATORE_OBJETIVOS/{dni}     : {dni, nombre, franja, reagendar, activo}
                                  ← la app lo edita; el bot le escribe encima
                                  {estado, estado_hora, estado_detalle, estado_en}
- CACHATORE_ESTADO/bot          : {modo, total, pendientes, ultimo_tick_en}
                                  ← SOLO lo escribe el bot (latido)
"""
from datetime import datetime

from firebase_admin import firestore

import choferes
import destinatarios
import canales_pausados

COL_CONFIG = "CACHATORE_CONFIG"
DOC_CONFIG = "global"
COL_OBJETIVOS = "CACHATORE_OBJETIVOS"
COL_ESTADO = "CACHATORE_ESTADO"
DOC_ESTADO = "bot"
COL_TURNOS = "CACHATORE_TURNOS"
# Pedidos one-shot del operador para verificar si un chofer (que NO está en
# CACHATORE_OBJETIVOS) ya tiene turno sacado por la web de iTurnos. La app
# escribe el doc cuando el operador tappea "Verificar" en el wizard Agregar;
# el bot lo procesa y escribe el resultado de vuelta para que la UI reaccione.
# Vida corta: tras devolver resultado el bot borra el doc cuando hayan pasado
# CHEQUEO_TTL_SEG (no más persistencia).
COL_CHEQUEOS = "CACHATORE_CHEQUEOS"

FRANJAS_VALIDAS = {"madrugada", "manana", "tarde", "noche", "cualquiera"}

# FieldFilter (API nueva) para evitar el warning de "positional arguments".
try:  # pragma: no cover
    from google.cloud.firestore_v1.base_query import FieldFilter
except Exception:  # pragma: no cover
    FieldFilter = None


def _objetivos_activos(db):
    col = db.collection(COL_OBJETIVOS)
    if FieldFilter is not None:
        return col.where(filter=FieldFilter("activo", "==", True))
    return col.where("activo", "==", True)


def leer_config_nube() -> dict:
    """Devuelve un cfg dict igual al de drop.json:
    {activo, fecha, hora_inicio, duracion_min, poll_latente_seg,
     choferes:[{dni, franja, reagendar}]}.
    Lanza excepción si Firestore no responde (el caller hace fallback)."""
    db = choferes._db()
    snap = db.collection(COL_CONFIG).document(DOC_CONFIG).get()
    cfg = (snap.to_dict() or {}) if snap.exists else {}
    objetivos = []
    for d in _objetivos_activos(db).stream():
        x = d.to_dict() or {}
        franja = (x.get("franja") or "").strip().lower()
        if franja in FRANJAS_VALIDAS:
            objetivos.append({
                "dni": str(x.get("dni") or d.id),
                "fecha": x.get("fecha"),   # 'AAAA-MM-DD' o None=cualquiera
                "franja": franja,
                "reagendar": bool(x.get("reagendar")),
                # pedido de cancelacion desde la app: el bot cancela en iTurnos
                # y saca al chofer del ciclo.
                "cancelar": bool(x.get("cancelar_pedido")),
            })
    return {
        # activo: por defecto FALSE (arranca pausado hasta que lo prendan).
        "activo": cfg.get("activo", False),
        "fecha": cfg.get("fecha"),
        # hora_inicio ya no importa (siempre latente cada ~5 s); se deja por si
        # alguien lo setea a mano y quiere la ventana agresiva.
        "hora_inicio": cfg.get("hora_inicio"),
        "duracion_min": cfg.get("duracion_min", 20),
        "poll_latente_seg": cfg.get("poll_latente_seg", 5),
        "choferes": objetivos,
    }


def escribir_estado_bot(modo: str, total: int, pendientes: int):
    """Latido del bot — la app lo usa para saber si está vivo y qué hace."""
    db = choferes._db()
    db.collection(COL_ESTADO).document(DOC_ESTADO).set({
        "modo": modo,
        "total": total,
        "pendientes": pendientes,
        "ultimo_tick_en": firestore.SERVER_TIMESTAMP,
    }, merge=True)


def escribir_estado_chofer(dni: str, estado: str, hora=None, detalle=None,
                           cuando=None):
    """Estado en vivo de un chofer (lo muestra la UI). `hora`/`detalle`/`cuando`
    solo se escriben si vienen (no piso el dato del turno con None en cada tick).
    `cuando` = texto legible del turno (ej. 'Miércoles 20 May 2026 14:00 hs.')."""
    data = {"estado": estado, "estado_en": firestore.SERVER_TIMESTAMP}
    if hora is not None:
        data["estado_hora"] = hora
    if detalle is not None:
        data["estado_detalle"] = detalle
    if cuando is not None:
        data["estado_turno"] = cuando
    db = choferes._db()
    db.collection(COL_OBJETIVOS).document(str(dni)).set(data, merge=True)


def cancelar_reagendar(dni: str):
    """Apaga el flag `reagendar` de un objetivo. Lo usa el bot cuando detecta
    que el turno YA esta en la franja/fecha pedida (no hay que moverlo mas) y
    asi la UI deja de mostrar 'buscando reagendar'."""
    db = choferes._db()
    db.collection(COL_OBJETIVOS).document(str(dni)).set(
        {"reagendar": False, "actualizado_en": firestore.SERVER_TIMESTAMP},
        merge=True,
    )


def escribir_turno(dni, nombre, cuando, hora, uuid):
    """Publica el turno REAL del chofer en CACHATORE_TURNOS (lo lee la pantalla
    'Turnos concretados'). Lo escribe el bot para CUALQUIER chofer con turno,
    lo haya sacado el bot o no."""
    db = choferes._db()
    db.collection(COL_TURNOS).document(str(dni)).set({
        "dni": str(dni),
        "nombre": nombre,
        "cuando": cuando,
        "hora": hora,
        "uuid": uuid,
        "actualizado_en": firestore.SERVER_TIMESTAMP,
    }, merge=True)


def borrar_turno(dni):
    """El chofer ya no tiene turno → sacarlo de 'Turnos concretados'."""
    db = choferes._db()
    db.collection(COL_TURNOS).document(str(dni)).delete()


def listar_dnis_turnos():
    """DNIs (doc IDs) con turno publicado en CACHATORE_TURNOS. Lo usa el bot
    para limpiar los que ya no vigila (reconciliación al arrancar)."""
    db = choferes._db()
    return [d.id for d in db.collection(COL_TURNOS).stream()]


def eliminar_objetivo(dni: str):
    """Saca al chofer de la lista de vigilados (borra CACHATORE_OBJETIVOS/{dni}).
    Lo usa el bot cuando el chofer YA USÓ su turno (ciclo completo): la lista es
    cíclica, se re-agrega a mano para el próximo turno."""
    db = choferes._db()
    db.collection(COL_OBJETIVOS).document(str(dni)).delete()


# ---- chequeos one-shot (¿el chofer ya tiene turno sacado por la web?) -----
def leer_chequeos_pendientes() -> list:
    """Devuelve los chequeos PENDIENTES (sin `resultado` aún). Cada item:
    `{dni, nombre, pedido_en}`. Si no hay, devuelve []. El bot procesa cada
    uno y llama a `escribir_resultado_chequeo` para que la UI reaccione."""
    db = choferes._db()
    pendientes = []
    for d in db.collection(COL_CHEQUEOS).stream():
        x = d.to_dict() or {}
        # Si ya tiene `resultado`, el bot ya lo procesó (la UI debería haberlo
        # borrado; si quedó huérfano, lo limpia el TTL del propio bot).
        if x.get("resultado"):
            continue
        pendientes.append({
            "dni": str(x.get("dni") or d.id),
            "nombre": x.get("nombre"),
        })
    return pendientes


def escribir_resultado_chequeo(dni: str, resultado: str, detalle: str = None):
    """Escribe el resultado del chequeo para que la UI lo lea.
    `resultado` ∈ {'con_turno', 'sin_turno', 'error'}. `detalle` opcional
    (texto del turno si hay, o motivo del error)."""
    data = {
        "resultado": resultado,
        "resuelto_en": firestore.SERVER_TIMESTAMP,
    }
    if detalle is not None:
        data["detalle"] = detalle
    db = choferes._db()
    db.collection(COL_CHEQUEOS).document(str(dni)).set(data, merge=True)


def borrar_chequeo(dni: str):
    """Limpia el doc del chequeo. Lo llama el bot tras N segundos del resuelto
    (TTL) o la UI tras mostrar el resultado al operador."""
    db = choferes._db()
    db.collection(COL_CHEQUEOS).document(str(dni)).delete()


def crear_objetivo_externo(dni: str, nombre: str, patente: str = None):
    """Da de alta al chofer en CACHATORE_OBJETIVOS marcándolo como detectado
    externamente (turno preexistente sacado por la web). `franja='cualquiera'`
    + `reagendar=False` para que el bot NO le busque nuevos turnos pero SÍ lo
    siga refrescando cada 10 min (así si lo cancelan por web, la UI se entera).
    Los botones Reagendar/Cancelar de la card de Concretados necesitan que
    exista el OBJETIVO, no solo el TURNO."""
    db = choferes._db()
    data = {
        "dni": str(dni),
        "nombre": nombre,
        "fecha": None,
        "franja": "cualquiera",
        "reagendar": False,
        "activo": True,
        "origen": "detectado_externo",
        "creado_en": firestore.SERVER_TIMESTAMP,
        "actualizado_en": firestore.SERVER_TIMESTAMP,
    }
    if patente:
        data["patente"] = patente
    db.collection(COL_OBJETIVOS).document(str(dni)).set(data, merge=True)


def listar_chequeos_resueltos_viejos(antes_de_ts) -> list:
    """DNIs de chequeos con `resultado` cuyo `resuelto_en` < antes_de_ts.
    Para que el bot los limpie (TTL) si la UI no llegó a borrarlos
    (ej. operador cerró la app sin esperar el resultado)."""
    db = choferes._db()
    viejos = []
    for d in db.collection(COL_CHEQUEOS).stream():
        x = d.to_dict() or {}
        ts = x.get("resuelto_en")
        if not x.get("resultado") or ts is None:
            continue
        try:
            if ts < antes_de_ts:
                viejos.append(d.id)
        except TypeError:
            # ts viene como DatetimeWithNanoseconds; comparar con datetime tz-aware
            continue
    return viejos


# ---- avisos por WhatsApp (vía COLA_WHATSAPP, la consume el bot) ------------
COL_COLA = "COLA_WHATSAPP"
COL_EMPLEADOS = "EMPLEADOS"
# Encargado de logística: recibe TODOS los turnos (default Errazu Esteban).
# Hoy se puede sobreescribir desde la app — pantalla "Destinatarios de
# notificación" → key `cachatoreEncargado`. Si la app no fija un override,
# usamos este DNI hardcoded como fallback.
ENCARGADO_LOGISTICA_DNI = "25022800"


def _encargado_dni() -> str:
    return destinatarios.obtener_destinatario(
        "cachatoreEncargado", ENCARGADO_LOGISTICA_DNI
    )


def _telefono_de(db, dni):
    snap = db.collection(COL_EMPLEADOS).document(str(dni)).get()
    tel = ((snap.to_dict() or {}).get("TELEFONO") or "").strip()
    return tel if tel and tel != "-" else None


def encolar_whatsapp(telefono, mensaje):
    """Encola un mensaje para que lo mande el bot (mismo formato que las CF)."""
    if not telefono:
        return
    db = choferes._db()
    db.collection(COL_COLA).add({
        "telefono": telefono,
        "mensaje": mensaje,
        "estado": "PENDIENTE",
        "encolado_en": firestore.SERVER_TIMESTAMP,
        "enviado_en": None,
        "origen": "cachatore",
    })


def avisar_turno(chofer_dni, chofer_nombre, cuando, evento):
    """Avisa por WhatsApp al chofer + al encargado de logística cuando el bot
    consigue (`evento='reservado'`), reprograma (`'reagendado'`) o CANCELA
    (`'cancelado'`) un turno.

    Al CHOFER: encola un mensaje individual inmediato (es crítico, no se
    agrupa — necesita saber al toque que tiene/cambió/perdió su turno).

    Al ENCARGADO: en lugar de encolar directo, escribe a un BUFFER
    (`CACHATORE_AVISOS_ENCARGADO_PENDIENTES`) que `flushear_avisos_encargado()`
    consume cada ciclo (~5s) con una ventana de 90s para agrupar varios
    turnos del mismo drop en UN solo mensaje. Antes el drop de las 10:30
    le metía 7-10 mensajes seguidos a Errazu (request 2026-05-28)."""
    db = choferes._db()
    cuando = cuando or "(ver en iTurnos)"
    nombre = (chofer_nombre or chofer_dni)
    primer = nombre.split()[0].title() if nombre and nombre != chofer_dni else ""
    hola = f"Hola {primer}, " if primer else "Hola, "
    if evento == "reagendado":
        msg_chofer = (f"{hola}te reprogramamos el turno de carga YPF: "
                      f"ahora es *{cuando}*.\n\n_Coopertrans Móvil_")
    elif evento == "cancelado":
        msg_chofer = (f"{hola}te avisamos que tu turno de carga YPF "
                      f"(*{cuando}*) fue CANCELADO.\n\n_Coopertrans Móvil_")
    else:
        msg_chofer = (f"{hola}te conseguimos turno de carga YPF para "
                      f"*{cuando}*.\n\n_Coopertrans Móvil_")
    encolar_whatsapp(_telefono_de(db, chofer_dni), msg_chofer)
    # M9 — pausa por canal. La pausa silencia SOLO el aviso al encargado;
    # el chofer siempre recibe el aviso de su turno (es crítico).
    if not canales_pausados.esta_canal_pausado("cachatoreEncargado"):
        _bufferear_aviso_encargado(
            db, str(chofer_dni or ""), nombre, cuando, evento or "reservado")


# ---- buffer + flush de avisos al encargado (agrupados) --------------------
COL_AVISOS_ENC = "CACHATORE_AVISOS_ENCARGADO_PENDIENTES"


def _bufferear_aviso_encargado(db, chofer_dni, chofer_nombre, cuando, evento):
    """Mete un aviso individual al buffer para que `flushear_avisos_encargado`
    lo agrupe en un solo mensaje con otros del mismo batch."""
    db.collection(COL_AVISOS_ENC).add({
        "chofer_dni": chofer_dni,
        "chofer_nombre": chofer_nombre,
        "cuando": cuando,
        "evento": evento,
        "creado_en": firestore.SERVER_TIMESTAMP,
    })


def _armar_mensaje_agrupado_encargado(items):
    """Texto del WhatsApp al encargado.
    - 1 item → formato individual (mismo que enviaba antes).
    - 2+ items → mensaje agrupado, separado por tipo de evento si hay mix.
    `items` = lista de dicts con keys: chofer_dni, chofer_nombre, cuando, evento.
    """
    n = len(items)
    if n == 1:
        it = items[0]
        ev = it["evento"]
        n_v = it["chofer_nombre"]
        dni = it["chofer_dni"]
        cuando = it["cuando"]
        if ev == "reagendado":
            return f"Turno YPF REPROGRAMADO — {n_v} (DNI {dni}): {cuando}."
        if ev == "cancelado":
            return f"Turno YPF CANCELADO — {n_v} (DNI {dni}): {cuando}."
        return f"Turno YPF — {n_v} (DNI {dni}): {cuando}."

    # 2+: agrupar por evento, mostrar contadores
    por_ev = {"reservado": [], "reagendado": [], "cancelado": []}
    for it in items:
        ev = it["evento"] if it["evento"] in por_ev else "reservado"
        por_ev[ev].append(it)

    partes = [f"*Cachatore — {n} turnos procesados*", ""]
    bloques = [
        ("Nuevos", "reservado"),
        ("Reprogramados", "reagendado"),
        ("Cancelados", "cancelado"),
    ]
    for label, ev in bloques:
        if not por_ev[ev]:
            continue
        partes.append(f"*{label} ({len(por_ev[ev])}):*")
        # Orden por nombre — más legible que por cuando (que puede ser
        # string sin formato uniforme).
        for it in sorted(por_ev[ev], key=lambda x: (x["chofer_nombre"] or "").upper()):
            partes.append(
                f"• {it['chofer_nombre']} (DNI {it['chofer_dni']}): {it['cuando']}"
            )
        partes.append("")  # línea en blanco entre bloques

    return "\n".join(partes).rstrip()


def flushear_avisos_encargado(ventana_seg=90):
    """Si hay avisos pendientes con edad >= `ventana_seg`, encola UN solo
    mensaje agrupado al encargado y borra los pendientes flusheados.

    Política:
      - Si TODOS los pendientes son recientes (<ventana_seg), no hace
        nada — espera más avisos del batch.
      - Si hay al menos UNO con edad >= ventana_seg, flushea TODOS los
        pendientes (incluso los recientes), porque ya pasó el tiempo de
        "esperar más" del batch del drop.
      - El doc en COLA_WHATSAPP queda con origen 'cachatore_agrupado'
        para distinguir de los individuales en la pantalla de cola.

    Idempotente ante crashes: los pendientes viven en Firestore, no en
    memoria. Si el cachatore muere con un buffer pendiente, al volver el
    próximo ciclo los flushea.

    Devuelve cant de avisos flusheados (0 si no hizo nada)."""
    from datetime import datetime, timezone
    db = choferes._db()
    pendientes = list(db.collection(COL_AVISOS_ENC).stream())
    if not pendientes:
        return 0

    ahora = datetime.now(timezone.utc)
    hay_estable = False
    items = []
    for d in pendientes:
        x = d.to_dict() or {}
        creado = x.get("creado_en")
        if creado is None:
            # write muy reciente, el server timestamp no se asentó aún
            continue
        try:
            edad = (ahora - creado).total_seconds()
        except TypeError:
            edad = (ahora - creado.replace(tzinfo=timezone.utc)).total_seconds()
        if edad >= ventana_seg:
            hay_estable = True
        items.append({
            "ref": d.reference,
            "chofer_dni": str(x.get("chofer_dni") or ""),
            "chofer_nombre": str(x.get("chofer_nombre") or x.get("chofer_dni") or ""),
            "cuando": str(x.get("cuando") or "(ver iTurnos)"),
            "evento": str(x.get("evento") or "reservado"),
        })

    if not hay_estable or not items:
        return 0  # todos recientes o todos sin timestamp aún → esperar

    mensaje = _armar_mensaje_agrupado_encargado(items)
    tel = _telefono_de(db, _encargado_dni())
    # Si no hay teléfono, igual borramos el buffer (no podemos mandar)
    if tel:
        db.collection(COL_COLA).add({
            "telefono": tel,
            "mensaje": mensaje,
            "estado": "PENDIENTE",
            "encolado_en": firestore.SERVER_TIMESTAMP,
            "enviado_en": None,
            "origen": "cachatore_agrupado",
        })

    batch = db.batch()
    for it in items:
        batch.delete(it["ref"])
    batch.commit()
    return len(items)


def resumen_turnos_para_encargado():
    """Texto con TODOS los turnos concretados (CACHATORE_TURNOS). None si no hay."""
    db = choferes._db()
    turnos = []
    for d in db.collection(COL_TURNOS).stream():
        x = d.to_dict() or {}
        nombre = str(x.get("nombre") or x.get("dni") or d.id)
        cuando = str(x.get("cuando") or x.get("hora") or "—")
        turnos.append((nombre, cuando))
    if not turnos:
        return None
    turnos.sort(key=lambda t: t[0].upper())
    lineas = "\n".join(f"• {n}: {c}" for n, c in turnos)
    return f"*Turnos de carga YPF* ({len(turnos)})\n{lineas}"


def enviar_resumen_diario_turnos():
    """Encola (idempotente por día) el resumen de turnos al encargado de
    logística. Devuelve True si lo encoló ahora; False si ya estaba hoy o sin tel.
    Idempotencia: doc determinístico `cachatore_resumen_<fecha>` en COLA_WHATSAPP
    (si ya existe, no re-encola aunque el bot se reinicie)."""
    # M9 — pausa por canal: el resumen diario es 100% para el encargado.
    if canales_pausados.esta_canal_pausado("cachatoreEncargado"):
        return False
    db = choferes._db()
    hoy = datetime.now().strftime("%Y-%m-%d")
    ref = db.collection(COL_COLA).document(f"cachatore_resumen_{hoy}")
    if ref.get().exists:
        return False
    tel = _telefono_de(db, _encargado_dni())
    if not tel:
        return False
    texto = resumen_turnos_para_encargado() or \
        "*Turnos de carga YPF*: hoy no hay turnos cargados."
    ref.set({
        "telefono": tel,
        "mensaje": texto,
        "estado": "PENDIENTE",
        "encolado_en": firestore.SERVER_TIMESTAMP,
        "enviado_en": None,
        "origen": "cachatore_resumen",
    })
    return True
