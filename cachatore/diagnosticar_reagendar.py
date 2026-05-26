"""diagnosticar_reagendar.py — diagnóstico READ-ONLY del calendario de reagendar.

Loguea como un chofer dado, lee su turno actual, abre la página
/reagendar/calendario/{uuid} (con y sin ?d=fecha) y muestra qué slots ofrece
iTurnos. NO mueve ni cancela ningún turno.

Sirve para distinguir:
  (a) iTurnos no le ofrece nada a ESE chofer para reagendar (restricción del
      sitio) — el HTML llega sin <a class="btn-outline-success">.
  (b) Bug de parseo / filtros nuestros — el HTML SÍ tiene slots libres pero
      parsear_slots_reagendar() o los filtros posteriores los descartan.

Uso (modo Firestore, igual que el bot — necesita serviceAccountKey.json y
claves.json, lo normal en la PC dedicada):
    python diagnosticar_reagendar.py --dni 12345678 --franja tarde --fecha 2026-05-26

Uso (modo standalone, sin Firestore — para correr suelto en cualquier PC con
curl_cffi + bs4):
    python diagnosticar_reagendar.py --email chofer@x.com --clave Cooper2022 \\
        --franja tarde --fecha 2026-05-26

Opciones:
    --franja  tarde|manana|madrugada|noche|cualquiera (default: tarde)
    --fecha   AAAA-MM-DD (default: hoy en ART)
    --guardar-html  Vuelca el HTML del calendario a un archivo (para inspección).
"""
import argparse
import re
import sys
from datetime import datetime

import iturnos

# stdout en UTF-8 (evita UnicodeEncodeError en PowerShell con cp1252).
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def _resolver_chofer_firestore(dni: str):
    """Trae email + clave del chofer de Firestore + claves.json (igual que el bot)."""
    import choferes
    cs = choferes.cargar_choferes(solo_dnis=[dni], incluir_excluidos=True)
    if not cs:
        return None
    return cs[0]


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dni", help="DNI del chofer (modo Firestore)")
    p.add_argument("--email", help="Email del chofer en iTurnos (modo standalone)")
    p.add_argument("--clave", help="Clave del chofer en iTurnos (modo standalone)")
    p.add_argument("--franja", default="tarde",
                   choices=list(iturnos.FRANJAS.keys()) + [iturnos.CUALQUIERA],
                   help="Franja objetivo del reagendar (default: tarde)")
    p.add_argument("--fecha", default=None,
                   help="Fecha objetivo AAAA-MM-DD (default: hoy)")
    p.add_argument("--guardar-html", action="store_true",
                   help="Vuelca el HTML del calendario a un archivo")
    args = p.parse_args()

    if args.dni:
        ch = _resolver_chofer_firestore(args.dni)
        if not ch:
            print(f"ERROR: no encontré el chofer DNI={args.dni} en Firestore")
            sys.exit(1)
        email = ch["email"]
        clave = ch["clave"]
        nombre = ch.get("nombre") or args.dni
        if not email or not clave:
            print(f"ERROR: chofer {nombre} sin email/clave (email={email!r}, "
                  f"clave_set={'sí' if clave else 'NO'})")
            sys.exit(1)
    elif args.email and args.clave:
        email = args.email
        clave = args.clave
        nombre = email
    else:
        print("ERROR: pasá --dni  o  --email + --clave")
        sys.exit(2)

    fecha = args.fecha or datetime.now().strftime("%Y-%m-%d")

    print(f"\n=== diagnóstico cachatore reagendar ===")
    print(f"chofer:  {nombre}")
    print(f"email:   {email}")
    print(f"franja:  {args.franja}")
    print(f"fecha:   {fecha}")
    print(f"ahora:   {datetime.now():%Y-%m-%d %H:%M:%S}  (hora local = ART)")
    print()

    cli = iturnos.IturnosClient()

    print("[1/5] login...")
    if not cli.login(email, clave):
        print("ERROR: login falló")
        sys.exit(1)
    print("  OK")

    print("\n[2/5] mis_turnos...")
    try:
        turnos = cli.mis_turnos()
    except Exception as e:
        print(f"ERROR: {e}")
        sys.exit(1)
    if not turnos:
        print("ERROR: el chofer NO tiene turnos. No hay UUID para reagendar.")
        sys.exit(1)
    t = turnos[0]
    print(f"  turno actual: {t.get('cuando')}")
    print(f"  uuid: {t['uuid']}")
    print(f"  hora: {t.get('hora')}")
    fa = iturnos.franja_de_hora(t.get("hora"))
    print(f"  franja del turno actual: {fa}")

    uuid = t["uuid"]

    # --- A) GET con ?d=fecha (lo que hace el bot) ---
    url_a = f"{iturnos.BASE}/reagendar/calendario/{uuid}?d={fecha}"
    print(f"\n[3/5] GET con ?d={fecha} (lo que hace el bot)")
    print(f"  url: {url_a}")
    resp_a = cli.s.get(url_a)
    html_a = resp_a.text
    print(f"  status: {resp_a.status_code}  len(html): {len(html_a)} bytes")
    _diagnosticar_html(html_a, args.franja, fecha, fa, args.guardar_html,
                       sufijo=f"con_d_{fecha}")

    # --- B) GET sin ?d ---
    url_b = f"{iturnos.BASE}/reagendar/calendario/{uuid}"
    print(f"\n[4/5] GET sin ?d (calendario default)")
    print(f"  url: {url_b}")
    resp_b = cli.s.get(url_b)
    html_b = resp_b.text
    print(f"  status: {resp_b.status_code}  len(html): {len(html_b)} bytes")
    _diagnosticar_html(html_b, args.franja, fecha, fa, args.guardar_html,
                       sufijo="sin_d")

    # --- C) abrir_agenda — qué ve el scanner ---
    print(f"\n[5/5] abrir_agenda (lo que ve el scanner en la página de tomar turno)")
    html_c = cli.abrir_agenda()
    print(f"  len(html): {len(html_c)} bytes")
    libres = iturnos.parsear_disponibilidad(html_c).get("slots", [])
    print(f"  slots libres en agenda: {len(libres)}")
    if libres:
        en_franja = [s for s in libres
                     if iturnos.hora_en_franja(s["hora"], args.franja)]
        print(f"  ...de los cuales en franja '{args.franja}': {len(en_franja)}")
        for s in en_franja[:20]:
            print(f"      {s['fecha']} {s['hora']}")
        # comparar con lo del calendario de reagendar
        en_fecha = [s for s in libres if s["fecha"] == fecha
                    and iturnos.hora_en_franja(s["hora"], args.franja)]
        print(f"  ...y en franja '{args.franja}' + fecha {fecha}: {len(en_fecha)}")
        for s in en_fecha:
            print(f"      {s['fecha']} {s['hora']}")
    print()


