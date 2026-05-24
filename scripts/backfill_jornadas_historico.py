"""Backfill manual del histórico de JORNADAS reconstruidas desde
SITRACK_EVENTOS. Replica la lógica de la CF
`reconstruirJornadasDiario` para procesar N días pasados de una.

Uso (desde la raíz del repo):
    python scripts/backfill_jornadas_historico.py --dias 7

Sin --commit: dry-run (cuenta pero no escribe).
Con --commit: escribe a VOLVO_JORNADAS_HISTORICO.

Idempotente: doc id determinístico `{dni}_{YYYY-MM-DD}`, si lo corres
dos veces el mismo día sobrescribe pero NO duplica.
"""
import argparse
import datetime as dt
import os

import firebase_admin
from firebase_admin import credentials, firestore

_DIR = os.path.dirname(os.path.abspath(__file__))
_SAK = os.path.join(_DIR, "..", "serviceAccountKey.json")

# Mismos umbrales que functions/src/jornadas_v2.ts:
#   UMBRAL_MOVIMIENTO_KMH=15, PAUSA_BLOQUE_SEGUNDOS=900, DESCANSO_MIN_SEGUNDOS=28800
VEL_MOVIMIENTO = 15
PAUSA_MIN_MS = 15 * 60 * 1000
DESCANSO_MIN_MS = 8 * 3600 * 1000
MAX_PUNTOS_GRAFICO = 240


def _db():
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    return firestore.client()


