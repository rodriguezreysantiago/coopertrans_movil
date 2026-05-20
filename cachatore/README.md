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

## Archivos
- `iturnos.py` — cliente del sitio: login, parseo de slots (validado contra el
  HTML real del drop), filtro por franja, y `reservar()` (GET `/reservar/{ISO}`
  para tomar el slot en sesión + POST `/r/{cliente}/{agenda}` con los `campo[N]`).
- `choferes.py` — datos vivos de Firestore: por cada chofer (`ROL=CHOFER`) trae
  DNI + email (`MAIL`) + **patente vigente** (`ASIGNACIONES_VEHICULO` con
  `hasta==null`) + clave (de `claves.json`). Si se reasigna la unidad en la app,
  se refleja solo. `python choferes.py` lista todo (smoke test).
- `verificar_logins.py` — prueba el login chofer por chofer y reporta a quiénes
  hay que corregirles el `MAIL`/clave. `python verificar_logins.py [N]`.
- `claves.ejemplo.json` — plantilla. El real es `claves.json` (gitignoreado):
  `{"_comun": "Cooper2022"}` (o per-DNI si alguno difiere).
- `orquestador.py` — el motor: a la hora del drop, en paralelo (un hilo por
  chofer) loguea, caza un slot en la franja de cada uno y reserva, con reintento.
  `python orquestador.py` (espera la hora) / `--ya` (arranca ya) / `--dry` (no
  reserva, testeo). La selección del día va en `drop.json` (plantilla
  `drop.ejemplo.json`, ambos gitignoreados).

## Estado (2026-05-20)
- **Login validado**: los **51 choferes no-tanque loguean OK** con el `MAIL` de
  la app + `Cooper2022`. (En corridas masivas hay blips transitorios de
  Cloudflare → el orquestador debe **reintentar** el login fallido.)
- **Integración Firestore validada**: 55 choferes; tanques/testers/inactivos
  omitidos como en la app; email + patente vigente correctos.
- `reservar()` implementado con el form capturado; la heurística de éxito se
  afina con la 1ª reserva real.
- **Orquestador hecho y validado**: login en paralelo + caza por franja +
  reintento + scheduler (espera hasta `hora_inicio`) + resumen. Probado en
  `--ya --dry` (2 choferes loguean en paralelo y pollean OK).
- **Pendiente**: confirmar la heurística de reserva en el 1er drop real + UI
  dentro de la app (`lib/features/`).

## Setup / correr
```bash
cd cachatore
python -m venv venv
venv/Scripts/pip install curl_cffi beautifulsoup4 firebase-admin
cp claves.ejemplo.json claves.json     # y poner la clave común (Cooper2022)
```
Requiere `serviceAccountKey.json` en la raíz del repo (un nivel arriba).
`claves.json` (credenciales) está **gitignoreado** — nunca se commitea.
