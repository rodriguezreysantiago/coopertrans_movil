"""Foto EN VIVO del cachatore — READ-ONLY (no escribe NADA, no toca iTurnos).

Solo LEE Firestore para mostrar qué está haciendo el bot de la PC dedicada
ahora mismo: el latido, la config que setea la app, los vigilados y los turnos
publicados ("Turnos concretados"). Es lo mismo que ve la UI, en consola.

Sirve para una revisión rápida sin abrir la app ni entrar por RDP a la dedicada.
Para ver el LOOP real del bot decidiendo (login iTurnos + scan + reserva/
reagendar), correr aparte:  python vigia.py --dry --latente   (no reserva nada).

Uso:
    cachatore\\venv\\Scripts\\python.exe estado_vivo.py
    cachatore\\venv\\Scripts\\python.exe estado_vivo.py --agenda   # + huecos libres
"""
import sys
from collections import defaultdict
from datetime import datetime, timezone

import choferes  # reusa la conexión Firestore (serviceAccountKey de la raíz)
import iturnos
import nube


def _edad(ts) -> str:
    """'hace 12s' / 'hace 3 min' a partir de un Timestamp de Firestore."""
    if not ts:
        return "sin dato"
    try:
        s = int((datetime.now(timezone.utc) - ts).total_seconds())
    except Exception:
        return str(ts)
    return f"hace {s}s" if s < 120 else f"hace {s // 60} min"


def _vivo(ts) -> bool:
    try:
        return ts is not None and (datetime.now(timezone.utc) - ts).total_seconds() < 120
    except Exception:
        return False


def main():
    db = choferes._db()

    # 1) Latido del bot de la PC dedicada (CACHATORE_ESTADO/bot).
    bot = (db.collection("CACHATORE_ESTADO").document("bot").get().to_dict() or {})
    tick = bot.get("ultimo_tick_en")
    print("== LATIDO DEL BOT (PC dedicada) ==")
    print(f"   modo={bot.get('modo')}  vigilados={bot.get('total')}  "
          f"sin_turno={bot.get('pendientes')}  ultimo_tick={_edad(tick)}")
    print(f"   -> {'VIVO' if _vivo(tick) else 'NO RESPONDE (>120s) — revisar servicio'}")

    # 2) Config que setea la app (CACHATORE_CONFIG/global + objetivos activos).
    cfg = nube.leer_config_nube()
    chs = cfg.get("choferes", [])
    print(f"\n== CONFIG (la edita la app) ==  activo={cfg.get('activo')}  "
          f"poll_latente={cfg.get('poll_latente_seg')}s")

    # 3) Estado por chofer (lo que pinta la UI) + si tiene turno publicado.
    turnos = {d.id: (d.to_dict() or {})
              for d in db.collection("CACHATORE_TURNOS").stream()}
    print(f"\n== VIGILADOS ({len(chs)}) ==")
    for c in sorted(chs, key=lambda x: str(x.get("dni"))):
        dni = str(c["dni"])
        obj = (db.collection("CACHATORE_OBJETIVOS").document(dni).get().to_dict() or {})
        nombre = obj.get("nombre") or dni
        tur = turnos.get(dni, {})
        linea = (f"   {nombre} (DNI {dni})\n"
                 f"      objetivo: {c.get('fecha') or 'cualquier fecha'} · franja "
                 f"'{c['franja']}'   reagendar={'SI' if c.get('reagendar') else 'no'}\n"
                 f"      estado UI: {obj.get('estado') or '—'}"
                 f"   turno: {tur.get('cuando') or obj.get('estado_turno') or '—'}")
        print(linea)

    # 4) Turnos publicados que NO están en la lista de vigilados (colgados).
    huerfanos = [t.get("nombre") or k for k, t in turnos.items()
                 if k not in {str(c["dni"]) for c in chs}]
    if huerfanos:
        print(f"\n== TURNOS PUBLICADOS SIN VIGILAR ({len(huerfanos)}) ==")
        print("   " + ", ".join(huerfanos) + "  (se limpian al reiniciar el bot)")

    if "--agenda" in sys.argv:
        _scan_agenda(chs)


def _scan_agenda(chs):
    """Scan READ-ONLY de la agenda YPF: muestra los huecos LIBRES por fecha y
    franja. Loguea como el primer vigilado con credenciales (no reserva nada)."""
    print("\n== AGENDA YPF — HUECOS LIBRES AHORA (read-only) ==")
    datos = {x["dni"]: x for x in
             choferes.cargar_choferes(solo_dnis=[str(c["dni"]) for c in chs])}
    ch = next((datos.get(str(c["dni"])) for c in chs
               if datos.get(str(c["dni"])) and datos[str(c["dni"])].get("email")
               and datos[str(c["dni"])].get("clave")), None)
    if not ch:
        print("   (ningún vigilado tiene credenciales para usar de scanner)")
        return
    cli = iturnos.IturnosClient()
    if not cli.login(ch["email"], ch["clave"]):
        print(f"   login FALLÓ con {ch['nombre']}")
        return
    slots = iturnos.parsear_disponibilidad(cli.abrir_agenda()).get("slots", [])
    if not slots:
        print("   (sin huecos — el bot está en latente cazando cancelaciones)")
        return
    por_fecha = defaultdict(list)
    for s in slots:
        por_fecha[s["fecha"]].append(s["hora"])
    for fecha in sorted(por_fecha):
        print(f"   {fecha}: {', '.join(sorted(por_fecha[fecha]))}")


if __name__ == "__main__":
    main()
