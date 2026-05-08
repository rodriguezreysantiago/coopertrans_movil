# Importador masivo de UBICACIONES_LOGISTICA desde un CSV.
#
# Caso de uso: Vecchi tiene 50+ silos / plantas / acopios que cargar.
# A mano por la app es tedioso. Este script lee un CSV y crea los
# documentos en Firestore en una pasada.
#
# Idempotente: si ya existe una ubicación con el mismo nombre
# (case-insensitive), se skipea — no duplica. Útil para re-correr el
# script si agregás filas nuevas al CSV.
#
# Uso (desde la raíz del repo):
#   python scripts/importar_ubicaciones_logistica.py --dry-run    # solo lista
#   python scripts/importar_ubicaciones_logistica.py --apply      # crea
#   python scripts/importar_ubicaciones_logistica.py --csv x.csv  # CSV custom
#
# Default CSV: scripts/ubicaciones_logistica.csv
#
# Formato CSV (con header):
#   nombre,localidad,provincia,direccion,lat,lng,empresa_nombre
#   PLANTA PROFERTIL,Bahía Blanca,Buenos Aires,Puerto Ing. White,-38.78,-62.27,PROFERTIL
#   PUERTO QUEQUÉN,Quequén,Buenos Aires,,-38.5694,-58.7019,
#
# Campos:
#   - nombre*:        obligatorio, se normaliza a UPPER al guardar
#   - localidad*:     obligatorio
#   - provincia*:     obligatorio
#   - direccion:      opcional, vacío → no se setea el campo
#   - lat:            opcional, debe estar entre -90 y 90
#   - lng:            opcional, debe estar entre -180 y 180
#   - empresa_nombre: opcional, busca la empresa por nombre (case-
#                     insensitive) en EMPRESAS_LOGISTICA. Si no la
#                     encuentra, error (no se carga la fila — primero
#                     cargá la empresa). Si está vacío, ubicación queda
#                     "huérfana" sin empresa asociada.
#
# Si lat o lng está pero no el otro, error (no se carga la fila).

import argparse
import sys
from pathlib import Path

import pandas as pd
import firebase_admin
from firebase_admin import credentials, firestore


def conectar():
    repo_root = Path(__file__).resolve().parent.parent
    sa_path = repo_root / "serviceAccountKey.json"
    if not sa_path.exists():
        print(f"❌ No encuentro {sa_path}")
        print("   Bajá el service account de Firebase Console → Settings → Service accounts.")
        sys.exit(1)
    cred = credentials.Certificate(str(sa_path))
    firebase_admin.initialize_app(cred)
    return firestore.client()


def cargar_existentes(db):
    """Devuelve un set con los nombres normalizados (UPPER) ya
    presentes en UBICACIONES_LOGISTICA. Para chequeo de duplicados."""
    snap = db.collection("UBICACIONES_LOGISTICA").stream()
    nombres = set()
    for doc in snap:
        nombre = (doc.to_dict().get("nombre") or "").strip().upper()
        if nombre:
            nombres.add(nombre)
    return nombres


def cargar_empresas(db):
    """Devuelve un dict {nombre_upper: (id, nombre_original)} con todas
    las empresas activas. Usado para resolver `empresa_nombre` del CSV
    contra el catálogo y guardar empresa_id + snapshot del nombre."""
    snap = db.collection("EMPRESAS_LOGISTICA").stream()
    empresas = {}
    for doc in snap:
        data = doc.to_dict()
        if data.get("activa") is False:
            continue
        nombre = (data.get("nombre") or "").strip()
        if nombre:
            empresas[nombre.upper()] = (doc.id, nombre)
    return empresas


def parsear_lat_lng(valor, etiqueta, contexto):
    """Devuelve float o None. Lanza ValueError si está fuera de
    rango o no es parseable. Strings vacíos / NaN devuelven None."""
    if valor is None or (isinstance(valor, float) and pd.isna(valor)):
        return None
    s = str(valor).strip()
    if s == "" or s.lower() == "nan":
        return None
    try:
        v = float(s)
    except ValueError:
        raise ValueError(f"[{contexto}] '{etiqueta}' = {valor!r} no es número")
    if etiqueta == "lat" and not -90 <= v <= 90:
        raise ValueError(f"[{contexto}] lat fuera de rango: {v}")
    if etiqueta == "lng" and not -180 <= v <= 180:
        raise ValueError(f"[{contexto}] lng fuera de rango: {v}")
    return v