def _diagnosticar_html(html: str, franja: str, fecha: str, franja_actual: str,
                       guardar: bool, sufijo: str):
    """Analiza el HTML del calendario de reagendar: conteo crudo, parsing,
    filtros. Opcionalmente lo vuelca a un archivo para inspección humana."""
    if guardar:
        path = f"diag_reagendar_{sufijo}.html"
        with open(path, "w", encoding="utf-8") as f:
            f.write(html)
        print(f"  HTML guardado en: {path}")

    # Marcadores de "no hay turnos" / form de login (perdió la sesión)
    if 'id="login-form"' in html:
        print("  ⚠️ el HTML tiene login-form → la sesión expiró o nunca quedó logueado")
        return
    if "No hay turnos disponibles" in html:
        print("  iTurnos dice 'No hay turnos disponibles' literal")

    # Conteo crudo via regex
    crudo_a = len(re.findall(r'class="[^"]*btn-outline-success', html))
    crudo_editar = len(re.findall(r'/editar/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}', html))
    print(f"  conteo crudo HTML:")
    print(f"    'btn-outline-success' (clase de slot libre):  {crudo_a}")
    print(f"    href '/editar/AAAA-MM-DDTHH:MM':              {crudo_editar}")

    # parsing oficial
    slots = iturnos.parsear_slots_reagendar(html)
    print(f"  parsear_slots_reagendar(): {len(slots)} slots")
    if slots:
        # agrupar por fecha
        por_fecha = {}
        for s in slots:
            por_fecha.setdefault(s.get("fecha") or "?", []).append(s)
        for fec in sorted(por_fecha):
            horas = sorted(s.get("hora") for s in por_fecha[fec])
            print(f"    {fec}: {len(horas)} → {', '.join(horas)}")

    # filtros del bot
    if not slots:
        print(f"  → 0 slots crudos → el bot reporta 'calendario vacío'")
        return
    ahora = datetime.now()
    # mismo filtro que iturnos.reagendar()
    en_franja = [s for s in slots
                 if iturnos.hora_en_franja(s["hora"], franja)]
    en_fecha = [s for s in en_franja if s.get("fecha") == fecha]
    futuros = [s for s in en_fecha if iturnos.slot_es_futuro(s, ahora)]
    print(f"  filtros del bot:")
    print(f"    en franja '{franja}':                         {len(en_franja)}")
    print(f"    + fecha == '{fecha}':                       {len(en_fecha)}")
    print(f"    + futuro (hora > {ahora:%H:%M}):              {len(futuros)}")
    if franja == iturnos.CUALQUIERA and franja_actual:
        otra_franja = [s for s in futuros
                       if iturnos.franja_de_hora(s["hora"]) != franja_actual]
        print(f"    + 'cualquiera' excluye franja actual ({franja_actual}): {len(otra_franja)}")
        futuros = otra_franja
    if futuros:
        print(f"  → el bot SÍ tendría {len(futuros)} candidato(s) y debería reagendar")
        for s in futuros[:10]:
            print(f"      {s['fecha']} {s['hora']}")
    else:
        print(f"  → el bot reporta 'sin_slot_en_franja' tras filtros")


if __name__ == "__main__":
    main()
