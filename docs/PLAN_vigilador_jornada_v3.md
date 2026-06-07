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

## Paso 2 — backend (07-jun, HECHO · DORMIDO, SIN deploy)
Capa de I/O alrededor de la lógica pura: `functions/src/jornadas_v3_batch.ts` +
`functions/test/jornadas_v3_batch.test.js` (13 tests). Calcado del patrón de `jornada_historico.ts`
(cron diario + backfill + funciones puras testeables), pero persistiendo la reconstrucción v3.
Suite functions **225/225**, eslint limpio.

**DOBLE RED para no tocar prod sin OK** (jornada sensible):
1. **No wired**: `index.ts` NO lo re-exporta → Firebase no lo ve, `firebase deploy` no crea nada.
2. **Dark por flag**: el cron chequea `META/config_vigilador_v3.registro_batch_activo` (default
   false) → aunque se deploye, no escribe hasta prender el flag, y se apaga al instante bajándolo.

**Qué hace** (cuando se active):
- Colección NUEVA `REGISTRO_JORNADAS`, permanente, en paralelo (NO toca `JORNADAS` del v2 ni
  `VOLVO_JORNADAS_HISTORICO`). Doc id determinístico `{dni}_{YYYY-MM-DD}` → idempotente +
  compatible con la regla que da al chofer su propio registro (`doc.split('_')[0] == uid`).
- `registrarJornadasV3Diario`: cron 06:45 ART, ventana [ayer 00:00, ahora] para completar turnos
  que cruzan medianoche; persiste solo los que INICIARON ayer (filtro inicio) → sin fragmentos.
- `backfillRegistrosV3`: callable ADMIN, reprocesa N días (1..60), idempotente.
- Funciones puras testeadas: `mapearDocEvento` (SITRACK_EVENTOS → EventoJornadaLite), `fechaArt`,
  `docIdRegistro`, `agruparYReconstruir`, `registroToFirestore`.
- Regla Firestore `REGISTRO_JORNADAS` agregada (lectura admin/supervisor/SEG_HIGIENE + chofer dueño;
  escritura solo CF) — **NO deployada** todavía.

**ACTIVACIÓN (3 pasos, los hace Santiago):**
1. `export * from "./jornadas_v3_batch";` en `functions/src/index.ts`.
2. `firebase deploy --only functions:registrarJornadasV3Diario,functions:backfillRegistrosV3` +
   `firebase deploy --only firestore:rules`.
3. Prender `META/config_vigilador_v3.registro_batch_activo = true` (o correr el backfill 1×).
Recomendado: backfill de unos días → comparar `REGISTRO_JORNADAS` vs `JORNADAS` (v2) en los casos
en disputa antes de exponerlo al chofer.

## Validación v3 vs v2 (07-jun, "validar primero" · read-only, SIN deploy)
Script `whatsapp-bot/scripts/validar_jornada_v3.js` (read-only): corre la reconstrucción v3 contra
los SITRACK_EVENTOS reales de Firestore y la compara, lado a lado, con lo que registró el v2
(colección JORNADAS), sobre los 5 casos del buzón REPORTES_DISCREPANCIA del 06-jun. NO escribe nada.

**Resultado: v3 reivindica los 5/5 casos en disputa.** Detecta TODAS las pausas que los choferes
reclamaban, con evidencia (`Contacto OFF` / `Inicio de detenido`) y confianza por tramo:
- **FERNANDEZ** (DNI 26129762): v3 muestra 5 pausas que cierran bloque (incl. 13:15–13:41 motor
  apagado, la del reclamo). Manejo neto 12h30 → **dispara el flag de jornada excedida** (ver abajo).
- **LOPEZ** (22987952): pausa 12:28–13:28 (1 h, baño Chinchinales) acreditada; paró antes de 4 h.
- **WEIMANN** (32563425): pausa 09:45–10:13 (27 min) + un descanso parcial nocturno de 5h13.
- **CHAVEZ** (24861891): pausa 12:48–13:10 (21 min) + parada larga 14:09–17:49 (3h40).
- Todos con confianza media/baja (la data real tiene gaps) → honesto, "revisar antes de liquidar".

**Hallazgo de la validación → fix aplicado:** con el día COMPLETO, FERNANDEZ manejó 12h30 NETAS en
5 bloques, ninguno > 4 h. El registro no lo señalaba (solo medía el exceso por bloque de 4 h). Se
agregó `RegistroJornada.jornadaExcedida` (manejo neto ≥ 12 h, paridad con la `cuota` del v2) + línea
en la explicación. Tests: 227/227 functions. Commit del fix junto con el script de validación.

**Lectura para decidir el deploy:** el v2 suele mostrar `total_manejo` inflado porque la jornada
quedó ABIERTA (no cerró por descanso) y arrastró horas a la madrugada; el v3 reconstruye el turno
real con sus pausas y lo explica. Antes de exponer al chofer conviene 1–2 semanas de
`REGISTRO_JORNADAS` real (deploy + flag) para comparar a escala.

