"""Override de destinatarios de notificación — espejo Python del helper que
vive en functions/src/comun.ts y whatsapp-bot/src/destinatarios.js.

Lee el doc `META/destinatarios_notificacion` con cache 5 min y devuelve el
DNI override para una key dada, o el `fallback` (típicamente la constante
hardcoded del módulo) si no hay override válido.

El doc lo edita el admin desde la pantalla "Destinatarios de notificación"
en la app. Cambiar el destinatario NO requiere reiniciar el servicio
cachatore: el cache TTL 5 min hace que la próxima ronda tome el valor
nuevo sin downtime.

Si Firestore falla / el doc no existe / la key no tiene override, devuelve
el fallback. Un Firestore caído no rompe el bot — seguimos usando los
valores históricos hardcoded.
"""
import time

import choferes

COL_META = "META"
DOC_DESTINATARIOS = "destinatarios_notificacion"
TTL_SEG = 5 * 60

_cache: dict | None = None
_cache_expira: float = 0.0


def _cargar() -> dict:
    """Lee el doc con cache 5 min. Si falla, devuelve el cache viejo (aun
    vencido) o un dict vacío — los callers ya tienen fallback hardcoded.
    """
    global _cache, _cache_expira
    if _cache is not None and time.monotonic() < _cache_expira:
        return _cache
    try:
        db = choferes._db()
        snap = db.collection(COL_META).document(DOC_DESTINATARIOS).get()
        if snap.exists:
            _cache = snap.to_dict() or {}
        else:
            _cache = {}
        _cache_expira = time.monotonic() + TTL_SEG
        return _cache
    except Exception:
        return _cache or {}


def obtener_destinatario(key: str, fallback: str) -> str:
    """Devuelve el DNI para `key` desde Firestore, o `fallback` si no hay
    override válido."""
    mp = _cargar()
    v = mp.get(key)
    if isinstance(v, str) and v.strip():
        return v.strip()
    return fallback


def invalidar_cache() -> None:
    """Útil para tests."""
    global _cache, _cache_expira
    _cache = None
    _cache_expira = 0.0
