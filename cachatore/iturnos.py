"""Cliente del iTurnos NUEVO (agendas.iturnos.com).

Reemplaza al cazador.py viejo, que apuntaba a secure.iturnos.com (dado de
baja por la migración de iTurnos).

Hallazgos de la revisión (2026-05-20):
- iTurnos migró: secure.iturnos.com -> agendas.iturnos.com (+ prestadores).
- El sitio está detrás de Cloudflare → `requests` queda bloqueado por
  fingerprint TLS. Usamos **curl_cffi** con impersonate="chrome" (pasa OK,
  STATUS 200 + cookies de sesión Laravel XSRF-TOKEN/_session).
- Login = Laravel estándar: form POST a /login con _token (CSRF) + email +
  password + remember.
- Agenda de carga YPF: cliente "proyecto-arenas-ypf",
  agenda "transporte-directo-a-anelo"
  (URL: /c/proyecto-arenas-ypf/a/transporte-directo-a-anelo).
- Server-rendered (no API JSON) → se parsea el HTML con BeautifulSoup.

PENDIENTE (capturar en un drop real, ~10:30 ART): el HTML de las franjas/
slots disponibles y el formulario final de reserva (campos exactos: patente,
DNI, empresa). Ver parsear_disponibilidad() y reservar() — marcados TODO.
"""
import re
from curl_cffi import requests as cf
from bs4 import BeautifulSoup

BASE = "https://agendas.iturnos.com"
LOGIN_URL = f"{BASE}/login"

# Agenda de carga YPF (slugs vistos en la revisión).
CLIENTE_SLUG = "proyecto-arenas-ypf"
AGENDA_SLUG = "transporte-directo-a-anelo"
AGENDA_URL = f"{BASE}/c/{CLIENTE_SLUG}/a/{AGENDA_SLUG}"

# Empresa que se tipea a mano en el formulario de reserva (constante, la
# misma para todos los choferes). Confirmado por Santiago 2026-05-20.
EMPRESA_CARGA = "VECCHI ARIEL Y VECCHI GRACIELA SRL"

# Las 4 franjas operativas (inicio/fin en minutos desde 00:00).
FRANJAS = {
    "madrugada": ("00:00", "05:30"),
    "manana":    ("06:00", "11:30"),
    "tarde":     ("12:00", "17:30"),
    "noche":     ("18:00", "23:30"),
}


