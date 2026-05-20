# cachatore — sniper de turnos de carga YPF (iTurnos)

Herramienta para **sacar (reservar) automáticamente los turnos de carga** de
los choferes en **iTurnos**, en el momento del drop diario. Forma parte del
monorepo de **Coopertrans Móvil** (no es un proyecto Flutter aparte): el
**núcleo es este tool Python** (corre 24/7 en la PC dedicada) y la **UI de
control es un módulo dentro de la app Flutter** (`lib/features/cachatore/`,
capability `verCachatore`). La app escribe la selección en **Firestore** (qué
choferes, qué franja, prendido/pausado) y el bot la lee en vivo y le devuelve el
estado; reutiliza los datos de la app (mail + patente asignada del chofer).

> ⚠️ El `cazador.py` viejo (que vivía suelto en el Drive) quedó **obsoleto**:
> apuntaba a `secure.iturnos.com`, dado de baja por la migración de iTurnos.

## Cómo funciona (operativa)
- **Vigía 24/7** (`vigia.py`, corre como servicio en la PC dedicada del bot):
  queda **latente** todo el día escaneando suave la agenda. Si se libera un
  turno (porque alguien **canceló**) en la franja de un chofer que lo necesita,
  lo agarra al toque — **sin esperar al drop de las 10:30**.
- Por defecto el **drop time ya no importa**: el bot está **siempre latente**
  (barre cada ~5 s). El modo **agresivo** (cada chofer caza su agenda a full,
  en paralelo) queda solo para una corrida manual puntual con `--agresivo`.
- También **reagenda** (mueve un turno ya tomado) cuando se libera un slot mejor
  dentro de la franja, para los choferes marcados con `reagendar:true`.
- Escribe el **latido** del bot cada ~5 s (lo lee la app para mostrarlo vivo).
- 4 franjas: `madrugada` 00:00–05:30 · `manana` 06:00–11:30 ·
  `tarde` 12:00–17:30 · `noche` 18:00–23:30. Toma cualquier slot libre dentro
  de la franja del chofer. Además el comodín **`cualquiera`** ("cualquier
  horario", sin ventana): combinado con `fecha=None` agarra el **primer turno
  futuro** que se libere, sea la fecha y la hora que sea.
- **Solo slots futuros**: nunca reserva un horario ya pasado (guard
  `iturnos.slot_es_futuro`, hora local = ART), y entre los candidatos elige
  el **más próximo** primero.
- **Control desde la app**: el bot lee su worklist de **Firestore** (lo que
  edita el módulo Cachatore de la app: `CACHATORE_CONFIG/global` +
  `CACHATORE_OBJETIVOS/{dni}`) y devuelve el estado en vivo
  (`CACHATORE_ESTADO/bot` + estado por chofer). `activo` es el interruptor
  maestro (pausa todo). `drop.json` queda como fallback local (`--archivo`).
- `orquestador.py` sigue para una corrida **one-shot** manual (sin servicio):
  espera el drop, caza en paralelo y cierra.

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
  HTML real del drop), filtro por franja, `reservar()` (GET `/reservar/{ISO}`
  para tomar el slot en sesión + POST `/r/{cliente}/{agenda}` con los `campo[N]`),
  y **reagendar**: `mis_turnos()` (encuentra el UUID del turno del chofer) +
  `reagendar(uuid, franja)` (GET `/reagendar/calendario/{uuid}` → clickear un
  slot libre lo reasigna directo, sin formulario). mis_turnos validado.
- `choferes.py` — datos vivos de Firestore: por cada chofer (`ROL=CHOFER`) trae
  DNI + email (`MAIL`) + **patente vigente** (`ASIGNACIONES_VEHICULO` con
  `hasta==null`) + clave (de `claves.json`). Si se reasigna la unidad en la app,
  se refleja solo. `python choferes.py` lista todo (smoke test).
- `nube.py` — puente Firestore: lee la config que escribe la UI de la app
  (`CACHATORE_CONFIG/global` + `CACHATORE_OBJETIVOS` activos) y devuelve el
  estado en vivo (latido del bot + estado por chofer). Reusa `choferes._db()`.
- `verificar_logins.py` — prueba el login chofer por chofer y reporta a quiénes
  hay que corregirles el `MAIL`/clave. `python verificar_logins.py [N]`.
- `claves.ejemplo.json` — plantilla. El real es `claves.json` (gitignoreado):
  `{"_comun": "Cooper2022"}` (o per-DNI si alguno difiere).
- `orquestador.py` — corrida one-shot manual: a la hora del drop, en paralelo
  (un hilo por chofer) loguea, caza un slot en la franja de cada uno y reserva,
  con reintento. `python orquestador.py` (espera la hora) / `--ya` (arranca ya) /
  `--dry` (no reserva, testeo). La selección del día va en `drop.json` (plantilla
  `drop.ejemplo.json`, ambos gitignoreados).