## Pulido con data de flota (07-jun · read-only, SIN deploy)
Auditor `whatsapp-bot/scripts/auditar_jornada_v3.js` (read-only): corre v3 sobre TODA la flota y N
días, lista anomalías + distribución + modos `detalle <dni> <fecha>` e `histograma <dias>`. Destapó
dos cosas:

1. **BUG dominante — corte de turno (ARREGLADO).** Sobre 6 días, la mayoría de los turnos abarcaban
   ~24 h (manejo inflado 11-16 h, 44 falsos "jornada excedida"). Causa: el descanso nocturno casi
   nunca es un GAP — el equipo manda heartbeats con el camión parado, y el corte solo miraba gaps de
   ≥8 h. Caso real GASTON DIETRICH: descansó **7h44** (21:48→05:32) y, con corte estricto a 8 h, su
   turno encadenaba día+noche+día.
   **Fix:** corte de turno UNIFICADO a nivel de segmento — cualquier intervalo/pausa ≥ 7 h sin
   actividad es un descanso y corta el turno (cubre gap apagado + pausa en el lugar). El umbral 7 h
   se eligió con el **histograma de pausas** (8 días/~270 chofer-días): breaks decrecen hasta un
   valle en 5-7 h y los descansos repuntan en 7-8 h (60) con pico 8-9 h (80). Resultado: anomalías
   "turno largo" de ~50 → ~8; turnos bien cortados; FERNANDEZ ahora cierra el turno cuando estaciona
   (21:27), no metido en la noche.
2. **Señal nueva — `descansoInsuficiente` (AGREGADO).** Al cortar a 7 h se podía perder que un
   descanso fue < 8 h (mínimo legal). Se agregó `RegistroJornada.descansoPrevioSeg` + `descanso
   Insuficiente` (descanso previo < 8 h): **19 turnos con descanso corto en 6 días** que antes eran
   invisibles (sepultados en el turno de 24 h). Compliance real para Vecchi.

**Verificado:** el **drift multi-patente** (un DNI con 2 patentes solapadas, que mezclaría 2 camiones)
NO aparece en 6 días de flota → ese riesgo no se materializó (queda el auditor para vigilarlo). La
**confianza** es a nivel intervalo (precisa): los pocos "manejo absurdo" (>14 h) que quedan son
turnos largos reales o levemente inflados por telemetría rala, bien marcados `excedida` + media/baja
para revisión (límite honesto de reconstruir con data rala — no se ocultan manejando los gaps como
descanso). Suite functions **231/231**, eslint OK. Los 5 casos en disputa siguen reivindicados 5/5.

## Inflado de manejo — INVESTIGADO, no existe (07-jun · read-only)
Sospecha: en telemetría rala (eventos cada 1-3 h), ¿se cuenta como manejo tiempo en que el camión
estuvo parado dentro del gap? Medido 3 formas con `auditar_jornada_v3.js gaps` + `detalle`:
1. **Velocidad promedio de los gaps** "con desplazamiento" (≥30 min, ambos extremos en movimiento),
   8 días, 922 gaps: **97% promedian ≥ 55 km/h, 621 en 70-85 km/h** (crucero). Solo 22 gaps (2,4%)
   bajan de 55.
2. **Descuento simulado** (estimar manejo = distancia/crucero): con crucero 70 km/h se descontaría
   2% del tiempo de gaps; con 60, ~0%. No hay nada material que descontar.
3. **Cross-check distancia ÷ manejo** en los casos "absurdos": GASTON 1025 km/15,8 h = 65 km/h;
   LACEAR 1047/15,9 = 66; BAJENETA 1124/17,0 = 66; FERNANDEZ 840/12,6 = 66. La velocidad implícita
   ~65 km/h es manejo REAL de ruta (si fuera inflado por idle/paradas daría 25-40 km/h).

**Conclusión:** el manejo NO está inflado. Los "15-17 h" son días de manejo REALES (1000+ km) =
sobre-jornada grave que v3 detecta correctamente (`jornadaExcedida` + confianza baja/media para
revisión). **Descontar manejo sería un atajo peligroso: ocultaría violaciones de seguridad reales y
acreditaría descanso que no ocurrió.** No se toca la lógica de manejo. El descuento físico
(distancia/crucero) queda DESCARTADO por la evidencia. (Si en el futuro aparecen unidades con
telemetría que sí muestre idle contado como manejo, el auditor `gaps` lo detectaría — vigilar.)

**Siguiente (con OK de Santiago): pantalla/bot "mi jornada"** que lee `REGISTRO_JORNADAS` y muestra
el registro explicado (pausas + confianza + descanso insuficiente) — la pata de transparencia del
Paso 2. Después: Paso 3 (aviso en vivo humilde) y Paso 4 (destronar al v2). **Nada se deploya sin OK
de Santiago.**
