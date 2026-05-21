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

COL_CONFIG = "CACHATORE_CONFIG"
DOC_CONFIG = "global"
COL_OBJETIVOS = "CACHATORE_OBJETIVOS"
COL_ESTADO = "CACHATORE_ESTADO"
DOC_ESTADO = "bot"
COL_TURNOS = "CACHATORE_TURNOS"

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
        "poll_agresivo_seg": cfg.get("poll_agresivo_seg", 1.5),
        # Boton "barrido agresivo" de la app: timestamp (UTC) hasta cuando
        # barrer rapido. La app lo setea a now+10min; el bot lo evalua cada
        # ciclo y vuelve a latente al expirar.
        "agresivo_hasta": cfg.get("agresivo_hasta"),
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


# ---- avisos por WhatsApp (vía COLA_WHATSAPP, la consume el bot) ------------
COL_COLA = "COLA_WHATSAPP"
COL_EMPLEADOS = "EMPLEADOS"
# Encargado de logística: recibe TODOS los turnos (Errazu Esteban).
ENCARGADO_LOGISTICA_DNI = "25022800"


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
    consigue (`evento='reservado'`) o reprograma (`'reagendado'`) un turno."""
    db = choferes._db()
    cuando = cuando or "(ver en iTurnos)"
    nombre = (chofer_nombre or chofer_dni)
    primer = nombre.split()[0].title() if nombre and nombre != chofer_dni else ""
    hola = f"Hola {primer}, " if primer else "Hola, "
    if evento == "reagendado":
        msg_chofer = (f"{hola}te reprogramamos el turno de carga YPF: "
                      f"ahora es *{cuando}*.\n\n_Coopertrans Móvil_")
        msg_enc = (f"Turno YPF REPROGRAMADO — {nombre} (DNI {chofer_dni}): "
                   f"{cuando}.")
    else:
        msg_chofer = (f"{hola}te conseguimos turno de carga YPF para "
                      f"*{cuando}*.\n\n_Coopertrans Móvil_")
        msg_enc = (f"Turno YPF — {nombre} (DNI {chofer_dni}): {cuando}.")
    encolar_whatsapp(_telefono_de(db, chofer_dni), msg_chofer)
    encolar_whatsapp(_telefono_de(db, ENCARGADO_LOGISTICA_DNI), msg_enc)


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
    db = choferes._db()
    hoy = datetime.now().strftime("%Y-%m-%d")
    ref = db.collection(COL_COLA).document(f"cachatore_resumen_{hoy}")
    if ref.get().exists:
        return False
    tel = _telefono_de(db, ENCARGADO_LOGISTICA_DNI)
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