- `vigia.py` — **el daemon 24/7** (lo que vive en la PC dedicada). Dos modos
  automáticos: **latente** (barre la worklist cada ~5 s — agenda a los que no
  tienen turno y reagenda a los marcados; caza cancelaciones) y **agresivo** (en
  la ventana `hora_inicio`, cada chofer caza su propia agenda a full). Por
  defecto lee la config de **Firestore** (UI de la app) cada ~30 s y escribe el
  estado/latido de vuelta; `--archivo` usa `drop.json` local sin tocar Firestore.
  Re-trae unidad/mail de Firestore cada ~10 min (si reasignás el camión, lo toma
  solo), re-chequea `mis_turnos` (no dobla reserva y sobrevive reinicios).
  `python vigia.py` / `--archivo` / `--dry` / `--latente` / `--agresivo`.
  Validado en `--dry` (nube) y `--dry --latente`.
- `instalar_servicio_vigia.ps1` / `ver_logs_vigia.ps1` — instalan el vigía como
  servicio NSSM (Auto diferido + log rotado a `logs/`) en la PC dedicada y siguen
  el log en vivo (coloreado por prefijo). Mismo patrón que el servicio del bot.
- `instalar_monitor_logs_vigia.ps1` — abre la ventana de logs del cachatore sola
  al iniciar sesión (shortcut en Startup), igual que la del bot → en la dedicada
  ves las dos ventanas (bot + cachatore).
- `instalar_todo_cachatore.ps1` — setup completo de un saque en la dedicada
  (Python + venv + deps + `claves.json` + `drop.json` + servicio + ventana de
  logs al login). Idempotente. `.\instalar_todo_cachatore.ps1 -Clave Cooper2022`.

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
- **Vigía 24/7 hecho**: daemon latente + agresivo + reagendar, con hot-reload de
  `drop.json`, re-pull de Firestore (refleja reasignaciones de unidad) y barrido
  de `mis_turnos` (no dobla reserva, sobrevive reinicios). Probado en
  `--dry --latente` (loguea, escanea read-only y no reserva). Servicio NSSM listo
  para la PC dedicada (`instalar_servicio_vigia.ps1`).
- **UI en la app hecha**: módulo `lib/features/cachatore/` (capability
  `verCachatore`, admin/supervisor) — interruptor maestro, hora del drop, fecha
  objetivo, alta/baja de choferes con franja + reagendar, y estado en vivo +
  latido del bot. La app escribe Firestore; `nube.py` lo lee. `flutter analyze`
  limpio; `nube` + `vigia --dry` validados contra Firestore real.
- **Pendiente**: deploy de `firestore.rules` (3 colecciones `CACHATORE_*`) +
  release de la app; confirmar en el 1er drop real (heurística de `reservar()` +
  reagendar real).

## Setup / correr
```bash
cd cachatore
python -m venv venv
venv/Scripts/pip install curl_cffi beautifulsoup4 firebase-admin
cp claves.ejemplo.json claves.json     # y poner la clave común (Cooper2022)
```
Requiere `serviceAccountKey.json` en la raíz del repo (un nivel arriba).
`claves.json` (credenciales) está **gitignoreado** — nunca se commitea.

### Servicio 24/7 en la PC dedicada
El vigía vive en la **misma PC dedicada del bot** (prendida 24/7). El `git pull`
(o el auto-update del bot) trae el **código**, pero el runtime no viene en git.
Un solo comando lo completa todo (Python + venv + deps + `claves.json` +
`drop.json` + servicio), en PowerShell **como administrador**:
```powershell
cd cachatore
.\instalar_todo_cachatore.ps1 -Clave Cooper2022   # idempotente, re-corrible
.\ver_logs_vigia.ps1                               # seguir el log en vivo
```
A mano sería: `python -m venv venv` + `pip install curl_cffi beautifulsoup4
firebase-admin`, poner `claves.json`/`drop.json` y `.\instalar_servicio_vigia.ps1`.
Queda como servicio `cachatore-vigia` (arranca solo al bootear, junto con el
auto-login de Windows). La selección la maneja la **UI de la app** (vía
Firestore); `drop.json` solo se usa con `--archivo`. Reiniciar/parar/arrancar
con cmdlets nativos (no hace falta `nssm` en el PATH — es un servicio de Windows
normal): `Restart-Service cachatore-vigia` · `Stop-Service ...` ·
`Start-Service ...`. **Tras un cambio de código de `vigia.py` hay que
`Restart-Service cachatore-vigia`** (el auto-update pull-ea pero no reinicia
este servicio).
