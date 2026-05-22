# Scrapers diarios en la PC dedicada (Volvo taller + ICM Sitrack)

Dos scrapers Playwright que corren **una vez por día** en la PC dedicada
(`coopertransmovil`) como Scheduled Tasks. No son daemons: corren, hacen el
`--commit` a Firestore y salen.

| Tarea | Hora | Qué hace | Escribe |
|---|---|---|---|
| `CoopertransSyncVolvoTaller` | 05:10 | Login Volvo Connect → último service + historial de taller por unidad | `VEHICULOS.ULTIMO_SERVICE_*`, `VEHICULOS_TALLER` |
| `CoopertransSyncSitrackIcm` | 06:10 | Login portal Sitrack → ICM oficial (el que audita YPF) por chofer y unidad | `ICM_OFICIAL/{YYYY-MM}` |

**Por qué diario y a esa hora:** Sitrack calcula el ICM en **batch diario**
(el día en curso recién aparece cuando cierra) → no tiene sentido más seguido.
Sitrack a las 06:10 (después de que cerró el día anterior); Volvo a las 05:10,
escalonado para no levantar dos chromium a la vez. Las tareas corren como el
**usuario logueado** (el del auto-login), NO como SYSTEM, así Playwright/chromium
usan el cache y el entorno del usuario (evita los problemas de chromium headless
bajo SYSTEM).

> El código nuevo llega solo por el auto-update (git pull cada 5 min). Pero los
> **prerequisitos de abajo son one-time a mano** (el auto-update NO crea venvs
> ni instala chromium ni pone credenciales).

## Setup (UNA vez, por RDP a la dedicada, con el usuario del auto-login)

### 1. Repo al día
```powershell
cd C:\coopertrans_movil
git pull --ff-only origin main
```

### 2. venv compartido + dependencias + chromium
```powershell
python -m venv C:\coopertrans_movil\sync_venv
C:\coopertrans_movil\sync_venv\Scripts\python.exe -m pip install --upgrade pip
C:\coopertrans_movil\sync_venv\Scripts\pip install playwright firebase-admin
C:\coopertrans_movil\sync_venv\Scripts\playwright install chromium
```
(Un solo venv para los dos scrapers → un solo chromium descargado.)

### 3. Credenciales (gitignoreadas, a mano)
- `C:\coopertrans_movil\serviceAccountKey.json` — clave del service account de
  Firebase en la raíz del repo. **Probablemente ya está** (la usan el bot y
  cachatore); si no, copiala.
- `C:\coopertrans_movil\volvo_sync\claves.json` — credenciales de Volvo Connect
  (`{"usuario": "...", "password": "..."}`). Copiá de `claves.json.example`.
- `C:\coopertrans_movil\sitrack_sync\claves.json` — usuario personal del portal
  Sitrack (`SantiagoRRey` + password). Copiá de `claves.json.example`.

### 4. Probar cada scraper a mano (dry-run, NO escribe)
```powershell
cd C:\coopertrans_movil\volvo_sync
C:\coopertrans_movil\sync_venv\Scripts\python.exe sync_taller.py

cd C:\coopertrans_movil\sitrack_sync
C:\coopertrans_movil\sync_venv\Scripts\python.exe sync_icm.py
```
- Volvo: tiene que listar las unidades con su último service.
- Sitrack: tiene que decir `login OK` + el ICM de flota + los peores choferes.
  Al loguear bien queda sembrada la sesión (`storage_state.json`) y las corridas
  siguientes ya no re-loguean.
- **Si el login de Sitrack falla por reCAPTCHA** (la página tiene uno; desde la
  oficina resultó pasivo, pero la IP de la dedicada podría dispararlo): avisame y
  agregamos un modo "headed" para sembrar la sesión a mano una vez. NUNCA se
  resuelve/saltea el CAPTCHA por código.

### 5. Instalar las Scheduled Tasks (PowerShell COMO ADMINISTRADOR)
```powershell
cd C:\coopertrans_movil\scripts
.\instalar_syncs_diarios.ps1
```

### 6. Verificar
```powershell
Get-ScheduledTask CoopertransSync*
# Correr una ya mismo para probar end-to-end (escribe Firestore):
Start-ScheduledTask -TaskName CoopertransSyncSitrackIcm
Start-Sleep 90
Get-Content C:\coopertrans_movil\sitrack_sync\logs\sync_diario.log -Tail 12
```

## Operación / mantenimiento

- **Logs:** `C:\coopertrans_movil\<scraper>\logs\sync_diario.log` (rotan a ~5 MB).
- **Correr a mano (con commit):** `.\correr_sync_diario.ps1 -Sync sitrack` (o `volvo`).
- **Desinstalar las tareas:** `.\instalar_syncs_diarios.ps1 -Remove`.
- **Si rotás credenciales** del portal/Volvo: editá el `claves.json` y borrá
  `sitrack_sync\storage_state.json` para forzar un login nuevo.
- **reCAPTCHA / sesión caída:** si el log muestra "sigue en login", la sesión
  expiró o el CAPTCHA se puso exigente → re-correr a mano el dry-run como usuario
  (re-siembra `storage_state.json`).
