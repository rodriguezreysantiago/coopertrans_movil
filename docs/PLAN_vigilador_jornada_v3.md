# Plan — Vigilador de jornada v3: registro a posteriori sobre Sitrack

> Estado: PLAN (no ejecutado). Diseño acordado con Santiago 2026-06-07. Ejecutar
> en sesión dedicada, incremental, sin tirar el v2 de golpe.

## Objetivo
Resolver los 3 dolores del vigilador v2, que **salen de una sola raíz**:
- **Imprecisión** (no detecta bien paradas/manejo).
- **Reclamos / pérdida de credibilidad** con los choferes.
- **Fragilidad** del código (1700 LOC, máquina de estados en vivo que se descalibra).

## Diagnóstico (raíz común)
El v2 intenta saber la verdad **EN TIEMPO REAL**, con datos que llegan **tarde y con
huecos** (gaps de cobertura GSM). De ahí:
- imprecisión → en el momento el dato está incompleto (el evento de la parada todavía no llegó);
- reclamos → avisa "4h" con dato incompleto y el chofer sabe que paró;
- fragilidad → mantener estado tick a tick (bloque/pausa/flags) es frágil ante gaps/lag.

## Filosofía v3 — separar AVISO de REGISTRO
Hoy el v2 hace las dos cosas mezcladas y en vivo. Se parten:
1. **Aviso en vivo** = preventivo, blando, **solo con datos frescos**. Si hay gap → se calla.
2. **Registro de jornada** = la verdad, calculada **A POSTERIORI** (cierre de turno/día) con
   **todos los datos de Sitrack ya llegados**. Determinístico, auditable, transparente al chofer.

Cambio de fondo: **dejar de pelear con el tiempo real para la VERDAD.**

## Fuente: SOLO Sitrack (lo más completo hoy)
(Volvo descartado: snapshot sin histórico, posición 85% stale. Tacógrafo / input del chofer =
futuro, no dependencias ahora.)
- **SITRACK_EVENTOS** — la secuencia rica: `report_date`, `speed`, `gps_speed`, `event_id`,
  `latitude`/`longitude`, `driver_dni`, `asset_id` (~30 campos). Llega bufferada → a posteriori está **completa**.
- **SITRACK_POSICIONES** — snapshot por patente (para el aviso en vivo / frescura).
- **Exprimir las señales DIRECTAS** que hoy casi no se usan: eventos de **contacto/ignición ON-OFF**
  y **detenido / fin-de-detenido** (`event_id`) son más confiables que inferir de `speed`. El v2
  mira casi solo velocidad.

## Diseño

### Parte A — Aviso en vivo humilde (cambio chico sobre el v2 actual)
- Antes de disparar el aviso de bloque (3h30 / 4h): medir **confianza** = frescura del último
  dato del chofer. Si está viejo (gap > umbral) → **NO avisar** (postergar hasta tener dato fresco).
- Tono de recordatorio, no de acusación.
- Resultado: cero avisos injustos → **cortan los reclamos** sin tocar el cómputo.

### Parte B — Registro a posteriori (batch nuevo — el corazón de v3)
- Proceso batch al cierre del turno (cron de madrugada y/o al detectar fin de jornada) que, por chofer:
  1. Lee **TODOS** los eventos Sitrack de su turno (el turno completo, no la ventana de 2h).
  2. Reconstruye la línea de tiempo **manejo/pausa** cruzando: eventos de **ignición** (contacto OFF
     = parado), **detenido/fin-detenido**, **velocidad**, y **posición** (gap + mismo lugar = pausa,
     como el fix `d7b751f` del 07-jun).
  3. Calcula manejo neto, pausas y bloques — **determinístico y auditable**.
  4. Persiste el registro cerrado (doc de jornada / colección de registro).
- Batch sobre dato completo → **preciso y robusto** (sin estado tick a tick).

