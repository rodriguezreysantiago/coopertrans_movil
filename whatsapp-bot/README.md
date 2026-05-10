# WhatsApp Bot — Coopertrans Móvil

Bot de Node.js que escucha la cola `COLA_WHATSAPP` en Firestore y envía
mensajes vía WhatsApp Web automatizado (`whatsapp-web.js`).

> ⚠️ **Aviso operativo**. WhatsApp prohíbe explícitamente bots no
> oficiales. Usar esto **solo con un número descartable** que NO sea el
> número principal de la oficina. Si Meta detecta el patrón, banea el
> número sin previo aviso.

## Arquitectura

```
[App Flutter]               [Firestore]                 [Bot Node.js]
admin → "enviar    →   COLA_WHATSAPP/                escucha la cola
        automático"     { telefono,                ←  toma cada doc PENDIENTE
                          mensaje,                     espera delay aleatorio
                          estado: PENDIENTE }    →    envía con wwebjs
                                                      marca ENVIADO o ERROR
```

La app Flutter no se conecta directamente con WhatsApp — solo escribe
docs en Firestore. Eso desacopla el ciclo de vida del bot del de la
app, y permite que la cola sobreviva si el bot se cae.

## Pre-requisitos

- Node.js 18+ instalado.
- `serviceAccountKey.json` de Firebase (el mismo que usa el resto del
  proyecto Flutter). Está en la raíz del repo principal.
- Un teléfono Android/iOS con WhatsApp instalado (el "número descartable").

## Setup inicial

### 1. Instalar dependencias

```bash
cd whatsapp-bot
npm install
```

`whatsapp-web.js` baja Chromium headless (~150 MB). Tarda un toque la
primera vez.

### 2. Configurar variables de entorno

```bash
cp .env.example .env
# editar .env con la ruta correcta a serviceAccountKey.json
```

### 3. Primer arranque (escanear QR)

```bash
npm start
```

En la consola va a aparecer un QR ASCII. **Abrí WhatsApp en el teléfono
descartable**, andá a `Ajustes → Dispositivos vinculados → Vincular un
dispositivo` y escaneá el QR.

A partir de acá la sesión queda guardada en `.wwebjs_auth/`. La próxima
vez que arranques no vas a tener que escanear nada — solo levanta y se
conecta automáticamente.

### 4. Pre-cargar contactos (importante)

Antes de mandar avisos automáticos, **agendá los teléfonos de los
choferes en los contactos del teléfono descartable**. WhatsApp es más
permisivo cuando manda a contactos guardados que cuando manda a números
"desconocidos". Hacer esto reduce el riesgo de baneo.

### 5. Calentar el número (opcional pero recomendado)

Antes de poner el bot en producción, intercambiá unos mensajes manuales
con varios choferes durante 2-3 días. Un número nuevo y silencioso que
de repente manda 30 mensajes es la señal más fuerte de bot. Un número
"con historia" pasa más desapercibido.

## Operación

### Levantar el bot

```bash
npm start
```

El bot:
1. Se conecta a Firestore.
2. Espera a que WhatsApp Web esté autenticado (instantáneo si ya
   escaneaste QR antes).
3. Comienza a escuchar la colección `COLA_WHATSAPP` en tiempo real.
4. Cuando aparece un doc con `estado: PENDIENTE`:
   - Verifica que esté en horario hábil (8-21 hs por default; si no,
     queda en cola para el día siguiente).
   - Espera un delay aleatorio de 15-60 segundos.
   - Envía el mensaje.
   - Marca el doc como `ENVIADO` con timestamp.
5. Si algo falla (chofer sin WhatsApp, número mal formado, sesión
   caída) marca `ERROR` con el detalle. El admin lo ve en la pantalla
   "Cola de WhatsApp" y puede reintentar manual o cancelar.

### Logs

El bot loguea a stdout. Si querés persistir, redirigí:

```bash
npm start >> logs/bot.log 2>&1
```

## Autostart en Windows (PC de oficina)

Para que el bot arranque solo cuando se prende la PC y se reinicie si
se cae:

### Opción A: Tarea programada de Windows

1. Abrir `Task Scheduler`.
2. `Create Basic Task` → nombre "WhatsApp Bot Vecchi".
3. Trigger: `When the computer starts`.
4. Action: `Start a program`.
   - Program: `C:\Program Files\nodejs\node.exe`
   - Arguments: `src/index.js`
   - Start in: `C:\Users\Colo Logistica\coopertrans_movil\whatsapp-bot`
