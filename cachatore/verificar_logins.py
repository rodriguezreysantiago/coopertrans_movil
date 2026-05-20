"""Verifica, chofer por chofer, que el login a iTurnos funcione con el email
(campo MAIL de la app) + la clave común (claves.json). Reporta cuáles fallan,
para corregirles el dato en la app (mail mal cargado, o clave distinta, o
chofer sin cuenta en iTurnos).

Uso:
    python verificar_logins.py [limite]   # limite opcional: probar solo N
"""
import sys
import time

import iturnos
import choferes

limite = int(sys.argv[1]) if len(sys.argv) > 1 else None
cs = choferes.cargar_choferes()
if limite:
    cs = cs[:limite]

ok, fallan = [], []
for c in cs:
    cli = iturnos.IturnosClient()
    try:
        logueado = bool(c["email"] and c["clave"]) and cli.login(c["email"], c["clave"])
    except Exception:
        logueado = False
    (ok if logueado else fallan).append(c)
    print(f"{'OK   ' if logueado else 'FALLA'}  {c['dni']:>10}  {(c['nombre'] or '')[:32]}")
    time.sleep(1.0)  # gentil con iTurnos/Cloudflare

print(f"\n=== {len(ok)} OK / {len(fallan)} fallan (de {len(cs)}) ===")
if fallan:
    print("Revisar email (MAIL) / clave en la app de:")
    for c in fallan:
        print(f"  - {c['nombre']} (DNI {c['dni']})")
