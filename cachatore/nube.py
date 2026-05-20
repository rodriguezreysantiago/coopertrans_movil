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
from firebase_admin import firestore

import choferes

COL_CONFIG = "CACHATORE_CONFIG"
DOC_CONFIG = "global"
COL_OBJETIVOS = "CACHATORE_OBJETIVOS"
COL_ESTADO = "CACHATORE_ESTADO"
DOC_ESTADO = "bot"
COL_TURNOS = "CACHATORE_TURNOS"

FRANJAS_VALIDAS = {"madrugada", "manana", "tarde", "noche"}

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