### Parte C — Transparencia al chofer (construye credibilidad)
- El chofer puede ver su jornada del día **explicada** (app/bot): "8 h de manejo; paraste
  13:50–14:40 en Baigorrita (motor apagado)". Revisable y justo → recupera credibilidad.
- (Opcional) un LLM **redacta** la explicación amigable; **el cálculo es SIEMPRE determinístico**
  (es laboral — nada de IA inventando horas).

## Plan incremental (el v2 sigue andando mientras se construye v3 al lado)
- **Paso 0 — Catalogar los `event_id` de Sitrack** relevantes (contacto ON/OFF, detenido,
  fin-detenido, etc.) y validar con data real (FERNANDEZ/LOPEZ del 06-jun) qué señales son confiables.
- **Paso 1 — Batch de reconstrucción como LÓGICA PURA** (extraída del I/O, testeable sin emulador
  — patrón ya usado en `tickVigiladorJornada`). + tests con los casos reales.
- **Paso 2 — Persistir el registro + pantalla/bot "mi jornada"** para el chofer (transparencia).
- **Paso 3 — Aviso en vivo humilde** (Parte A) sobre el v2 actual.
- **Paso 4 — "Destronar" el v2 como verdad**: el batch pasa a ser la fuente oficial
  (liquidación/disputa); el v2 queda solo como aviso preventivo.

## Principios
- **Determinístico** para las horas (laboral). LLM solo para redactar explicación, si acaso.
- **Incremental**: nada se rompe; v3 se construye al lado y recién al final destrona al v2.
- **Solo Sitrack** por ahora. Volvo/tacógrafo/input-chofer = mejoras futuras opcionales.
- **Lógica pura + tests** (el patrón ganador del repo).

## Riesgos / casos borde a cubrir
- Turnos que cruzan medianoche / multi-día.
- Detección del **cierre de turno** (¿reusar el criterio del v2: ~8 h motor apagado en misma posición?).
- Eventos Sitrack que llegan **muy tarde** (después del batch) → batch **idempotente / re-ejecutable**.
- Chofer sin Sitrack fresco (mismo límite de cobertura): el registro lo marca como **"baja confianza"**
  en vez de inventar — y ahí sí puede pedir confirmación al chofer (no antes).

