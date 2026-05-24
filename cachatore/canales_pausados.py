"""Pausa temporal de canales — espejo Python del helper que vive en
functions/src/canales_pausados.ts y whatsapp-bot/src/canales_pausados.js.

Lee el doc META/canales_pausados con cache 5 min. Sirve para que el
cachatore (avisar_turno / enviar_resumen_diario_turnos) pregunte
"¿está pausado el canal X?" antes de encolar.

Diseño defensivo: cualquier falla de Firestore → "no hay pausa" (False).
"""
import time
from datetime import datetime, timezone

import choferes

COL_META = "META"
DOC_CANALES_PAUSADOS = "canales_pausados"
TTL_SEG = 5 * 60

_cache: dict | None = None
_cache_expira: float = 0.0


def _cargar() -> dict:
    global _cache, _cache_expira
    if _cache is not None and time.monotonic() < _cache_expira:
        return _cache
    try:
        db = choferes._db()
        snap = db.collection(COL_META).document(DOC_CANALES_PAUSADOS).get()
        _cache = snap.to_dict() or {} if snap.exists else {}
        _cache_expira = time.monotonic() + TTL_SEG
        return _cache
    except Exception:
        return _cache or {}


def esta_canal_pausado(key: str) -> bool:
    """`True` si `key` está pausado (con o sin fecha de fin, pero no
    vencida). `False` si no está en el doc, o si la fecha ya pasó.
    """
    mp = _cargar()
    raw = mp.get(key)
    if not isinstance(raw, dict):
        return False
    hasta = raw.get("hasta_iso")
    if isinstance(hasta, str) and hasta:
        try:
            # Acepta tanto ISO con Z como con offset.
            iso = hasta.replace("Z", "+00:00")
            dt_hasta = datetime.fromisoformat(iso)
            if dt_hasta.tzinfo is None:
                dt_hasta = dt_hasta.replace(tzinfo=timezone.utc)
            if datetime.now(timezone.utc) >= dt_hasta:
                return False
        except Exception:
            # Si la fecha no parsea, conservador: tratamos como pausa
            # indefinida (la app valida formato al escribir).
            pass
    return True


def invalidar_cache() -> None:
    global _cache, _cache_expira
    _cache = None
    _cache_expira = 0.0
