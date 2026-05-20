# cachatore — sniper de turnos de carga YPF (iTurnos)

Herramienta para **sacar (reservar) automáticamente los turnos de carga** de
los choferes en **iTurnos**, en el momento del drop diario. Forma parte del
monorepo de **Coopertrans Móvil** (no es un proyecto Flutter aparte): el
**núcleo es este tool Python**; la **UI de control será un módulo dentro de la
app Flutter** (`lib/features/...`), reutilizando datos de la app (DNI + patente
asignada del chofer).

> ⚠️ El `cazador.py` viejo (que vivía suelto en el Drive) quedó **obsoleto**:
> apuntaba a `secure.iturnos.com`, dado de baja por la migración de iTurnos.

## Cómo funciona el drop (operativa)
- Los turnos se liberan ~**10:30 ART** (a veces lo cambian). El bot arranca
  ~1 min antes, reserva para **varios choferes en paralelo** (cada uno su
  cuenta) un turno dentro de la **franja elegida**, y cierra al terminar.
- 4 franjas: `madrugada` 00:00–05:30 · `manana` 06:00–11:30 ·
  `tarde` 12:00–17:30 · `noche` 18:00–23:30. Toma cualquier slot libre dentro
  de la franja del chofer.

## Hallazgos del sitio (revisión 2026-05-20, con la extensión Chrome)
- iTurnos migró a **`agendas.iturnos.com`** (Laravel) **detrás de Cloudflare**.
  → Python `requests` queda **bloqueado** por fingerprint TLS; **`curl_cffi`
  con `impersonate="chrome"` pasa** (STATUS 200 + cookies `XSRF-TOKEN`/`_session`).
- **Login**: form POST a `/login` con `_token` (CSRF) + `email` + `password` +
  `remember`. La clave es **común a todos los choferes**; el email sale del
  perfil de cada uno.
- **Agenda de carga**: "TRANSPORTE DIRECTO A AÑELO – PROYECTO ARENAS YPF"
  (Cantera El Mangrullo YPF, Ruta Prov. 45 Km 2,3, Ibicuy, Entre Ríos).
  URL: `/c/proyecto-arenas-ypf/a/transporte-directo-a-anelo`.
- **Slots** (server-rendered): ocupado = `<button class="btn-dark">`; **libre =
  `<a class="btn-outline-success" href=".../reservar/2026-05-20T17:00">`**.
  Patrón de reserva: `/reservar/{FECHA-HORA ISO}`.
- Al abrir un `/reservar/{slot}` ya tomado, iTurnos muestra
  *"...máximo de iTurnos permitidos"* — **eso significa "turno ya tomado"**, NO
  que la cuenta esté excedida.
- Al reservar se tipea a mano: **patente**, **DNI del chofer** y **empresa**
  (constante: `VECCHI ARIEL Y VECCHI GRACIELA SRL`). **Sin captcha.**

## Estado
- `iturnos.py`: cliente nuevo. **Hecho y testeado**: login (mecánica), parseo de
  disponibilidad (validado contra el HTML real del drop), filtro por franja,
  fetch de la pantalla de reserva + detección de "ya tomado", y un **modo
  auto-captura** que vuelca el HTML del formulario la 1ª vez que cace un slot
  libre (para mapear los campos y completar el POST de reserva).
- **Pendiente**: capturar el formulario de reserva (se auto-captura en el
  próximo drop) → completar `reservar()`; orquestador multi-chofer + scheduler;
  integrar DNI/patente desde Coopertrans Móvil; UI dentro de la app.

## Setup / correr
```bash
cd cachatore
python -m venv venv
venv/Scripts/pip install curl_cffi beautifulsoup4
cp cuentas.ejemplo.json cuentas.json   # y completar email + clave común + dni + patente + franja
```
`cuentas.json` (credenciales) está **gitignoreado** — nunca se commitea.