## Paso 0 — RESULTADO (07-jun, HECHO)
Catálogo oficial leído (1427 tipos, en `G:\Mi unidad\API SITRACK\`) + verificado contra la data real
de Vecchi (scripts read-only en `whatsapp-bot/scripts/`: `catalogo_eventos_sitrack.js`,
`verificar_eventos_jornada_sitrack.js`).

**Señales de jornada CONFIABLES que ya recibimos** (frecuentes, casi todos los choferes):
- Parada: `6 Inicio de detenido`, `164 Contacto OFF` (motor apagado).
- Arranque: `7 Fin de detenido`, `163 Contacto ON`.
- Tracking en marcha: `283 Cambio de curso` (el evento más frecuente, ~57% del total).
- Por evento: `ignition` (0/1), `speed`, `latitude/longitude`, `hourmeter`.
- Baja cobertura: `386 Bloqueo celular y GPS` → marcador para "baja confianza".
→ Base sólida para el batch v3 (Parte B): contacto/detenido dan los bordes de cada pausa.

**HALLAZGO GRANDE:** Sitrack tiene un **módulo nativo de control de jornada** (`565/566 inicio/fin de
turno`, `152/513/514 conducción continua`, `1239/1246 descanso cumplido`, `1244/1245 preaviso`,
`190/191 exceso de conducción`) — pero en la cuenta de Vecchi está **APAGADO**: **0 de 24 tipos en
~90 días**. Si Sitrack lo activa, el equipo/plataforma calcula la jornada (turno, conducción continua,
descanso) y nosotros solo **consumimos** esos eventos → análogo al tacógrafo, pero con Sitrack que ya
está integrado. Máximo impacto, le saca el cálculo frágil al código. Requiere gestión con Sitrack
(activar el módulo + posible config por unidad/plan).

**Bifurcación para el Paso 1:**
- **A) Pedir a Sitrack activar el módulo de jornada** → consumir eventos nativos (máximo impacto,
  depende del proveedor / costo / tiempo).
- **B) Reconstruir el batch con lo que YA tenemos** (contacto/detenido + ignition + posición) →
  autónomo, más trabajo nuestro; es el plan v3 de arriba.
- **Ideal: pedir A en paralelo (gestión) y avanzar con B mientras** (B no queda bloqueado por A).

> **Decisión Santiago 07-jun: Camino B** (reconstruir nosotros, autónomo, sin depender de Sitrack).

## Paso 1 — DISEÑO DETALLADO (Camino B, listo para codear)
Reconstruir con las señales que ya tenemos. **Lógica PURA + tests, sin I/O** (patrón del repo:
se testea sin emulador). El v2 sigue corriendo en paralelo; v3 se construye al lado.

### Dónde
`functions/src/jornadas_v3.ts` (módulo nuevo) + tests `functions/test/jornadas_v3.test.js`.

### Input — `EventoJornadaLite`
Por cada evento Sitrack del turno: `ms`, `eventId`, `eventName`, `speed`, `gpsSpeed`,
`ignition` (0/1/null), `lat`, `lng`, `gpsValidity`. Se mapean de `SITRACK_EVENTOS`
(campos confirmados — ver poller `sitrack.ts:691`).

### Señales (event_id confirmados en el Paso 0)
- **Paró** (cierra tramo de manejo): `164 Contacto OFF`, `6 Inicio de detenido`,
  `331/332 Detenido sin/con contacto`. Refuerzo: `ignition==0`, `speed<=15`.
- **Arrancó** (reanuda): `163 Contacto ON`, `7 Fin de detenido`, `333/334 Movimiento`.
  Refuerzo: `ignition==1` + `speed>15`.
- **En marcha**: `283 Cambio de curso` + cualquier evento con `speed>15`.
- **Baja confianza**: `386 Bloqueo celular y GPS`, `gpsValidity` baja, o gaps sin posición.

### Algoritmo (determinístico, auditable)
1. Ordenar los eventos del turno por `ms`.
2. Armar SEGMENTOS alternados manejo/pausa con sus timestamps de borde:
   - Pausa = desde un evento "paró" hasta el siguiente "arrancó".
   - **Gap entre 2 eventos de movimiento** (sin eventos en el medio): misma posición
     (≤ `RADIO_PAUSA_GAP_METROS`=500) → PAUSA encubierta; se movió → manejo. (Reusar la idea
     de `analizarEventosDetencion`, fix `d7b751f`.)
3. Acumular **manejo neto** (Σ manejo) y **pausas** (Σ pausas).
4. Partir en **bloques** con el modelo del v2 (3h45 manejo + 15 min pausa; reusar
   `PAUSA_BLOQUE_SEGUNDOS` y demás constantes de `jornadas_v2.ts`).
5. **Turno**: inicio = primer movimiento del día; fin = descanso ≥8h misma posición
   (reusar `DESCANSO_RADIO_METROS` + criterio 8h del v2).
6. Marcar **confianza por segmento** (alta/baja según señales y cobertura).
7. Devolver `RegistroJornada { manejoNetoSeg, pausas[], bloques[], inicioTurno, finTurno,
   confianza, explicacion[] }`. `explicacion[]` = líneas legibles para el chofer
   ("paró 13:50–14:40 en Baigorrita — Contacto OFF").

### Tests (TDD — escribir primero)
Casos reales del 06-jun: **FERNANDEZ** (~50 min en Baigorrita), **LOPEZ** (baño en
Chinchinales). + sintéticos: turno simple, pausa por Contacto OFF/ON, pausa por gap+posición,
baja confianza por `Bloqueo GPS`, turno que cruza medianoche. Los eventos reales se sacan con
`whatsapp-bot/scripts/investigar_jornada_paradas.js`.

### Después del Paso 1 (no ahora)
Paso 2: persistir `RegistroJornada` (colección nueva) + pantalla "mi jornada" del chofer +
cron batch 1×/día (o al cierre de turno), idempotente. **NO deployar sin OK de Santiago**
(jornada = horas de trabajo, sensible).

## Paso 1 — RESULTADO (07-jun, HECHO · lógica pura + tests, SIN deploy)
Implementado `functions/src/jornadas_v3.ts` (batch puro, sin I/O) + `functions/test/jornadas_v3.test.js`
(24 tests, TDD). **Inerte en prod**: no lo importa `index.ts`, no exporta ninguna Cloud Function
todavía → `firebase deploy` no lo levanta. El v2 sigue intacto. Suite total functions **212/212**,
eslint limpio.

**API pública** (`jornadas_v3.ts`):
- `reconstruirJornada(eventos)` → `RegistroJornada` (primer turno) · `reconstruirJornadas` (todos) ·
  `partirEnTurnos` (corta por gap ≥ 8 h) · helpers `esParoEvento`/`esArranqueEvento`/`esMovimientoEvento`/
  `horaMinArt` + constantes.
- `RegistroJornada { inicioTurnoMs, finTurnoMs, manejoNetoSeg, pausaTotalSeg, segmentos[], pausas[],
  bloques[], bloquesExcedidos, confianza('alta'|'media'|'baja'), explicacion[] }`.
- Reusa del v2: `distanciaMetros`, `PAUSA_BLOQUE_SEGUNDOS`, `RADIO_PAUSA_GAP_METROS`,
  `DESCANSO_MIN_SEGUNDOS`, `UMBRAL_MOVIMIENTO_KMH`, `BLOQUE_EXCEDIDO_SEGUNDOS`.

**Decisiones finas (de la data real, no del catálogo):**
- **`ignition` NO es gatillo de paro.** Hay eventos `283` con `ignition==0` y `speed==75` (FERNANDEZ
  11:56) → en marcha el campo miente. El paro se decide por `event_id` (164/6/331/332); `ignition`
  queda solo informativo.
- **Contacto ON (163) NO es arranque.** El motor enciende pero el chofer sigue en pausa (LOPEZ: 163 a
  las 13:13, arranca de verdad 13:28 con `Fin de detenido`). Arranque = 7/333/334 o speed>15.
- **Dos umbrales de gap distintos**: pausa encubierta (misma posición ≤ 500 m) desde **15 min**; baja
  confianza por gap CON desplazamiento desde **30 min** (un tramo recto de autopista no dispara `283`
  por 15-25 min — marcar todo ≥ 15 min como "baja" volvería la señal inútil). Gap **sin posición** =
  ciego desde los 15 min.
- **Confianza global** por fracción del turno cubierta por TIEMPO de gap dudoso (no por segmentos
  enteros): un gap de 51 min adentro de 3 h de manejo ensucia esos 51 min, no las 3 h.

**Validación contra la data viva del 06-jun** (`whatsapp-bot/scripts/dump_eventos_jornada_v3.js`,
read-only, reconstruye con el compilado):
- **FERNANDEZ**: pausa **13:15–13:41 (26 min) motor apagado REGISTRADA** (la que el v2 no vio) +
  2 detenciones de playón (30/49 min); manejo neto 5h17 en 4 bloques, **0 excedidos**; la parada que
  el chofer ubica 13:50–14:40 cae en un gap de 51 min con +59 km → **no se inventa, se marca a
  revisar**. Confianza media.
- **LOPEZ**: pausa **12:28–13:28 (1h) ACREDITADA**; bloque 1 ≈ 3h22 (< 3h45) → **paró antes de las
  4 h, cero infracción** (el v2 le marcaba "4h05 y sigue manejando"). Confianza media.

**Siguiente: Paso 2** (persistir + pantalla "mi jornada" + cron batch idempotente). **NO deployar
sin OK de Santiago** (jornada = horas de trabajo, sensible).
