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

Capturado en el drop real del 2026-05-20:
- Slots: libre = <a class="btn-outline-success" href=".../reservar/{ISO}">.
- Reserva: GET /reservar/{ISO} (toma el slot en sesión) + POST /r/{cliente}/{agenda}
  con _token + Patente (campo[4767]) + DNI (campo[4768]) + Empresa (campo[5293]).
- Datos de cada chofer (DNI/email/patente vigente) salen de Firestore via
  choferes.py; la clave común sale de claves.json (local, gitignoreado).
La heurística de éxito de reservar() se afina con la 1ª reserva real.
"""
import re
from datetime import datetime
from curl_cffi import requests as cf
from bs4 import BeautifulSoup

BASE = "https://agendas.iturnos.com"
LOGIN_URL = f"{BASE}/login"

# Agenda de carga YPF (slugs vistos en la revisión).
CLIENTE_SLUG = "proyecto-arenas-ypf"
AGENDA_SLUG = "transporte-directo-a-anelo"
AGENDA_URL = f"{BASE}/c/{CLIENTE_SLUG}/a/{AGENDA_SLUG}"

# Confirmación de reserva: POST a /r/{cliente}/{agenda} (form capturado del
# drop 2026-05-20). El slot (fecha/hora) NO va en el body: queda "tomado" en
# la sesión al hacer el GET de /reservar/{ISO} previo. Los "campo[N]" son IDs
# propios de ESTA agenda en iTurnos (cambiarían si reconfiguran el form).
RESERVAR_ACTION = f"{BASE}/r/{CLIENTE_SLUG}/{AGENDA_SLUG}"
CAMPO_PATENTE = "campo[4767]"   # label "Patente Camión"
CAMPO_DNI = "campo[4768]"       # label "Nro DNI Chofer"
CAMPO_EMPRESA = "campo[5293]"   # label "Empresa de Transporte"

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

# Comodín: "cualquier horario" (sin ventana). La UI lo manda como codigo
# 'cualquiera' y el bot agarra cualquier slot; combinado con fecha=None es
# "el primer turno futuro que se libere, sea la fecha y la hora que sea".
CUALQUIERA = "cualquiera"


def franja_valida(franja_key: str) -> bool:
    """`True` para las 4 franjas o el comodín 'cualquiera'."""
    return franja_key == CUALQUIERA or franja_key in FRANJAS


def _hhmm_a_min(hhmm: str) -> int:
    h, m = hhmm.split(":")
    return int(h) * 60 + int(m)


def hora_en_franja(hora_slot: str, franja_key: str) -> bool:
    """¿El horario del slot (ej '06:30') cae dentro de la franja elegida?
    El comodín 'cualquiera' acepta cualquier hora."""
    if franja_key == CUALQUIERA:
        return True
    ini, fin = FRANJAS[franja_key]
    t = _hhmm_a_min(hora_slot)
    return _hhmm_a_min(ini) <= t <= _hhmm_a_min(fin)


def franja_de_hora(hora_slot: str):
    """Devuelve la franja ('madrugada'/'manana'/'tarde'/'noche') a la que
    pertenece un 'HH:MM', o None si no cae en ninguna. Sirve para EXCLUIR la
    franja actual cuando se reagenda con 'cualquiera' (= mover a otra franja)."""
    if not hora_slot:
        return None
    t = _hhmm_a_min(hora_slot)
    for key, (ini, fin) in FRANJAS.items():
        if _hhmm_a_min(ini) <= t <= _hhmm_a_min(fin):
            return key
    return None


def slot_es_futuro(slot: dict, ahora: datetime = None) -> bool:
    """`True` si el slot (fecha+hora del iso 'AAAA-MM-DDTHH:MM') es ESTRICTAMENTE
    posterior a `ahora` (hora local del equipo = ART). Evita reservar un horario
    ya pasado — clave para 'cualquier horario', donde no hay ventana de franja
    que descarte los de más temprano hoy. Si el iso no parsea, no lo descarta."""
    iso = slot.get("iso") or ""
    try:
        dt = datetime.strptime(iso, "%Y-%m-%dT%H:%M")
    except (ValueError, TypeError):
        return True
    return dt > (ahora or datetime.now())


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


def ordenar_slots_preferidos(slots: list) -> list:
    """Ordena los slots por PREFERENCIA de reserva: el DÍA más cercano primero
    y, dentro del día, la hora MÁS TARDE de la franja primero.

    Santiago (2026-05-22): 'tomá siempre el último turno de cada franja como
    primera opción y andá bajando' — ej. madrugada (00:00-05:30): intenta 05:30,
    después 05:00, 04:30... Como el bot reintenta cada ciclo, si el más tarde lo
    toman, en el próximo barrido agarra el siguiente más tarde (baja solo).

    Clave: (fecha ASC, hora DESC). Defensivo con campos faltantes/no parseables."""
    def _clave(s):
        try:
            min_desc = -_hhmm_a_min(s.get("hora") or "")
        except Exception:
            min_desc = 0
        return (s.get("fecha") or "", min_desc)
    return sorted(slots, key=_clave)


# Meses (es/en, por las primeras 3 letras) -> numero, para parsear el `cuando`
# legible de iTurnos ("Viernes 22 May 2026 10:00 hs.") a fecha ISO.
_MESES = {
    "ene": 1, "jan": 1, "feb": 2, "mar": 3, "abr": 4, "apr": 4, "may": 5,
    "jun": 6, "jul": 7, "ago": 8, "aug": 8, "sep": 9, "set": 9, "oct": 10,
    "nov": 11, "dic": 12, "dec": 12,
}
_RE_CUANDO_FECHA = re.compile(r"(\d{1,2})\s+([A-Za-záéíóú]+)\.?\s+(\d{4})")


def fecha_iso_de_cuando(cuando: str) -> str:
    """Extrae 'AAAA-MM-DD' del texto legible de un turno
    ('Viernes 22 May 2026 10:00 hs.' -> '2026-05-22'). None si no parsea."""
    if not cuando:
        return None
    m = _RE_CUANDO_FECHA.search(cuando)
    if not m:
        return None
    dia, mes_txt, anio = m.group(1), m.group(2)[:3].lower(), m.group(3)
    mes = _MESES.get(mes_txt)
    if not mes:
        return None
    return f"{anio}-{mes:02d}-{int(dia):02d}"


def turno_en_objetivo(turno_hora: str, turno_cuando: str, franja: str,
                      fecha_obj: str = None) -> bool:
    """`True` si el turno (hora 'HH:MM' + texto `cuando`) YA cae dentro de la
    franja pedida y, si `fecha_obj` no es None ('AAAA-MM-DD'), tambien en esa
    fecha. Sirve para que el bot detecte que un turno ya esta donde se queria y
    cancele solo el reagendar (en vez de seguir moviendolo). Conservador: si hay
    fecha objetivo y no se puede parsear la del turno, devuelve False (no
    cancela; mejor seguir intentando que cancelar de mas).

    OJO 'cualquiera': reagendar con el comodín = "moveme a OTRA franja". El slot
    actual SIEMPRE cae en 'cualquiera', así que si devolviéramos True se
    autocancelaría al toque (bug 2026-05-21). Por eso con 'cualquiera' NUNCA está
    "en el objetivo" → el bot sigue buscando en las demás franjas."""
    if not turno_hora or franja == CUALQUIERA:
        return False
    if not hora_en_franja(turno_hora, franja):
        return False
    if fecha_obj:
        return fecha_iso_de_cuando(turno_cuando or "") == fecha_obj
    return True


# Href de un slot del calendario de REAGENDAR: /editar/{AAAA-MM-DDTHH:MM}.
_RE_EDITAR_ISO = re.compile(r"/editar/(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2})")


def parsear_slots_reagendar(html: str) -> list:
    """Slots libres en el calendario de REAGENDAR (/reagendar/calendario/{uuid}).
    Mismo estilo que la reserva: libre = <a class="btn-outline-success">HH:MM</a>,
    pero al clickearlo **reasigna directo** (sin formulario de patente/DNI).

    OJO (2026-05-21, verificado en vivo): el calendario muestra la SEMANA ENTERA,
    no un solo día. Por eso cada slot trae su `fecha`+`iso` (los del href
    /editar/{ISO}); antes solo se sacaba la `hora` y el bot podía reagendar al
    DÍA EQUIVOCADO (elegía el primer <a> de la semana que cayera en la franja).
    Devuelve [{hora, fecha, iso, url}]. Ignora el botón 'Horarios' (href="#")."""
    soup = BeautifulSoup(html, "html.parser")
    slots = []
    for a in soup.find_all("a", class_=re.compile("btn-outline-success")):
        txt = a.get_text(strip=True)
        href = a.get("href", "")
        if not re.fullmatch(r"\d{1,2}:\d{2}", txt) or not href or href == "#":
            continue
        m = _RE_EDITAR_ISO.search(href)
        slots.append({
            "hora": txt,
            "fecha": m.group(1) if m else None,
            "iso": f"{m.group(1)}T{m.group(2)}" if m else None,
            "url": href if href.startswith("http") else BASE + "/" + href.lstrip("/"),
        })
    return slots


# Cartel que iTurnos muestra cuando el slot ya fue tomado por otro
# (Santiago 2026-05-20: el texto "máximo de iTurnos permitidos" NO significa
# que la cuenta esté excedida, sino que ESE turno ya lo agarraron).
_RE_TOMADO = re.compile(
    r"máximo de iTurnos|no disponible|ya fue tomado|no hay turnos", re.I)

# UUID del turno en el botón Cancelar de /misiturnos (mismo UUID que reagendar).
_RE_CANCELAR = re.compile(r"/misiturnos/cancelar/([0-9a-f-]{36})")


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
                 empresa: str = EMPRESA_CARGA, motivo: str = "") -> dict:
        """Reserva (confirma) un slot. Flujo CONFIRMADO el 2026-05-20:

        1) GET de slot['url'] (= /reservar/{ISO}) → "toma" el slot en la sesión
           y trae el formulario (con el CSRF token y los campos OCULTOS).
        2) Si ya lo agarró otro → {ok:False, motivo:'tomado'}.
        3) POST a la action del form (/r/{cliente}/{agenda}) con TODOS los
           campos ocultos del form + patente + DNI + empresa + motivo.

        CRÍTICO: el form trae `fecha` y `hora` como inputs OCULTOS que SÍ van
        en el body — sin ellos iTurnos rechaza la reserva. Ése era el bug del
        2026-05-20 (el bot no sacaba NINGÚN turno: mandábamos solo patente/DNI/
        empresa). Por eso arrastramos todos los hidden del form en vez de armar
        el body a mano — así también sobrevivimos si iTurnos agrega campos.

        Devuelve {ok, motivo, status, ...}.
        """
        html = self.abrir_reserva(slot["url"])
        if self.reserva_tomada(html):
            return {"ok": False, "motivo": "tomado"}

        soup = BeautifulSoup(html, "html.parser")
        form = soup.find("form", action=re.compile(r"/r/" + re.escape(CLIENTE_SLUG)))
        if form is None:
            return {"ok": False, "motivo": "sin_form"}
        # Arrastrar TODOS los campos del form (incluye _token, fecha, hora).
        data = {}
        for inp in form.find_all("input"):
            nombre = inp.get("name")
            if nombre:
                data[nombre] = inp.get("value", "")
        if not data.get("_token"):
            return {"ok": False, "motivo": "sin_token"}
        # Pisar los que cargamos nosotros.
        data[CAMPO_PATENTE] = patente
        data[CAMPO_DNI] = dni
        data[CAMPO_EMPRESA] = empresa
        data["motivo"] = motivo

        accion = form.get("action") or RESERVAR_ACTION
        resp = self.s.post(accion, data=data, allow_redirects=True)
        txt = resp.text or ""
        if self.reserva_tomada(txt):
            return {"ok": False, "motivo": "tomado", "status": resp.status_code}
        # Éxito: status OK y la respuesta no volvió a mostrar el form (que
        # tendría el campo de patente). El vigía igual lo re-confirma contra
        # mis_turnos, que es la fuente autoritativa.
        ok = resp.status_code in (200, 302) and (CAMPO_PATENTE not in txt)
        return {
            "ok": ok,
            "motivo": "reservado" if ok else "revisar",
            "status": resp.status_code,
            "url_final": resp.url,
        }

    # ---- REAGENDAR (mover un turno ya tomado a otro slot) ------------------
    def mis_turnos(self) -> list:
        """Turnos actuales del chofer logueado. Devuelve
        [{uuid, reagendar_url, cuando, hora}] — `cuando` es el texto legible que
        muestra iTurnos (ej. 'Miércoles 20 May 2026 14:00 hs.') y `hora` el HH:MM.
        Cada turno tiene un botón Cancelar con
        data-bs-href=.../misiturnos/cancelar/{uuid} y data-bs-info="<cuando>"
        (el UUID es el mismo que usa reagendar)."""
        html = self.s.get(f"{BASE}/misiturnos").text
        soup = BeautifulSoup(html, "html.parser")
        vistos, turnos = set(), []
        for btn in soup.find_all(attrs={"data-bs-href": _RE_CANCELAR}):
            m = _RE_CANCELAR.search(btn.get("data-bs-href", ""))
            if not m:
                continue
            uuid = m.group(1)
            if uuid in vistos:
                continue
            vistos.add(uuid)
            cuando = (btn.get("data-bs-info") or "").strip()
            hm = re.search(r"(\d{1,2}:\d{2})", cuando)
            turnos.append({
                "uuid": uuid,
                "reagendar_url": f"{BASE}/reagendar/calendario/{uuid}",
                "cuando": cuando or None,
                "hora": hm.group(1) if hm else None,
            })
        # Fallback: si la página no trajo botones Cancelar, sacar al menos los
        # UUID de los links de reagendar (sin fecha/hora).
        if not turnos:
            for m in re.finditer(r"/reagendar/calendario/([0-9a-f-]{36})", html):
                uuid = m.group(1)
                if uuid in vistos:
                    continue
                vistos.add(uuid)
                turnos.append({"uuid": uuid, "cuando": None, "hora": None,
                               "reagendar_url": f"{BASE}/reagendar/calendario/{uuid}"})
        return turnos

    def reagendar(self, uuid: str, franja: str, fecha: str = None,
                  franja_actual: str = None) -> dict:
        """Reagenda el turno {uuid} a un slot libre dentro de la franja (y de la
        `fecha` si se da: 'AAAA-MM-DD').

        `franja_actual`: si `franja=='cualquiera'`, EXCLUYE esa franja (la del
        turno actual) → "moveme a cualquier OTRA franja". Sin esto, con cualquiera
        se quedaba en la misma franja (bug 2026-05-21: VOGEL madrugada no salía
        de madrugada).

        Flujo CONFIRMADO 2026-05-20 (misma mecánica de 2 pasos que reservar):
        1) GET /reagendar/calendario/{uuid}[?d=AAAA-MM-DD] → lista los slots
           libres como <a href=".../editar/{ISO}">HH:MM</a>.
        2) GET de ese href (página /editar) → trae el FORM de confirmación con
           los ocultos `fecha` + `hora` (es read-only: NO reasigna por sí solo).
        3) POST a /reagendar/calendario/{uuid} con _token + fecha + hora → ahí
           recién se reasigna.

        Bug viejo (2026-05-20): hacía solo el paso 2 (GET de /editar) y asumía
        que reasignaba — nunca posteaba, así que NO movía el turno.
        """
        url = f"{BASE}/reagendar/calendario/{uuid}"
        if fecha:
            url += f"?d={fecha}"
        # El calendario trae la semana entera → filtrar por franja + fecha (si se
        # pidió) + que sea a futuro, y elegir el ÚLTIMO de la franja (día más
        # cercano, hora más tarde — ver ordenar_slots_preferidos). Sin el filtro
        # de fecha el bot reagendaba al día equivocado (ver parsear_slots_reagendar).
        ahora = datetime.now()
        slots = [s for s in parsear_slots_reagendar(self.s.get(url).text)
                 if hora_en_franja(s["hora"], franja)
                 and (not fecha or s.get("fecha") == fecha)
                 and slot_es_futuro(s, ahora)
                 # 'cualquiera' = otra franja: descartar los de la franja actual.
                 and not (franja == CUALQUIERA and franja_actual
                          and franja_de_hora(s["hora"]) == franja_actual)]
        if not slots:
            return {"ok": False, "motivo": "sin_slot_en_franja"}
        slots = ordenar_slots_preferidos(slots)
        slot = slots[0]

        # Abrir la página /editar del slot → trae el form de confirmación.
        html = self.s.get(slot["url"]).text
        if self.reserva_tomada(html):
            return {"ok": False, "motivo": "tomado", "hora": slot["hora"]}
        soup = BeautifulSoup(html, "html.parser")
        form = soup.find("form", action=re.compile(r"/reagendar/calendario/"))
        if form is None:
            return {"ok": False, "motivo": "sin_form", "hora": slot["hora"]}
        # Arrastrar todos los campos del form (incluye _token, fecha, hora).
        data = {}
        for inp in form.find_all("input"):
            nombre = inp.get("name")
            if nombre:
                data[nombre] = inp.get("value", "")
        if not data.get("_token"):
            return {"ok": False, "motivo": "sin_token", "hora": slot["hora"]}

        accion = form.get("action") or url
        resp = self.s.post(accion, data=data, allow_redirects=True)
        txt = resp.text or ""
        if self.reserva_tomada(txt):
            return {"ok": False, "motivo": "tomado", "hora": slot["hora"],
                    "status": resp.status_code}
        ok = resp.status_code in (200, 302)
        return {"ok": ok, "motivo": "reagendado" if ok else "revisar",
                "hora": slot["hora"], "status": resp.status_code}

    def cancelar(self, uuid: str) -> dict:
        """CANCELA el turno {uuid} en iTurnos. ⚠️ DESTRUCTIVO: libera el slot y no
        se puede deshacer. Flujo confirmado 2026-05-21: el botón "Cancelar" abre el
        modal #cancelarModal cuyo form #formCancelar (POST + _token) recibe
        action=/misiturnos/cancelar/{uuid} vía JS. Replicamos: GET /misiturnos para
        sacar el _token + POST a /misiturnos/cancelar/{uuid}. Verifica con
        mis_turnos que el turno ya no esté (verdad autoritativa)."""
        html = self.s.get(f"{BASE}/misiturnos").text
        soup = BeautifulSoup(html, "html.parser")
        token = None
        form = soup.find(id="formCancelar")
        if form is not None:
            inp = form.find("input", attrs={"name": "_token"})
            token = inp.get("value") if inp else None
        if not token:
            meta = soup.find("meta", attrs={"name": "csrf-token"})
            token = meta.get("content") if meta is not None else None
        if not token:
            return {"ok": False, "motivo": "sin_token"}
        resp = self.s.post(f"{BASE}/misiturnos/cancelar/{uuid}",
                           data={"_token": token}, allow_redirects=True)
        sigue = any(t.get("uuid") == uuid for t in self.mis_turnos())
        ok = (resp.status_code in (200, 302)) and not sigue
        return {"ok": ok, "status": resp.status_code, "sigue": sigue}
