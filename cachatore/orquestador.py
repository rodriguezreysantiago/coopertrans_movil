"""Orquestador del sniper de turnos YPF.

A la hora del drop, para CADA chofer seleccionado (en paralelo, un hilo c/u)
loguea a iTurnos y caza un turno dentro de su franja; cuando lo encuentra lo
reserva con los datos del chofer (patente/DNI/empresa). Reintenta ante blips.

- Selección del drop: `drop.json` (fecha opcional, hora_inicio, choferes+franja).
- Datos de cada chofer (email/patente): de Firestore vía choferes.py.
- Claves: claves.json (vía choferes.py).

Uso:
    python orquestador.py            # espera hasta hora_inicio y arranca
    python orquestador.py --ya       # arranca YA (ignora hora_inicio) — testeo
    python orquestador.py --dry      # detecta y loguea pero NO reserva — testeo

Logs con prefijo LOG:/EXITO:/ERROR: para que la UI los parsee y colore.
"""
import json
import os
import sys
import threading
import time
from datetime import datetime

import iturnos
import choferes

_DIR = os.path.dirname(os.path.abspath(__file__))
DROP_CONFIG = os.path.join(_DIR, "drop.json")

POLL_SEG = 2.0            # cada cuánto re-escanea la agenda
LOGIN_REINTENTOS = 3
DURACION_MIN_DEFAULT = 15  # minutos máx. de caza tras el drop

_log_lock = threading.Lock()


def log(tag: str, quien: str, msg: str):
    with _log_lock:
        print(f"{tag}:[{datetime.now():%H:%M:%S}] [{quien}] {msg}", flush=True)


def _esperar_hasta(hhmm: str):
    """Duerme hasta hh:mm de HOY (hora local = ART en el equipo)."""
    ahora = datetime.now()
    h, m = map(int, hhmm.split(":"))
    objetivo = ahora.replace(hour=h, minute=m, second=0, microsecond=0)
    seg = (objetivo - ahora).total_seconds()
    if seg > 0:
        log("LOG", "sistema", f"esperando {seg:.0f}s hasta el drop ({hhmm})")
        time.sleep(seg)


def _worker(ch: dict, franja: str, fecha: str | None, dry: bool,
            deadline: float, resultados: dict):
    nombre = ch.get("nombre") or ch["dni"]
    if not ch.get("email") or not ch.get("clave"):
        log("ERROR", nombre, "sin email/clave (revisar en la app)")
        resultados[ch["dni"]] = "sin_credenciales"
        return
    if not ch.get("patente"):
        log("ERROR", nombre, "sin patente/unidad asignada en la app")
        resultados[ch["dni"]] = "sin_patente"
        return

    cli = iturnos.IturnosClient()
    # --- login con reintento (los blips de Cloudflare son transitorios) ---
    logueado = False
    for _ in range(LOGIN_REINTENTOS):
        try:
            if cli.login(ch["email"], ch["clave"]):
                logueado = True
                break
        except Exception as e:
            log("LOG", nombre, f"login error transitorio: {e}")
        time.sleep(1.5)
    if not logueado:
        log("ERROR", nombre, "no pudo loguear tras reintentos")
        resultados[ch["dni"]] = "login_fallo"
        return
    log("LOG", nombre, f"logueado — cazando franja '{franja}'"
        + (f" del {fecha}" if fecha else ""))

    # --- caza + reserva ---
    while time.time() < deadline:
        try:
            disp = iturnos.parsear_disponibilidad(cli.abrir_agenda())
        except Exception as e:
            log("LOG", nombre, f"error leyendo agenda: {e}")
            time.sleep(POLL_SEG)
            continue
        slots = iturnos.slots_en_franja(disp["slots"], franja)
        if fecha:
            slots = [s for s in slots if s["fecha"] == fecha]
        if not slots:
            time.sleep(POLL_SEG)
            continue

        slot = slots[0]
        log("LOG", nombre, f"slot LIBRE {slot['fecha']} {slot['hora']} → reservando")
        if dry:
            log("EXITO", nombre, f"[DRY] habría reservado {slot['fecha']} {slot['hora']}")
            resultados[ch["dni"]] = "dry_ok"
            return
        try:
            r = cli.reservar(slot, patente=ch["patente"], dni=ch["dni"])
        except Exception as e:
            log("LOG", nombre, f"error en reserva: {e}")
            time.sleep(POLL_SEG)
            continue
        if r.get("ok"):
            log("EXITO", nombre,
                f"RESERVADO {slot['fecha']} {slot['hora']} — unidad {ch['patente']}")
            resultados[ch["dni"]] = "reservado"
            return
        if r.get("motivo") == "tomado":
            log("LOG", nombre, f"{slot['hora']} lo tomaron, sigo buscando")
            continue  # otro slot en el próximo escaneo
        log("LOG", nombre, f"reserva sin confirmar ({r.get('motivo')}); reintento")
        time.sleep(POLL_SEG)

    log("ERROR", nombre, "se agotó el tiempo sin conseguir turno")
    resultados[ch["dni"]] = "sin_turno"


def main():
    dry = "--dry" in sys.argv
    ya = "--ya" in sys.argv

    if not os.path.exists(DROP_CONFIG):
        log("ERROR", "sistema", f"falta {DROP_CONFIG} (ver drop.ejemplo.json)")
        sys.exit(1)
    with open(DROP_CONFIG, encoding="utf-8") as f:
        cfg = json.load(f)

    seleccion = cfg.get("choferes", [])
    if not seleccion:
        log("ERROR", "sistema", "drop.json no tiene choferes")
        sys.exit(1)
    dnis = [c["dni"] for c in seleccion]
    franja_por_dni = {c["dni"]: c["franja"] for c in seleccion}
    fecha = cfg.get("fecha")  # opcional

    # Datos vivos de Firestore (omite tanques/testers/inactivos).
    datos = {c["dni"]: c for c in choferes.cargar_choferes(solo_dnis=dnis)}

    if not ya:
        _esperar_hasta(cfg.get("hora_inicio", "10:29"))
    deadline = time.time() + cfg.get("duracion_min", DURACION_MIN_DEFAULT) * 60

    log("LOG", "sistema",
        f"arranca {'[DRY] ' if dry else ''}para {len(dnis)} chofer(es)")
    resultados: dict = {}
    hilos = []
    for dni in dnis:
        ch = datos.get(dni)
        if not ch:
            log("ERROR", dni, "no está en la base (¿tanque/excluido/inactivo?)")
            resultados[dni] = "no_encontrado"
            continue
        t = threading.Thread(
            target=_worker,
            args=(ch, franja_por_dni[dni], fecha, dry, deadline, resultados),
            daemon=True,
        )
        t.start()
        hilos.append(t)
    for t in hilos:
        t.join()

    ganados = [d for d, v in resultados.items() if v in ("reservado", "dry_ok")]
    log("LOG", "sistema", f"=== FIN: {len(ganados)}/{len(dnis)} con turno ===")
    for dni in dnis:
        nom = (datos.get(dni) or {}).get("nombre", dni)
        log("LOG", "sistema", f"  {nom}: {resultados.get(dni, '?')}")


if __name__ == "__main__":
    main()