def _hhmm_a_min(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def hora_en_franja(hora_slot: str, franja_key: str) -> bool:
    """¿El horario del slot (ej '06:30') cae dentro de la franja elegida?"""
    ini, fin = FRANJAS[franja_key]
    t = _hhmm_a_min(hora_slot)
    return _hhmm_a_min(ini) <= t <= _hhmm_a_min(fin)


def parsear_disponibilidad(html: str) -> dict:
    """Interpreta el HTML de la agenda (función pura, testeable).

    Estructura CONFIRMADA en un drop real (2026-05-20):
    - Horario OCUPADO  -> <button class="... btn-dark ...">11:00</button>  (sin link)
    - Horario LIBRE    -> <a class="... btn-outline-success ..."
                             href=".../reservar/2026-05-20T17:00">17:00</a>
    O sea: los libres son <a> cuyo href contiene "/reservar/{FECHA-HORA ISO}".

    Devuelve {disponible, slots:[{hora, fecha, iso, url}]}.
    """
    if "No hay turnos disponibles" in html or "pruebe más tarde" in html:
        return {"disponible": False, "slots": []}
    soup = BeautifulSoup(html, "html.parser")
    slots = []
    for a in soup.find_all("a", href=re.compile(r"/reservar/")):
        href = a.get("href", "")
        m = re.search(r"/reservar/([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2})", href)
        if not m:
            continue  # ej. el botón "Primer turno disponible" (href a la agenda)
        iso = m.group(1)
        fecha, hora = iso.split("T")
        slots.append({
            "hora": hora,
            "fecha": fecha,
            "iso": iso,
            "url": href if href.startswith("http") else BASE + "/" + href.lstrip("/"),
        })
    return {"disponible": len(slots) > 0, "slots": slots}


def slots_en_franja(slots: list, franja_key: str) -> list:
    """Filtra los slots libres que caen dentro de la franja elegida."""
    return [s for s in slots if s.get("hora") and hora_en_franja(s["hora"], franja_key)]


# Cartel que iTurnos muestra cuando el slot ya fue tomado por otro
# (Santiago 2026-05-20: el texto "máximo de iTurnos permitidos" NO significa
# que la cuenta esté excedida, sino que ESE turno ya lo agarraron).
_RE_TOMADO = re.compile(
    r"máximo de iTurnos|no disponible|ya fue tomado|no hay turnos", re.I)


class IturnosClient:
    """Sesión autenticada contra el iTurnos nuevo. Una instancia por chofer."""

    def __init__(self, timeout: int = 20):
        # impersonate chrome = TLS fingerprint de Chrome → pasa Cloudflare.
        self.s = cf.Session(impersonate="chrome", timeout=timeout)
        self.logueado = False

    # ---- LOGIN (validado: mecánica Laravel) --------------------------------
    def _csrf_token(self, html: str) -> str | None:
        soup = BeautifulSoup(html, "html.parser")
        # 1) hidden input _token dentro del form de login
        inp = soup.select_one('form#login-form input[name="_token"]')
        if inp and inp.get("value"):
            return inp["value"]
        # 2) fallback: meta csrf-token
        meta = soup.find("meta", attrs={"name": "csrf-token"})
        if meta and meta.get("content"):
            return meta["content"]
        return None

    def login(self, email: str, password: str) -> bool:
        """GET /login (toma cookies + _token) y POST de credenciales.
        Devuelve True si quedó logueado."""
        r = self.s.get(LOGIN_URL)
        token = self._csrf_token(r.text)
        if not token:
            return False
        resp = self.s.post(
            LOGIN_URL,
            data={
                "_token": token,
                "email": email,
                "password": password,
                "remember": "on",
            },
            allow_redirects=True,
        )
        # Éxito si nos fuimos de /login (Laravel redirige a /home) y no
        # volvió a mostrar el form de login.
        ok = ("/login" not in resp.url) and ('id="login-form"' not in resp.text)
        self.logueado = ok
        return ok

    # ---- AGENDA ------------------------------------------------------------
    def abrir_agenda(self) -> str:
        """Devuelve el HTML de la pantalla de tomar turno de la agenda YPF."""
        return self.s.get(AGENDA_URL).text

    # ---- RESERVA -----------------------------------------------------------
    def abrir_reserva(self, url: str) -> str:
        """GET de la pantalla de reserva de un slot (server-rendered).
        Devuelve el HTML: el FORMULARIO si el slot sigue libre, o el cartel
        de 'ya tomado' si lo agarró otro."""
        return self.s.get(url).text

    @staticmethod
    def reserva_tomada(html: str) -> bool:
        return bool(_RE_TOMADO.search(html))

    def reservar(self, slot: dict, patente: str, dni: str,
                 empresa: str = EMPRESA_CARGA,
                 capturar_en: str | None = "captura_form_reserva.html") -> dict:
        """Intenta reservar un slot.

        1) GET de slot['url'] (la pantalla de reserva).
        2) Si el slot ya fue tomado -> {ok:False, motivo:'tomado'}.
        3) Si aparece el FORMULARIO:
           - **MODO CAPTURA** (mientras no tengamos mapeados los campos):
             si `capturar_en` está seteado, vuelca el HTML a ese archivo y
             devuelve {ok:False, motivo:'form_capturado'} SIN enviar nada.
             Con ese HTML mapeamos action + nombres de campos (patente / DNI /
             empresa) + _token, y completamos el POST real acá abajo.

        TODO (tras capturar): armar el POST con los campos reales y confirmar.
        """
        html = self.abrir_reserva(slot["url"])
        if self.reserva_tomada(html):
            return {"ok": False, "motivo": "tomado"}
        if capturar_en:
            with open(capturar_en, "w", encoding="utf-8") as f:
                f.write(html)
            return {"ok": False, "motivo": "form_capturado", "archivo": capturar_en}
        # --- TODO: con los campos ya mapeados, armar y enviar el POST ---
        raise NotImplementedError(
            "reservar(): faltan mapear los campos del form (ver captura)"
        )
