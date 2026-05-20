"""Datos de choferes para cachatore, tomados EN VIVO de Firestore (la base
de Coopertrans Móvil). Así no se duplica nada: si en la app se reasigna la
unidad de un chofer, cachatore lo toma solo en la próxima corrida.

Por cada chofer arma:
  - dni     = docId en EMPLEADOS
  - nombre  = EMPLEADOS/{dni}.NOMBRE
  - email   = EMPLEADOS/{dni}.MAIL          (el "usuario" de iTurnos)
  - patente = ASIGNACIONES_VEHICULO vigente (chofer_dni={dni}, hasta==null).vehiculo_id
  - clave   = de claves.json (LOCAL, gitignoreado) — la carga Santiago.

Requiere serviceAccountKey.json en la raíz del repo (un nivel arriba), el
mismo que usan los demás scripts de admin.
"""
import json
import os
import re

import firebase_admin
from firebase_admin import credentials, firestore

# FieldFilter (API nueva) evita el UserWarning del SDK por "positional
# arguments" en .where() — el mismo que usa nube.py. Si la versión del SDK
# es vieja y no lo trae, caemos al modo posicional sin romper.
try:  # pragma: no cover
    from google.cloud.firestore_v1.base_query import FieldFilter
except Exception:  # pragma: no cover
    FieldFilter = None

_DIR = os.path.dirname(os.path.abspath(__file__))
_SAK = os.path.join(_DIR, "..", "serviceAccountKey.json")
_CLAVES = os.path.join(_DIR, "claves.json")

ROL_CHOFER = "CHOFER"
COL_EMPLEADOS = "EMPLEADOS"
COL_ASIGNACIONES = "ASIGNACIONES_VEHICULO"


def _db():
    if not firebase_admin._apps:
        firebase_admin.initialize_app(credentials.Certificate(_SAK))
    return firestore.client()


def _where(ref, campo, op, valor):
    """`.where()` con FieldFilter si está disponible (sin el warning del SDK);
    cae a posicional si la versión es vieja."""
    if FieldFilter is not None:
        return ref.where(filter=FieldFilter(campo, op, valor))
    return ref.where(campo, op, valor)


def _cargar_claves() -> dict:
    """claves.json: {"_comun": "claveParaTodos", "<dni>": "claveEspecifica"}.
    Si la clave es la misma para todos, alcanza con "_comun"."""
    if not os.path.exists(_CLAVES):
        return {}
    with open(_CLAVES, encoding="utf-8") as f:
        return json.load(f)


def _patentes_vigentes(db) -> dict:
    """Mapa dni -> patente de la asignación chofer↔vehículo activa."""
    mapa = {}
    # hasta == null  => asignación vigente (igual criterio que la app).
    for d in _where(db.collection(COL_ASIGNACIONES), "hasta", "==", None).stream():
        x = d.to_dict() or {}
        dni = x.get("chofer_dni")
        if dni:
            mapa[str(dni)] = x.get("vehiculo_id")
    return mapa


# Tester por NOMBRE (mismo regex que functions/src/excluidos.ts).
_RE_TESTER = re.compile(r"\b(reviewer|tester|demo)\b", re.I)


def _patentes_tanque(db) -> set:
    """Patentes de vehículos TIPO=TANQUE (los tanques NO se usan para la
    carga de arenas YPF; mismo criterio que los EXCLUIDOS de la app)."""
    return {
        d.id.upper()
        for d in _where(db.collection("VEHICULOS"), "TIPO", "==", "TANQUE").stream()
    }


def cargar_choferes(solo_dnis=None, incluir_excluidos: bool = False) -> list:
    """Lista [{dni, nombre, email, patente, clave}] con datos vivos de la app.

    Por defecto OMITE (igual que la app): inactivos, testers (reviewer/tester/
    demo) y **choferes de tanque** (su ENGANCHE es un vehículo TIPO=TANQUE) —
    los tanques no se usan para la carga de arenas YPF.

    `solo_dnis`: filtra a esos DNIs. `incluir_excluidos`: no omite nada.
    """
    db = _db()
    claves = _cargar_claves()
    comun = claves.get("_comun")
    patente_por_dni = _patentes_vigentes(db)
    patentes_tanque = set() if incluir_excluidos else _patentes_tanque(db)

    choferes = []
    q = _where(db.collection(COL_EMPLEADOS), "ROL", "==", ROL_CHOFER)
    for doc in q.stream():
        dni = doc.id
        if solo_dnis and dni not in solo_dnis:
            continue
        e = doc.to_dict() or {}
        if not incluir_excluidos:
            if e.get("ACTIVO") is False:
                continue
            if _RE_TESTER.search(e.get("NOMBRE") or ""):
                continue
            enganche = (e.get("ENGANCHE") or "").strip().upper()
            if enganche and enganche in patentes_tanque:
                continue  # chofer de tanque → se omite
        choferes.append({
            "dni": dni,
            "nombre": e.get("NOMBRE"),
            "email": (e.get("MAIL") or "").strip().lower(),
            "patente": patente_por_dni.get(dni),
            "clave": claves.get(dni) or comun,
        })
    choferes.sort(key=lambda c: c["nombre"] or "")
    return choferes


if __name__ == "__main__":
    # Smoke test: imprime los choferes (sin mostrar la clave).
    cs = cargar_choferes()
    print(f"{len(cs)} choferes con ROL={ROL_CHOFER}:")
    sin_mail = sin_patente = sin_clave = 0
    for c in cs:
        if not c["email"]:
            sin_mail += 1
        if not c["patente"]:
            sin_patente += 1
        if not c["clave"]:
            sin_clave += 1
        print(f"  {c['dni']:>10}  {(c['nombre'] or '')[:28]:<28}  "
              f"mail={'sí' if c['email'] else 'NO':<3}  "
              f"patente={c['patente'] or '—':<8}  "
              f"clave={'sí' if c['clave'] else 'NO'}")
    print(f"\nResumen: sin mail={sin_mail}, sin patente={sin_patente}, "
          f"sin clave={sin_clave} (de {len(cs)})")