5. En la pestaña Settings, marcá `If the task fails, restart every: 1
   minute, attempt 3 times`.

### Opción B: nssm (recomendado, más robusto)

`nssm` envuelve cualquier ejecutable como servicio Windows con auto-
restart inteligente.

```powershell
choco install nssm  # si no lo tenés
nssm install CoopertransMovilBot "C:\Program Files\nodejs\node.exe"
# UI gráfica: completar AppDirectory con la ruta del bot, AppParameters
# con `src/index.js`, y habilitar Auto-restart en Exit Actions.
nssm start CoopertransMovilBot
```

Para ver logs:

```powershell
nssm edit CoopertransMovilBot
# pestaña I/O → completar Output (stdout) y Error (stderr) con paths
# tipo C:\bot-logs\out.log y C:\bot-logs\err.log
```

## Estructura de un doc en COLA_WHATSAPP

La app Flutter escribe docs con este formato:

```javascript
{
  telefono: "+5492914567890",       // E.164 con +
  mensaje: "Hola Juan, te aviso...",
  estado: "PENDIENTE",              // PENDIENTE | PROCESANDO | ENVIADO | ERROR
  encolado_en: Timestamp,
  enviado_en: Timestamp | null,
  error: string | null,
  intentos: 0,
  origen: "aviso_vencimiento",      // free-form para auditoría
  destinatario_id: "12345678",      // DNI o patente
  destinatario_coleccion: "EMPLEADOS",
  campo_base: "LICENCIA_DE_CONDUCIR",
  admin_dni: "20111111",
  admin_nombre: "PEREZ JUAN",
}
```

El bot **solo lee y actualiza estos docs**. No crea ni borra — eso es
responsabilidad de la app o del admin.

## Fase 2 — Avisos automáticos

A partir de la Fase 2, el bot puede generar avisos por sí mismo, sin
que el admin los dispare desde la app. Está **deshabilitado por
default** — habilitalo en `.env` cuando confirmes que el envío manual
funciona bien.

### Cómo activarlo

```env
AUTO_AVISOS_ENABLED=true
CRON_INTERVAL_MINUTES=60
```

Reiniciar el bot. Va a aparecer en los logs:

```
Cron de avisos automáticos HABILITADO (cada 60 min).
```

### Qué hace

Cada `CRON_INTERVAL_MINUTES` (default 60), durante horario hábil
(`WORKING_HOURS_START`-`WORKING_HOURS_END`):

1. Lee `EMPLEADOS` y `VEHICULOS` de Firestore.
2. Por cada papel personal del chofer (Licencia, Preocupacional, ART,
   etc.) y por cada vencimiento de unidad asignada (RTO, Seguro,
   Extintores), calcula los días restantes.
3. Determina el nivel de urgencia:
   - **preventivo** (16-30 días): aviso temprano, "andá viendo el trámite".
   - **recordatorio** (8-15 días): "es buen momento para empezar".
   - **urgente** (1-7 días): "si no empezaste, hacelo ya".
   - **hoy** (0 días): "vence HOY, pasá por la oficina".
4. Si todavía no envió ese mismo aviso (chequea `AVISOS_AUTOMATICOS_HISTORICO`),
   lo encola en `COLA_WHATSAPP` y lo registra en el histórico.

### Idempotencia

Cada combinación `(chofer/unidad, papel, urgencia, fecha de vencimiento)`
se envía **una sola vez**. Si el papel se renueva (cambia la fecha en
Firestore), el id histórico cambia y los avisos del nuevo período se
generan limpios.

Los vencidos (días < 0) **NO** se procesan automáticamente — para esos
el admin sigue mandando manualmente. Es Fase 3 dejar que el bot también
recuerde diariamente sobre vencidos.

### Tono de los mensajes

El generador (`src/aviso_builder.js`) es un port directo del
`AvisoVencimientoBuilder` de la app Flutter. Los mensajes son idénticos
a los que el admin manda manualmente — incluida la firma
"_Mensaje automático del sistema..._".

Si querés cambiar el tono, modificá los dos archivos en paralelo
(Dart + JS) para mantenerlos sincronizados.

## Fase 3 (no implementada todavía)

El bot escucha respuestas de los choferes — si llega una foto + texto
a un mensaje de aviso, crea automáticamente una solicitud de revisión
en `REVISIONES`.