def main():
    parser = argparse.ArgumentParser(description="Importador de UBICACIONES_LOGISTICA")
    parser.add_argument("--csv", default="scripts/ubicaciones_logistica.csv",
                        help="Path al CSV (default: scripts/ubicaciones_logistica.csv)")
    parser.add_argument("--dry-run", action="store_true",
                        help="Solo lista qué se haría, no escribe en Firestore")
    parser.add_argument("--apply", action="store_true",
                        help="Crea los documentos en Firestore")
    args = parser.parse_args()

    if not args.dry_run and not args.apply:
        print("❌ Tenés que pasar --dry-run o --apply.")
        sys.exit(1)

    csv_path = Path(args.csv)
    if not csv_path.exists():
        print(f"❌ No existe el CSV: {csv_path}")
        sys.exit(1)

    df = pd.read_csv(csv_path, dtype=str, keep_default_na=False)
    columnas_esperadas = {"nombre", "localidad", "provincia"}
    faltantes = columnas_esperadas - set(df.columns)
    if faltantes:
        print(f"❌ Faltan columnas en el CSV: {faltantes}")
        print(f"   Columnas presentes: {list(df.columns)}")
        sys.exit(1)

    db = conectar()
    print(f"✅ Conexión a Firebase OK.")
    print(f"📂 CSV: {csv_path} ({len(df)} filas)")

    print("📡 Leyendo ubicaciones existentes...")
    existentes = cargar_existentes(db)
    print(f"   {len(existentes)} ubicación(es) ya en Firestore.")

    print("📡 Leyendo empresas (para asociar por nombre)...")
    empresas = cargar_empresas(db)
    print(f"   {len(empresas)} empresa(s) activas.")
    print("")

    a_crear = []
    saltadas = 0
    errores = 0

    for idx, row in df.iterrows():
        nro_fila = idx + 2  # +2 porque idx es 0-based y header cuenta 1
        nombre = (row.get("nombre") or "").strip()
        if not nombre:
            print(f"⚠️ Fila {nro_fila}: sin nombre, skip.")
            saltadas += 1
            continue
        nombre_norm = nombre.upper()
        if nombre_norm in existentes:
            print(f"⏭️ Fila {nro_fila}: '{nombre_norm}' ya existe, skip.")
            saltadas += 1
            continue

        localidad = (row.get("localidad") or "").strip()
        provincia = (row.get("provincia") or "").strip()
        if not localidad or not provincia:
            print(f"❌ Fila {nro_fila}: localidad y provincia obligatorias.")
            errores += 1
            continue

        try:
            lat = parsear_lat_lng(row.get("lat"), "lat", f"fila {nro_fila}")
            lng = parsear_lat_lng(row.get("lng"), "lng", f"fila {nro_fila}")
        except ValueError as e:
            print(f"❌ {e}")
            errores += 1
            continue

        if (lat is None) != (lng is None):
            print(f"❌ Fila {nro_fila}: si tenés lat tenés que tener lng (o viceversa).")
            errores += 1
            continue

        direccion = (row.get("direccion") or "").strip() or None

        # Lookup empresa opcional. Si vino nombre_empresa pero no
        # matchea ninguna en el catálogo, error (mejor abortar la
        # fila que perder la asociación).
        empresa_nombre_csv = (row.get("empresa_nombre") or "").strip()
        empresa_id = None
        empresa_nombre_snapshot = None
        if empresa_nombre_csv:
            match = empresas.get(empresa_nombre_csv.upper())
            if match is None:
                print(f"❌ Fila {nro_fila}: empresa "
                      f"'{empresa_nombre_csv}' no existe en EMPRESAS_LOGISTICA. "
                      f"Cargala primero o dejá el campo vacío.")
                errores += 1
                continue
            empresa_id, empresa_nombre_snapshot = match

        doc = {
            "nombre": nombre_norm,
            "localidad": localidad,
            "provincia": provincia,
            "activa": True,
            "creado_en": firestore.SERVER_TIMESTAMP,
            "creado_por": "BULK_IMPORT",
        }
        if direccion:
            doc["direccion"] = direccion
        if lat is not None:
            doc["lat"] = lat
        if lng is not None:
            doc["lng"] = lng
        if empresa_id:
            doc["empresa_id"] = empresa_id
            doc["empresa_nombre"] = empresa_nombre_snapshot

        a_crear.append((nombre_norm, doc))
        # Sumamos al set para que duplicados dentro del mismo CSV
        # también se detecten.
        existentes.add(nombre_norm)

    print("")
    print("📊 RESUMEN:")
    print(f"   A crear:  {len(a_crear)}")
    print(f"   Skip:     {saltadas} (vacíos o ya existen)")
    print(f"   Errores:  {errores}")
    print("")

    if errores > 0:
        print("⚠️ Hay errores. Resolvelos primero antes de --apply.")
        sys.exit(1)

    if args.dry_run:
        print("🧪 DRY-RUN: no se escribió nada. Los a crear son:")
        for nombre, doc in a_crear[:20]:
            coords = f"({doc.get('lat')},{doc.get('lng')})" if "lat" in doc else "(sin coords)"
            empresa = f" → {doc['empresa_nombre']}" if "empresa_nombre" in doc else ""
            print(f"   - {nombre} | {doc['localidad']}, {doc['provincia']} {coords}{empresa}")
        if len(a_crear) > 20:
            print(f"   ... y {len(a_crear) - 20} más")
        print("")
        print("Para crear de verdad: corré con --apply")
        return

    # --apply: crear en batches de 500 (límite de Firestore batch).
    print("🚀 Creando documentos...")
    creados = 0
    for i in range(0, len(a_crear), 500):
        batch = db.batch()
        for nombre, doc in a_crear[i:i + 500]:
            ref = db.collection("UBICACIONES_LOGISTICA").document()
            batch.set(ref, doc)
        batch.commit()
        creados += min(500, len(a_crear) - i)
        print(f"   Creadas {creados}/{len(a_crear)}...")

    print("")
    print(f"✅ Listo. {creados} ubicaciones creadas en UBICACIONES_LOGISTICA.")


if __name__ == "__main__":
    main()