def reconstruir_jornada_dia(dni, fecha, eventos):
    """eventos: lista de dicts con keys ts, speed, ignition, patente,
    driverDni, driverName, lat, lng, odometer.
    Devuelve dict de jornada o None.
    """
    if not eventos:
        return None
    eventos = sorted(eventos, key=lambda e: e["ts"])
    tramos = []
    paradas = []
    estado = "inicial"
    bdesde = bultimo = None
    bspmax = bspsum = bscount = 0
    bodom_ini = None

    def cerrar_tramo():
        nonlocal bdesde, bultimo, bspmax, bspsum, bscount, bodom_ini
        if not bdesde or not bultimo:
            return
        dur_ms = int((bultimo["ts"] - bdesde["ts"]).total_seconds() * 1000)
        if dur_ms >= 60_000:
            odo_fin = bultimo.get("odometer")
            km = (round(odo_fin - bodom_ini)
                  if odo_fin is not None and bodom_ini is not None
                  and odo_fin >= bodom_ini else 0)
            tramos.append({
                "desde": bdesde["ts"],
                "hasta": bultimo["ts"],
                "duracion_min": round(dur_ms / 60_000),
                "km_aprox": km,
                "velocidad_max": round(bspmax),
                "velocidad_prom": round(bspsum / bscount) if bscount else 0,
            })
        bdesde = bultimo = None
        bspmax = bspsum = bscount = 0
        bodom_ini = None

    def cerrar_parada():
        nonlocal bdesde, bultimo
        if not bdesde or not bultimo:
            return
        dur_ms = int((bultimo["ts"] - bdesde["ts"]).total_seconds() * 1000)
        if dur_ms >= 60_000:
            paradas.append({
                "desde": bdesde["ts"],
                "hasta": bultimo["ts"],
                "duracion_min": round(dur_ms / 60_000),
                "lat": bdesde.get("lat"),
                "lng": bdesde.get("lng"),
                "cumple_15min": dur_ms >= PAUSA_MIN_MS,
                "cumple_8h": dur_ms >= DESCANSO_MIN_MS,
            })
        bdesde = bultimo = None

    for e in eventos:
        moviendo = e["speed"] >= VEL_MOVIMIENTO
        if moviendo:
            if estado == "parado":
                cerrar_parada()
            if estado != "moviendo":
                bdesde = e
                bodom_ini = e.get("odometer")
                bspmax = e["speed"]
                bspsum = e["speed"]
                bscount = 1
                estado = "moviendo"
            else:
                bspmax = max(bspmax, e["speed"])
                bspsum += e["speed"]
                bscount += 1
            bultimo = e
        else:
            if estado == "moviendo":
                cerrar_tramo()
            if estado != "parado":
                bdesde = e
                estado = "parado"
            bultimo = e
    if estado == "moviendo":
        cerrar_tramo()
    elif estado == "parado":
        cerrar_parada()

    if not tramos:
        return None

    manejo_min = sum(t["duracion_min"] for t in tramos)
    paradas_min = sum(p["duracion_min"] for p in paradas)
    km_total = sum(t["km_aprox"] for t in tramos)
    vel_max = max(t["velocidad_max"] for t in tramos)

    step = max(1, -(-len(eventos) // MAX_PUNTOS_GRAFICO))
    serie = []
    for i in range(0, len(eventos), step):
        e = eventos[i]
        serie.append({"ts_ms": int(e["ts"].timestamp() * 1000),
                      "speed": round(e["speed"])})
    if eventos and serie and serie[-1]["ts_ms"] != int(eventos[-1]["ts"].timestamp() * 1000):
        serie.append({"ts_ms": int(eventos[-1]["ts"].timestamp() * 1000),
                      "speed": round(eventos[-1]["speed"])})

    pat_count = {}
    for e in eventos:
        pat_count[e["patente"]] = pat_count.get(e["patente"], 0) + 1
    patentes = list(pat_count.keys())
    patente_principal = max(patentes, key=lambda p: pat_count[p])
    nombre = next((e.get("driverName") for e in eventos if e.get("driverName")), None)

    return {
        "chofer_dni": dni,
        "chofer_nombre": nombre,
        "patente_principal": patente_principal,
        "patentes": patentes,
        "fecha": fecha,
        "inicio": tramos[0]["desde"],
        "fin": tramos[-1]["hasta"],
        "manejo_min": manejo_min,
        "paradas_min": paradas_min,
        "km_total": km_total,
        "velocidad_max": vel_max,
        "total_eventos": len(eventos),
        "tramos": tramos,
        "paradas": paradas,
        "serie_velocidad": serie,
    }


def procesar_dia(db, desde, hasta, fecha_label, commit=False):
    snap = (db.collection("SITRACK_EVENTOS")
            .where("report_date", ">=", desde)
            .where("report_date", "<", hasta)
            .get())

    por_dni = {}
    for d in snap:
        m = d.to_dict() or {}
        patente = (m.get("asset_id") or "").strip().upper()
        dni = (m.get("driver_dni") or "").strip()
        ts = m.get("report_date")
        if not patente or not dni or ts is None:
            continue
        speed = m.get("gps_speed") if isinstance(m.get("gps_speed"), (int, float)) else (
            m.get("speed") if isinstance(m.get("speed"), (int, float)) else 0)
        ignition = m.get("ignition") in (1, True)
        evt = {
            "ts": ts,
            "speed": speed,
            "ignition": ignition,
            "patente": patente,
            "driverDni": dni,
            "driverName": (m.get("driver_name") or "").strip() or None,
            "lat": m.get("latitude") if isinstance(m.get("latitude"), (int, float)) else None,
            "lng": m.get("longitude") if isinstance(m.get("longitude"), (int, float)) else None,
            "odometer": m.get("odometer") if isinstance(m.get("odometer"), (int, float)) else (
                m.get("gps_odometer") if isinstance(m.get("gps_odometer"), (int, float)) else None),
        }
        por_dni.setdefault(dni, []).append(evt)

    jornadas_ok = 0
    if commit:
        batch = db.batch()
        ops = 0
        for dni, eventos in por_dni.items():
            j = reconstruir_jornada_dia(dni, fecha_label, eventos)
            if not j:
                continue
            doc_id = f"{dni}_{fecha_label}"
            data = {
                "chofer_dni": j["chofer_dni"],
                "chofer_nombre": j["chofer_nombre"],
                "patente_principal": j["patente_principal"],
                "patentes": j["patentes"],
                "fecha": j["fecha"],
                "inicio": j["inicio"],
                "fin": j["fin"],
                "manejo_min": j["manejo_min"],
                "paradas_min": j["paradas_min"],
                "km_total": j["km_total"],
                "velocidad_max": j["velocidad_max"],
                "total_eventos": j["total_eventos"],
                "tramos": j["tramos"],
                "paradas": j["paradas"],
                "serie_velocidad": j["serie_velocidad"],
                "procesado_en": firestore.SERVER_TIMESTAMP,
            }
            batch.set(db.collection("VOLVO_JORNADAS_HISTORICO").document(doc_id), data)
            ops += 1
            jornadas_ok += 1
            if ops % 200 == 0:
                batch.commit()
                batch = db.batch()
        if ops % 200 != 0:
            batch.commit()
    else:
        for dni, eventos in por_dni.items():
            j = reconstruir_jornada_dia(dni, fecha_label, eventos)
            if j:
                jornadas_ok += 1

    return {"eventos": len(snap), "choferes": len(por_dni), "jornadas": jornadas_ok}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=7, help="Cuántos días pasados procesar")
    ap.add_argument("--commit", action="store_true", help="Escribe a Firestore")
    args = ap.parse_args()

    if args.dias < 1 or args.dias > 60:
        print("--dias entre 1 y 60")
        return 1

    db = _db()
    ahora_utc = dt.datetime.now(dt.timezone.utc)
    hoy_art_00 = ahora_utc.replace(hour=3, minute=0, second=0, microsecond=0)
    if ahora_utc < hoy_art_00:
        hoy_art_00 -= dt.timedelta(days=1)

    modo = "COMMIT" if args.commit else "DRY-RUN"
    print(f"=== Backfill Jornadas [{modo}] | últimos {args.dias} días ===")
    total_ev = total_cho = total_jor = 0
    for i in range(1, args.dias + 1):
        fin = hoy_art_00 - dt.timedelta(days=(i - 1))
        ini = fin - dt.timedelta(days=1)
        fecha_label = ini.strftime("%Y-%m-%d")
        print(f"  Día {i}/{args.dias} ({fecha_label} ART)…", end=" ", flush=True)
        try:
            r = procesar_dia(db, ini, fin, fecha_label, commit=args.commit)
            total_ev += r["eventos"]
            total_cho += r["choferes"]
            total_jor += r["jornadas"]
            print(f"eventos={r['eventos']:5}  choferes={r['choferes']:3}  jornadas={r['jornadas']:3}")
        except Exception as e:
            print(f"ERROR: {e}")
    print(f"--- TOTAL: eventos={total_ev:,}  choferes={total_cho}  jornadas={total_jor} ---")
    if not args.commit:
        print("(dry-run — agregá --commit para guardar)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
