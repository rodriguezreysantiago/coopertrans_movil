"""Backfill one-time: setea EMPRESA_CUIT en cada EMPLEADOS a partir del CUIT que
ya viene embebido en el campo EMPRESA ('NOMBRE: (XX-XXXXXXXX-X)').

Lo necesita la regla de Firestore de EMPRESAS_EMPLEADORAS para dejar a cada
chofer leer SU propia empresa empleadora (Póliza ART, F.931, SCVO, libre deuda).
De ahora en más la app escribe EMPRESA_CUIT sola al crear/editar la EMPRESA;
este script es SOLO para los legajos que ya existían.

SOLO LECTURA por default; con --go escribe. Sirve cualquier Python con
firebase-admin (p. ej. el venv del cachatore). El serviceAccountKey.json se
busca en la raíz del repo automáticamente (independiente del cwd):

    # desde la RAIZ del repo (C:/coopertrans_movil), NO desde la subcarpeta cachatore
    cachatore\\venv\\Scripts\\python.exe scripts\\backfill_empresa_cuit.py        # preview
    cachatore\\venv\\Scripts\\python.exe scripts\\backfill_empresa_cuit.py --go    # aplica
"""
import os
import re
import sys

import firebase_admin
from firebase_admin import credentials, firestore

RE_CUIT = re.compile(r"(\d{2}-\d{8}-\d)")
# serviceAccountKey.json vive en la raíz del repo (scripts/..), lo ubicamos
# relativo a ESTE archivo para no depender del directorio desde donde se corra.
_SAK = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "serviceAccountKey.json")


def main():
    go = "--go" in sys.argv
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    db = firestore.client()

    a_tocar, ya_ok, sin_cuit = [], 0, 0
    for doc in db.collection("EMPLEADOS").stream():
        d = doc.to_dict() or {}
        m = RE_CUIT.search(str(d.get("EMPRESA") or ""))
        cuit = m.group(1) if m else None
        actual = d.get("EMPRESA_CUIT")
        if cuit is None:
            sin_cuit += 1
            continue
        if cuit == actual:
            ya_ok += 1
            continue
        a_tocar.append((doc.id, d.get("NOMBRE"), actual, cuit))

    for dni, nombre, actual, cuit in a_tocar:
        print(f"  {dni:>10}  {(nombre or '')[:26]:<26}  "
              f"EMPRESA_CUIT {actual!r} -> {cuit!r}")
        if go:
            db.collection("EMPLEADOS").document(dni).set(
                {"EMPRESA_CUIT": cuit}, merge=True)

    modo = "APLICADO" if go else "DRY (agrega --go para escribir)"
    print(f"\n[{modo}]  a actualizar={len(a_tocar)}  ya OK={ya_ok}  "
          f"sin CUIT en EMPRESA={sin_cuit}")


if __name__ == "__main__":
    main()
