"""Diagnostico one-shot (NO reserva nada): loguea con un chofer real, abre el
formulario de reserva de un slot libre y lista TODOS los campos que pide
iTurnos (incluidos los ocultos). Sirve para arreglar reservar() cuando el POST
se rechaza por campos faltantes.

Hace SOLO el GET del formulario — NUNCA el POST de confirmacion, asi que no
saca ningun turno (equivale a un usuario que abre el form y no confirma).

Correr desde la raiz del repo con el venv del cachatore:
    cachatore\\venv\\Scripts\\python.exe cachatore\\inspeccionar_form_reserva.py
"""
import os
import sys
import time

from bs4 import BeautifulSoup

import choferes
import iturnos

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def _login_con_reintento(cred, intentos=3):
    cli = iturnos.IturnosClient()
    for i in range(intentos):
        try:
            if cli.login(cred["email"], cred["clave"]):
                return cli
        except Exception as e:
            print(f"  login intento {i + 1} error: {e}")
        time.sleep(1.5)
    return None


def main():
    cs = choferes.cargar_choferes()
    cred = next((c for c in cs if c.get("email") and c.get("clave")), None)
    if not cred:
        print("No hay ningun chofer con email+clave para loguear.")
        return
    print(f"Logueando con: {cred.get('nombre')} (patente {cred.get('patente')})")
    cli = _login_con_reintento(cred)
    if cli is None:
        print("Login FALLO tras reintentos (blip de Cloudflare? reintentar).")
        return
    print("Login OK.\n")

    disp = iturnos.parsear_disponibilidad(cli.abrir_agenda())
    slots = disp.get("slots", [])
    print(f"Slots libres en la agenda: {len(slots)}")
    if not slots:
        print("No hay slots libres ahora; no puedo abrir el form. "
              "Reintentar cuando haya disponibilidad.")
        return
    slot = slots[0]
    print(f"Abriendo el form del slot {slot['fecha']} {slot['hora']} "
          f"(GET, SIN reservar)...\n")
    html = cli.abrir_reserva(slot["url"])

    logs = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
    os.makedirs(logs, exist_ok=True)
    ruta = os.path.join(logs, "form_reserva_capturado.html")
    with open(ruta, "w", encoding="utf-8") as f:
        f.write(html)
    print(f"HTML completo guardado en: {ruta}")

    if iturnos.IturnosClient.reserva_tomada(html):
        print("OJO: el slot figura como 'ya tomado' — el form puede no venir.\n")

    soup = BeautifulSoup(html, "html.parser")
    forms = soup.find_all("form")
    print(f"\nForms en la pagina: {len(forms)}")
    for i, form in enumerate(forms):
        action = form.get("action", "")
        metodo = (form.get("method") or "GET").upper()
        campos = [c for c in form.find_all(["input", "select", "textarea"])
                  if c.get("name")]
        if not campos:
            continue
        print(f"\n=== FORM #{i}  method={metodo}  action={action} ===")
        for c in campos:
            tag = c.name
            tipo = c.get("type", tag)
            req = " [REQUERIDO]" if c.has_attr("required") else ""
            name = c.get("name")
            if tag == "select":
                opts = [(o.get("value"), o.get_text(strip=True)[:20])
                        for o in c.find_all("option")]
                print(f"  <select> {name}{req}  opciones={opts[:10]}")
            elif tag == "textarea":
                print(f"  <textarea> {name}{req}")
            else:
                val = c.get("value") or ""
                if name == "_token":
                    val = "(csrf, omitido)"
                elif len(val) > 20:
                    val = val[:20] + "..."
                print(f"  <input type={tipo}> {name} = {val!r}{req}")

    print("\nNO se hizo ningun POST: no se reservo ningun turno.")


if __name__ == "__main__":
    main()
