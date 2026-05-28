# RUNBOOK — La PC dedicada murió

**Objetivo:** levantar el bot WhatsApp + cachatore en una PC nueva en ≤ 30 min, **sin re-escanear QR de WhatsApp ni re-cargar secrets**.

> Para fallas recuperables (corte de luz, Windows update, crash del proceso) **NO uses este runbook** — la PC dedicada se recupera sola en minutos. Solo abrí Tailscale RDP, mirá que `Get-Service CoopertransMovilBot, cachatore-vigia` digan `Running`, y listo.
>
> Usá este runbook **solo** cuando la PC físicamente no enciende, el disco se quemó, fue robada, o cualquier escenario donde el hardware esté perdido.

---

## Prerrequisitos antes de arrancar

1. **PC reemplazo:** cualquier Windows 10/11 con 8GB RAM, 20GB libres, Ethernet. No necesita ser potente.
2. **Acceso a Drive:** la cuenta Google que tiene `G:\Mi unidad\ClaudeCodeSync\` montada en tu PC actual. La vas a loguear en la PC nueva.
3. **Confirmá en tu PC actual** que el kit del Drive está fresco (< 24h):
   ```powershell
   notepad "G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\ULTIMO_BACKUP.txt"
   ```
   Si la fecha es de hoy o ayer → la sesión WhatsApp del kit sirve, NO vas a tener que re-escanear QR. Si es de hace semanas → preparate para escanear el QR físicamente con el teléfono del bot.

---

## Paso a paso

### 1. Conseguir PC + Internet (10 min)

- Encendé la PC, terminá el OOBE de Windows.
- Conectala a Ethernet (estabilidad > Wi-Fi).
- Logueate como **usuario admin local**.

### 2. Instalar Drive Desktop + esperar sync (5-15 min)

- Bajá Drive Desktop de https://drive.google.com/download
- Logueate con la cuenta Google que tenés `ClaudeCodeSync`.
- Esperá que aparezca `G:\Mi unidad\ClaudeCodeSync\` con sus carpetas.
- **Verificá que estos 2 paths existan:**
  - `G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\`
  - `G:\Mi unidad\ClaudeCodeSync\cachatore-pc-dedicada\`

### 3. Instalar BOT (10-15 min)

```powershell
# Click derecho → Run with PowerShell (acepta UAC)
G:\Mi unidad\ClaudeCodeSync\bot-pc-dedicada\instalar_todo.ps1
```

Hace todo solo: instala Node + Git, clona el repo en `C:\coopertrans_movil`, copia los secrets, `npm install`, registra `CoopertransMovilBot` como servicio NSSM, activa auto-update cada 5 min, smoke test.

**Validar:**
```powershell
Get-Service CoopertransMovilBot   # debe decir Running
```

### 4. Instalar CACHATORE (5-10 min)

```powershell
G:\Mi unidad\ClaudeCodeSync\cachatore-pc-dedicada\instalar_todo.ps1
```

Hace lo equivalente pero para el cachatore: Python 3.11+, venv, requirements, registra `cachatore-vigia` como servicio NSSM, monitor de logs en Startup.

**Validar:**
```powershell
Get-Service cachatore-vigia   # debe decir Running
```

### 5. Activar acceso remoto (Tailscale) — 5 min

- Bajá Tailscale de https://tailscale.com/download/windows
- Logueate con la misma cuenta que la PC vieja.
- La PC nueva se va a registrar con un IP nuevo en tu tailnet. Anotalo.
- En tu PC actual, abrí el `.rdp` guardado y editá la IP destino al nuevo.

### 6. Setup Windows para 24/7 (opcional pero recomendado — 10 min)

- **Auto-login Windows** sin password: usá `autologon.exe` de Sysinternals (https://learn.microsoft.com/sysinternals/downloads/autologon).
- **Power plan**: `powercfg /change standby-timeout-ac 0` y `powercfg /change disk-timeout-ac 0` (no dormir / no apagar disco).
- **BIOS auto-power-on después de corte de luz**: entrar al BIOS → buscar `AC Power Recovery` o `Restore on AC Power Loss` → setear a `On`. Crítico si tenés cortes de luz.

### 7. Activar backup automático del kit en esta PC nueva (5 min)

Para que esta PC nueva también empiece a backupear los secrets vivos al Drive todas las noches (en caso de que ESTA PC muera en el futuro):

```powershell
# PowerShell admin
C:\coopertrans_movil\scripts\backup_secrets_a_drive.ps1 -InstalarTask
```

Registra una Scheduled Task diaria a las 3:00 AM ART. A partir de mañana, el kit del Drive se mantiene fresco siempre.

---

## Si la sesión WhatsApp pide QR (kit > 2-3 semanas viejo)

Pasa cuando la PC vieja murió hace tiempo o el backup nocturno no estaba corriendo:

1. Conseguí el celular con el WhatsApp del bot.
2. RDP a la PC nueva (Tailscale).
3. Mirá los logs del bot: `Get-Content C:\coopertrans_movil\whatsapp-bot\bot.log -Tail 50`
4. Cuando aparezca el QR (formato ASCII en la consola), abrí WhatsApp en el cel → Más → Dispositivos vinculados → Vincular un dispositivo → escaneá.
5. La sesión queda persistida en `.wwebjs_auth/` y el próximo backup nocturno la sube al Drive.

---

## Si el WhatsApp del bot también se perdió (extremo)

Si robaron la PC dedicada Y el teléfono del bot:

1. Conseguí una SIM nueva con el número del bot (típicamente el de Vecchi para notificaciones).
2. Activá WhatsApp en cualquier teléfono.
3. Seguí el flujo del paso anterior.

Esto requiere coordinación administrativa (recuperar la línea con la operadora) — puede tardar 1-2 días. Mientras tanto, los mensajes del bot se acumulan en `COLA_WHATSAPP` y se mandan cuando la sesión vuelva.

---

## Anti-checklist (cosas a NO hacer)

- ❌ **NO levantes 2 instancias del bot al mismo tiempo** (PC vieja + PC nueva). WhatsApp banea el número si ve 2 sesiones procesando la misma cola. Apagá la vieja ANTES de prender la nueva, o desinstalá el servicio NSSM ahí.
- ❌ **NO commitees nada de `bot-pc-dedicada/` o `cachatore-pc-dedicada/`** — son kits con secrets, viven SOLO en el Drive.
- ❌ **NO uses el kit viejo si Drive Desktop está sincronizando** — esperá que termine. Si arrancás con el kit a medio bajar, los secrets pueden quedar corruptos.

---

## Anti-resumen — qué cubre cada componente

| Falla | Recuperación | Tiempo |
|---|---|---|
| Crash del proceso bot o cachatore | NSSM lo reinicia solo | ~5 seg |
| Windows update reinicio | Servicios arrancan solos (Auto + DelayedAutoStart) | ~2 min al boot |
| Corte de luz | BIOS auto-power-on → auto-login → servicios | ~3 min cuando vuelve la luz |
| PC cuelga total | Smart plug remoto te apaga/prende | manual desde la app del plug |
| IP local cambia | Tailscale tracking automático | 0 acción |
| Push de un bugfix | Auto-update cada 5 min pulea y reinicia | ≤ 5 min |
| **PC murió físicamente** | **Este runbook** | **30 min** |
