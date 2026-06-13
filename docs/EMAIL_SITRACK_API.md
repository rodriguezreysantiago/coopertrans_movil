# Email a Sitrack — solicitud de configuración API

Borrador para enviar a `integraciones.ar@sitrack.com` (también CC `ingenieria@sitrack.com`).

Cubre tres pedidos en un solo mail:

1. Activar acumulación de reportes en `/files/reports` (forwarding por polling).
2. Activar `gpsHourmeter` en las unidades que hoy no lo traen (40 de 55).
3. Pedir presupuesto del sensor de enganche (`trailerId`) para algún tractor de prueba.

---

## Asunto

`Cuenta VECCHI SRL — solicitud de configuración API web services`

---

## Cuerpo del mail

```
Buenos días,

Soy el responsable informático de la integración API de SITRACK con
nuestra aplicación de gestión de flota en VECCHI ARIEL Y VECCHI
GRACIELA SRL (cuenta cliente con su usuario web service — ver vault).

Tenemos en curso una integración usando los siguientes endpoints de la
plataforma clásica AR (externalappgw.ar.sitrack.com):

  - GET /v2/report           ✅ funcionando OK
  - GET /assetStatus         ✅ funcionando OK
  - GET /files/reports       ⚠️  responde HTTP 200 con buffer vacío

Necesito coordinar con ustedes lo siguiente:

──────────────────────────────────────────────────────────────────
1) Activación de acumulación en /files/reports
──────────────────────────────────────────────────────────────────

Solicito que habiliten la acumulación de reportes en el buffer
dedicado para nuestra cuenta, con los siguientes parámetros:

  - Formato: JSON estándar (estructura documentada en
    "Integraciones-Estructura y formato de reportes").
  - Sin filtros — queremos recibir todos los reportes generados por
    las unidades de la cuenta (eventos por tiempo, identificación de
    chofer, ignición ON/OFF, eventos de zonas, etc).
  - Frecuencia de consumo prevista por nuestro lado: 1 invocación
    cada 5 minutos.

El uso principal de este endpoint es capturar el campo `driverCode`
(código del iButton/tarjeta del chofer) que solo viaja en los
eventos de identificación de conductor, para llevar nuestro propio
inventario de iButtons y validar contra la asociación que ustedes
mantienen del lado de su plataforma.

Avísenme cuando esté activado y desde ese momento empezamos a
consumirlo regularmente para no perder datos del buffer.

──────────────────────────────────────────────────────────────────
2) Activación de gpsHourmeter en toda la flota
──────────────────────────────────────────────────────────────────

Hoy, al consultar /v2/report, el campo `hourmeter` viene poblado
solo en 15 de las 55 unidades de la cuenta (las que tienen ICAN
con la ECU). El resto no devuelve `hourmeter` ni `gpsHourmeter`.

Solicito que activen el cálculo de `gpsHourmeter` (basado en el
sensor de ignición ON/OFF) en las unidades que actualmente no lo
tienen, para tener cobertura del 100% de la flota.

──────────────────────────────────────────────────────────────────
3) Presupuesto: sensor de enganche (trailerId)
──────────────────────────────────────────────────────────────────

Veo que el formato de reportes contempla los campos `trailerId` y
`trailerName` (patente del semirremolque enganchado al tractor),
pero ninguna de nuestras 55 unidades los está reportando — entiendo
que requiere un sensor adicional instalado en el tractor.

Quisiera coordinar con ustedes:

  - Costo de instalación del sensor de enganche por unidad.
  - Disponibilidad para hacer una prueba en 1 ó 2 tractores
    (ej. patente AI162YU u otra que ustedes sugieran) antes de
    decidir si lo extendemos a toda la flota.
  - Tiempo estimado de instalación y si requiere visita a la base.

──────────────────────────────────────────────────────────────────

Quedo atento a su respuesta para coordinar los puntos 1 y 2 (que
son configuración remota) y para agendar el punto 3 cuando puedan.

Muchas gracias.

Saludos,
Santiago [Apellido]
[Cargo / responsable informático]
VECCHI ARIEL Y VECCHI GRACIELA SRL
[Tu mail / teléfono]
```

---

## Notas para vos antes de mandarlo

- **Reemplazá** `[Apellido]`, `[Cargo / responsable informático]` y `[Tu mail / teléfono]` por tus datos reales.
- Asunto exacto: copia y pega "Cuenta VECCHI SRL — solicitud de configuración API web services". Conviene mantener "VECCHI SRL" tal cual figura en su sistema.
- Los emails confirmados según los PDFs:
  - `integraciones.ar@sitrack.com` — destinatario principal.
  - `ingenieria@sitrack.com` — CC, mencionado en los docs como contacto técnico general.
- Si tenés alguna persona de contacto comercial/técnica de Sitrack ya identificada (ej. quien armó la cuenta), agregarla al CC.

## Qué esperar como respuesta

- Punto 1 (`/files/reports`): activación remota, generalmente entre 1 y 5 días hábiles. Te pedirán confirmar el formato JSON elegido.
- Punto 2 (`gpsHourmeter`): config remota similar, mismo timeline.
- Punto 3 (sensor de enganche): respuesta comercial, te van a contactar por separado con presupuesto y agenda.

## Después de recibir respuesta del punto 1

Una vez activado `/files/reports`, hay que arrancar a consumirlo dentro de los 30 días siguientes — sino el buffer se purga. La Cloud Function `sitrackReportesConsumer` (Fase 4 del plan) tiene que estar lista o al menos en testing antes.
