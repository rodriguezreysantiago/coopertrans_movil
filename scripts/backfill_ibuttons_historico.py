"""Backfill manual del histórico de iButtons reconstruido desde
SITRACK_EVENTOS. Replica la lógica de la CF `reconstruirHistoricoIButtonsDiario`
para procesar N días pasados de una.

Uso (desde la raíz del repo):
    python scripts/backfill_ibuttons_historico.py --dias 7

Sin --commit: dry-run (cuenta pero no escribe).
Con --commit: escribe a SITRACK_IBUTTONS_HISTORICO.

Idempotente: doc id determinístico `{patente}_{dni}_{desde_ms}`, si lo
corres dos veces el mismo día sobrescribe pero NO duplica.
"""
import argparse
import datetime as dt
import os
import sys

import firebase_admin
from firebase_admin import credentials, firestore

_DIR = os.path.dirname(os.path.abspath(__file__))
_SAK = os.path.join(_DIR, "..", "serviceAccountKey.json")

# Mismas constantes que la CF
GAP_TRAMO_MS = 30 * 60 * 1000
MIN_EVENTOS_TRAMO = 2


def _db():
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    return firestore.client()


def reconstruir_tramos(eventos):
    """Eventos = lista de dicts con keys: patente, driver_dni, driver_name, ts (datetime).
    Devuelve lista de tramos."""
    por_patente = {}
    for e in eventos:
        if not e["patente"] or not e["driver_dni"]:
            continue
        por_patente.setdefault(e["patente"], []).append(e)

    tramos = []
    for patente, evts in por_patente.items():
        evts.sort(key=lambda x: x["ts"])
        actual = None
        for e in evts:
            ts_ms = int(e["ts"].timestamp() * 1000)
            nuevo = (
                actual is None
                or actual["driver_dni"] != e["driver_dni"]
                or ts_ms - int(actual["hasta"].timestamp() * 1000) > GAP_TRAMO_MS
            )
            if nuevo:
                if actual and actual["eventos_count"] >= MIN_EVENTOS_TRAMO:
                    tramos.append(actual)
                actual = {
                    "patente": patente,
                    "driver_dni": e["driver_dni"],
                    "driver_name": e["driver_name"],
                    "desde": e["ts"],
                    "hasta": e["ts"],
                    "eventos_count": 1,
                }
            else:
                actual["hasta"] = e["ts"]
                actual["eventos_count"] += 1
                if not actual["driver_name"] and e["driver_name"]:
                    actual["driver_name"] = e["driver_name"]
        if actual and actual["eventos_count"] >= MIN_EVENTOS_TRAMO:
            tramos.append(actual)
    return tramos


def procesar_dia(db, desde, hasta, commit=False):
    """Procesa eventos en [desde, hasta) y persiste tramos. Devuelve stats."""
    desde_ts = firestore.firestore.SERVER_TIMESTAMP if False else None
    snap = (
        db.collection("SITRACK_EVENTOS")
        .where("report_date", ">=", desde)
        .where("report_date", "<", hasta)
        .get()
    )
    eventos = []
    for d in snap:
        m = d.to_dict() or {}
        # OJO: en la cuenta ws41629VecchiSRL Sitrack manda la PATENTE en
        # `asset_id` (ej. "AF472BG"); `asset_name` viene vacío.
        patente = (m.get("asset_id") or "").strip().upper()
        dni = (m.get("driver_dni") or "").strip()
        ts = m.get("report_date")
        if not patente or not dni or ts is None:
            continue
        eventos.append({
            "patente": patente,
            "driver_dni": dni,
            "driver_name": (m.get("driver_name") or "").strip() or None,
            "ts": ts,
        })

    tramos = reconstruir_tramos(eventos)

    if commit and tramos:
        batch = db.batch()
        ops = 0
        for t in tramos:
            desde_ms = int(t["desde"].timestamp() * 1000)
            doc_id = f"{t['patente']}_{t['driver_dni']}_{desde_ms}"
            duracion_min = round(
                (t["hasta"].timestamp() - t["desde"].timestamp()) / 60
            )
            batch.set(db.collection("SITRACK_IBUTTONS_HISTORICO").document(doc_id), {
                "patente": t["patente"],
                "chofer_dni": t["driver_dni"],
                "chofer_nombre": t["driver_name"],
                "desde": t["desde"],
                "hasta": t["hasta"],
                "duracion_min": duracion_min,
                "eventos_count": t["eventos_count"],
                "procesado_en": firestore.SERVER_TIMESTAMP,
            })
            ops += 1
            if ops % 400 == 0:
                batch.commit()
                batch = db.batch()
        if ops % 400 != 0:
            batch.commit()

    return {"eventos": len(eventos), "tramos": len(tramos)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dias", type=int, default=7,
                    help="Cuántos días pasados procesar (default 7)")
    ap.add_argument("--commit", action="store_true",
                    help="Escribe a Firestore (sin esto = dry-run)")
    args = ap.parse_args()

    if args.dias < 1 or args.dias > 60:
        print("--dias entre 1 y 60"); return 1

    db = _db()
    # 00:00 ART hoy = 03:00 UTC hoy
    ahora_utc = dt.datetime.now(dt.timezone.utc)
    hoy_art_00 = ahora_utc.replace(hour=3, minute=0, second=0, microsecond=0)
    if ahora_utc < hoy_art_00:
        hoy_art_00 -= dt.timedelta(days=1)

    modo = "COMMIT" if args.commit else "DRY-RUN"
    print(f"=== Backfill iButtons [{modo}] | últimos {args.dias} días ===")
    total_evt = 0
    total_tr = 0
    for i in range(1, args.dias + 1):
        fin = hoy_art_00 - dt.timedelta(days=(i - 1))
        ini = fin - dt.timedelta(days=1)
        print(f"  Día {i}/{args.dias} ({ini.strftime('%Y-%m-%d')} ART)…", end=" ", flush=True)
        try:
            r = procesar_dia(db, ini, fin, commit=args.commit)
            total_evt += r["eventos"]
            total_tr += r["tramos"]
            print(f"eventos={r['eventos']:5}  tramos={r['tramos']:4}")
        except Exception as e:
            print(f"ERROR: {e}")
    print(f"--- TOTAL: eventos={total_evt:,}  tramos={total_tr:,} ---")
    if not args.commit:
        print("(dry-run — agregá --commit para guardar)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
