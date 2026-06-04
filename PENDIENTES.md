# Pendientes follow-up

Cosas que requieren acción nuestra en una fecha específica. Para roadmap general
del proyecto, ver `ESTADO_PROYECTO.md`. Para procedimientos operativos, `RUNBOOK.md`.

Convención: orden cronológico (los próximos arriba). Sacar el ítem cuando se ejecuta.

---

## 📅 2026-06-04 — Sesión grande: agente IA + cachatore + tarifas + mantenimiento + Volvo

~17 commits (todo en main + pusheado). **Bot y Cloud Functions YA en producción**
(auto-update PC dedicada + `firebase deploy`). La **app Flutter espera el release**
que larga Santiago.

### ✅ YA en producción (NO requieren release)
**Bot WhatsApp** (auto-update ≤5 min c/u):
- Groq eliminado → **Gemini de PAGO** único proveedor (key en `.env` de la dedicada).
- Agente: jornada reporta manejo **NETO**; nueva tool **`crear_adelanto`** (2 pasos
  con confirmación, escribe `ADELANTOS_CHOFER`); **buscador de nombres tolerante a
  tildes + orden invertido** (unificado con cachatore); log del fallback
  (`es_fallback`); no fuerza tools en charla social; **alerta WhatsApp al admin si
  Gemini se queda sin saldo** (throttle 6h, `AGENTE_SIN_SALDO_ALERT_DNI` →
  fallback `COLA_CRECIENTE_ALERT_DNI`).
- **Anti-auto-respuesta DEFINITIVO** — 3 capas: firma `Bot-On` + `BOT_PHONE` +
  **descarte por ID del saliente** (`wa.esMensajePropio`). El de ID cierra el
  "hablan entre ellos" del vigilador (el reflejo del saliente llega corrupto en
  sesión recién vinculada → solo el id es infalible).
- Cachatore: reprocesa re-pedidos de reagendar (reset `reagendar_hecho` por
  franja/fecha) + polling 30→8 s; logs en **DD-MM sin año** + reagendado muestra
  **fecha + hora** (sin franja).
**Cloud Functions** (deployado southamerica-east1): **vigilador de jornada cierra
por GAP de reportes** (fix "dormí 8 h → me decía 12 h" — equipo apagado de noche).
**Firestore**: limpiado el fantasma `alertasVolvoDiario` de `BOT_HEALTH/main`.

### 📦 EN EL RELEASE que largás (app Flutter)
- **Cachatore**: card muestra "buscando reagendar" EN VIVO (KPI + badge por flag
  `reagendar`, ya no condicionado por estado).
- **Tarifas**: "CHOFER FIJO $X" cuando el chofer cobra monto fijo (antes mostraba
  "$0" engañoso).
- **Mantenimiento**: **editar el service a mano** (km último service, fecha, km
  actual) desde el detalle — override mientras Volvo no reporta.
- (+ lo acumulado desde el bump 1.0.88+91 si no se había subido: versionado de
  tarifas por vigencia, filtro de Flota por tipo, tooltip de jornada, etc.)

### 🔧 Pendientes / a verificar (Santiago)
- **Alerta de presupuesto de Gemini** en Cloud Billing (preventiva; el aviso del
  bot es reactivo). Ver "cómo vigilar el saldo".
- **Corregir 2 tarifas** mal cargadas: Sea White (B.Bca) → La Martineta (Gral
  Lamadrid) sin tarifa de chofer; Río Colorado → Monte Hermoso (Devic) chofer **$2**.
- **¿Franja de reagendar de AVIT?** Quedó "noche"; si pediste "tarde", hay bug del
  selector de reagendar → confirmar.
- **Monitorear primer día**: vigilador de jornada (avisos coherentes) +
  anti-auto-respuesta (log `[handler] reflejo de saliente propio descartado por id`).

### 🟡 Para retomar (en pausa)
Monitor de frescura Volvo · fallbacks de mantenimiento a Sitrack · suscripciones
Volvo de las 16 unidades (ver entrada "Auditoría Volvo" abajo).

---

## 📅 2026-06-04 — Auditoría Volvo: 16 unidades con suscripción VENCIDA (decisión: dejar en Sitrack por ahora)

**Confirmado por Santiago**: 16 tractores Volvo tienen la suscripción de Volvo Connect **vencida** — cortaron transmisión casi simultáneamente **~29-may**. El poller los sigue "viendo" (consultado_en <1h) pero la API devuelve el último estado **congelado** de hace ~6 días. Auditoría completa esta sesión (datos en vivo en Firestore + mapeo de código con agentes).

**Patentes** (16 asignadas a choferes activos, congeladas ~6 d): AC114PY, AC114QQ, AC114QP, AB927WN, AB927WU, AC274LU, AC114QR, AB421DP, AC274IS, AC383ND, AC114PX, AC383OM, AB493CP, AC114PZ, AG848IK (2 d). Más **AH490YJ** (29 d — parada de verdad, muerta también en Sitrack) y 2 sin asignar (AB787RS, AF869ZU, probablemente paradas).

**Qué se perdió** (exclusivo de Volvo, irrecuperable sin renovar): combustible / AdBlue / autonomía · tell-tales del tablero (mantenimiento predictivo) · scores eco-driving (L/100km, CO₂) · alertas de seguridad activa (AEBS/ESP/LKS).

**Qué NO se perdió** — Sitrack cubre toda la flota (55) y **ya está reportando esas 16 en vivo**: posición/velocidad, odómetro, iButton (chofer), sobrevelocidad cartográfica, conducta (frenada/aceleración brusca vía ICM), zonas/descargas, jornada. **El ICM oficial que audita YPF sale de Sitrack, NO de Volvo → relación con YPF intacta.** El 70% operativo siempre vivió en Sitrack; Volvo era el "plus" de telemetría de motor.

**DECISIÓN (Santiago, 2026-06-04): dejar como está, operar esas 16 con Sitrack, NO renovar Volvo por ahora.** Revisitar si se necesita el control de combustible / mantenimiento predictivo de esas unidades.

**Para retomar (NO hacer ahora, quedó pausado):**
1. 🥇 **Monitor de frescura** — el verdadero problema fue perder 16 unidades 6 días sin enterarse. Cron que avise por WhatsApp cuando una unidad asignada deja de transmitir posición >X h. Esfuerzo chico, alto valor, **independiente de la decisión de suscripción**.
2. **Service por km/horas → fallback a Sitrack** (`odometer` / `hourmeter`) para unidades sin Volvo. Horas solo donde hay ICAN (~15/55); km en todas. Verificar que el mantenimiento caiga bien.
3. **Mejoras de código** (del mapeo): `volvoAlertasPoller` y `volvoScoresPoller` NO reintentan ante 401/403/500 (el cursor de alertas no avanza → riesgo de perder eventos en outage transitorio) — igualar a `telemetria.ts`. Colecciones muertas `ULTIMO_SERVICE_KM`/`ULTIMO_SERVICE_FECHA` (vacías; el dato vive en `VEHICULOS_TALLER`) → limpiar.
4. **Decisión de fondo**: renovar Volvo de las 16 (recupera combustible/eco/tell-tales/seguridad) vs seguir en Sitrack. Combustible vía Sitrack existe como módulo aparte (suscripción).

**El pipeline Volvo está SANO**: poller cada 5 min sobre 53/53, auth OAuth OK, alertas en tiempo real (última hace minutos), telemetría fresca, campos clave 53/53. El problema es 100% de suscripción, no del código.

---

## 📅 2026-05-29 — macOS enviado a review de Apple 🎉

Frente macOS destrabado end-to-end y **app enviada a review** del Mac App Store.
Detalle técnico en `ESTADO_PROYECTO.md` (entrada 2026-05-29) y `docs/RUNBOOK_macos_signing.md`.

**✅ Hecho hoy** (commits `c7c1c62`, `be9999c`, `7db6cee`, `1897091`):
- Pantalla negra de arranque resuelta (faltaba `macOS` en flutter_local_notifications +
  Firebase macOS sin configurar + inits de `main()` sin try/catch).
- Deployment target Podfile macOS → 11.0 (−86% warnings de build); Podfile versionado.
- Página de soporte `public/soporte.html` deployada (Support URL daba 404 → ahora 200).
- Listing macOS completo: capturas 2560×1600 (DNI propio borrado; la de Descargas
  DESCARTADA por exponer PII de otros choferes), promo, descripción, keywords.
- functions: 0 warnings (fix max-len en `comun.ts`). Entorno Mac alineado: Flutter 3.44.0 + SPM off + Node 26.

**⏳ Pendiente:**
1. **Esperar aprobación de Apple** (1-3 días) → publicar (modo **manual** elegido). Si rechazan, leer motivo y ajustar.
2. **Confirmar que el login demo `00000001` sigue activo** — es la causa #1 de rechazo de Apple (probar el login antes de que revisen).
3. **Android — análisis de warnings**: NO se pudo en la Mac (sin Android SDK). Pendiente desde la PC Windows: `flutter build appbundle` capturando el log de Gradle/Kotlin y clasificar (como se hizo con macOS).
4. **Limpieza menor**: borrar `~/Desktop/appstore_macos/_originales_sin_procesar/` (respaldo de capturas crudas) cuando se confirme que las finales entraron OK en el listing.

---

## 📅 2026-05-28 — Revisión de pendientes (varios cerrados) + setup PC nueva

Revisión del estado real contra el código. **Cerrados / obsoletos:**

- **Logística multi-tramo — features chicas**: TODO resuelto. Reordenar y
  duplicar tramos los descartó Santiago el 14-may (innecesarios en la práctica);
  validación de encadenamiento (banner amarillo), buscador en empresas y tarifas,
  pantalla de viajes borrados (toggle "Mostrar eliminados" + Reactivar) y export
  de liquidación a Excel (`report_liquidacion.dart` → `.xlsx`) ya implementados.
- **iOS — listing App Store**: hecho. App **aprobada + LIVE en App Store público**
  2026-05-28 → distribución multiplataforma completa (Windows + Play + iOS).
- **Sitrack P4 — tiempo promedio de descarga**: el KPI ya lo muestra la pantalla
  Descargas (`admin_descargas_screen`, promedio en min). Queda solo ranking por
  chofer + alerta de outliers (esperar ~1 mes de data).
- **Bot PC dedicada + acceso remoto**: operativos desde 2026-05-18 (NSSM +
  Tailscale `100.99.223.44` + RDP). Ver `project_bot_pc_dedicada.md`.
- **Setup PC de desarrollo nueva**: `docs/SETUP_PC_DESARROLLO.md` (toolchain:
  Flutter 3.44.0, Node 22 nvm, etc.) + `secrets\README_RESTAURACION.md` del Drive.

**Decisión abierta de ICM**: el "baseline odómetro" del CESVI quedó **moot** — la
UI usa el ICM **oficial** de Sitrack desde el 22-may y el CESVI está desconectado.
Lo que queda es decidir si **retirar** el CESVI (ver sección operativa abajo).

---

## 📅 2026-05-24 — Actualización del estado de propuestas Volvo/WhatsApp

### ✅ HECHO hoy (commits del 24-may)

- **V5 Bypass de seguridad** (`onAlertaVolvoCreated` extendido):
  DAS / LKS / LCS / AEBS ya NO van al chofer (él los apagó) → van a
  Molina con throttle 6h por (patente, tipo). Helper
  `_notificarBypassSeguridad` + colección META_BYPASS_SEGURIDAD.

- **WhatsApp Bot — mejoras menú** (M1 + M2 + M3): breakdown enviados
  por categoría, búsqueda free-form en cola, badge en tile panel.
  M4 ya estaba.

- **Card "Reglas de notificación" completa**: 16 reglas en 5 categorías
  reflejan TODA la realidad operativa (no las 3 viejas).

### ⚠️ HALLAZGOS que reorientan tareas

- **V1 (Tablero Seguridad)**: el agente del inventario se equivocó.
  `VOLVO_SCORES_DIARIOS` tiene los 17 sub-scores de EFICIENCIA
  (anticipation/idling/topgear/etc.) — NO los de SEGURIDAD
  (Defensivo/Atención/Uso funcional que vimos en Volvo Connect web).
  Para hacer V1 real hay que agregar un poller a `/safetyReport` (M).
  Postponed.

- **V2 (Ralentí)**: la pantalla Eco-Driving YA expone `idling` por
  unidad + drill-down con los 17 sub-scores. Una pantalla nueva
  "Ralentí" sería redundante. Lo que SÍ falta:
  · % real de ralentí (no el score Volvo, el % de tiempo del informe
    Rendimiento — requiere endpoint /performance o cálculo desde
    /vehiclestatuses con ignition + speed).
  · Estimación monetaria L perdidos × precio diésel.
  Ambos requieren ingest nuevo. Postponed.

- **Bonus (Eco-Driving detallado)**: YA estaba implementado de antes.
  La pantalla muestra los 8 principales + drill-down con los 17.

- **C P3 (DTCs históricos Sitrack)**: requiere scraper Sitrack web
  nuevo (`sync_dtcs.py` en `sitrack_sync/`). Postponed.

- **E M5 (Editar destinatarios desde la app)**: refactor de ~10 CFs
  para que lean los DNIs de Firestore `META/destinatarios_notificacion`
  en lugar de hardcoded en `comun.ts`. Pantalla CRUD. Postponed por
  scope (M-L), pero queda como prioritario porque ya lo flageó la
  auditoría del 2026-05-18 y mantenimiento es realmente importante
  para evitar dependencia técnica si cambia un destinatario.

---

## 📅 2026-05-24 — Análisis Volvo Connect vs nuestra app — propuestas pendientes

Exploración profunda del portal Volvo Connect (9 módulos del app launcher
+ 8 informes estándar + dashboard) + inventario exhaustivo del lado nuestro
(qué ya consumimos vs qué no). **8 propuestas priorizadas por ROI**. Hoy
se cerró V6 — las 7 restantes quedan acá como roadmap.

### ✅ HECHO hoy

- **V6 — Widget Km Recorridos** (commit `3507d4a`). Sorpresa: TELEMETRIA_HISTORICO
  ya tenía snapshot diario por las 53 unidades Volvo (`telemetriaSnapshotScheduled`
  cada 6h). Solo faltaba consumirlo. Nuevo widget en
  AdminMantenimientoDetalleScreen con KPIs mes en curso vs anterior +
  gráfico 30 días + tabla 3 meses (km, L, l/100km). Service
  OdometrosService calcula deltas client-side.

### ⏳ PENDIENTE — ordenadas por ROI

#### 🥇 V1 — Tablero Seguridad por chofer (data ya en Firestore, solo UI)
**Esfuerzo: S. Valor: 🔥🔥🔥**

`VOLVO_SCORES_DIARIOS` ya tiene 17 sub-scores del API Volvo (Defensivo, Atención,
Uso funcional, etc.). La pantalla Eco-Driving solo muestra eficiencia.
**Toda la data de seguridad está, falta UI.**

Plan: pantalla nueva "Seguridad" en hub ICM con score 78 + 3 sub-scores
(Defensivo 85 / Atención 53 / Uso funcional 91) + 12 sub-métricas (Distance
Alert, ABS, frenado brusco, advertencia colisión, DAS, LKS, LCS, AEBS) +
ranking unidades por score seguridad + WhatsApp diario a Molina con
unidades < 60.

#### 🥈 V2 — Métrica RALENTÍ % por chofer/unidad (combustible perdido)
**Esfuerzo: M. Valor: 🔥🔥🔥**

Hoy desperdiciamos plata sin medir. Volvo lo expone en informe Rendimiento
(% ralentí, % PTO, % punto muerto, % programador velocidad por vehículo).
**1 punto % menos de ralentí flota = ~3000 L/mes = $1.500.000 ARS/mes.**

Plan: extender `volvoScoresPoller` para persistir `ralenti_pct`, `pto_pct`,
`punto_muerto_pct` por vehículo/día (los campos ya vienen del API).
Pantalla "Combustible" en Reportes con ranking + L perdidos estimados +
$/mes + alerta WhatsApp si una unidad > 35% ralentí 3 días seguidos.
Cruce con chofer asignado via SITRACK_IBUTTONS_HISTORICO.

#### 🥉 V3 — Calendario citas taller FUTURAS (visibilidad Emmanuel)
**Esfuerzo: M. Valor: 🔥🔥🔥**

Hoy Emmanuel sabe lo PASADO (sync_taller.py historial). NO sabe qué hay
PROGRAMADO. Volvo `/calendar` tiene cada cita con tipo (Diagnóstico/Reparación)
+ taller + dirección + tel + estado.

Plan: scraper Playwright `sync_calendario.py` en volvo_sync/ → escribe
VEHICULOS_CITAS_TALLER/{patente}_{fecha_iso}. Pantalla "Calendario taller"
en Mantenimiento (vista mes con citas). WhatsApp a Emmanuel cada lunes
06:00: "Esta semana van al taller: AF472BO mié 30/abr (Ruta Sur Trucks
Bahía Blanca)". Tile en panel: "3 citas próximas".

#### 4️⃣ V4 — Reporte mensual sostenibilidad CO₂/NOx/PM para YPF
**Esfuerzo: M. Valor: 🔥🔥🔥** (diferenciador comercial)

YPF y clientes corporativos PIDEN datos de emisiones. Volvo los calcula
(informe Medioambiental: CO₂ t, NOx kg, PM kg por unidad).

Plan: scraper extrae informe Medioambiental mensual → VOLVO_EMISIONES_MES/{YYYY-MM}.
Pantalla "Sostenibilidad" en Reportes (CO₂ t mensual + por unidad + tendencia
anual). Excel exportable "Reporte de Emisiones Vecchi — Mes X" listo para
enviar a YPF.

#### 5️⃣ V5 — Capturar "DAS desactivado" + alertas bypass de seguridad
**Esfuerzo: S. Valor: 🔥🔥🔥** (señal grave hoy invisible)

Cuando un chofer apaga DAS/AEBS/LKS, deliberadamente apaga la seguridad.
Volvo lo emite como alerta separada. Hoy probablemente cae en nuestra
blacklist genérica.

Plan: auditar tipos de alerta en VOLVO_ALERTAS últimos 30 días → identificar
"DAS desactivado" / "Sistema deshabilitado". Whitelist específica
(DAS_DISABLED, DISTANCE_ALERT_DISABLED, LKS_DISABLED) → SIEMPRE al admin
(no al chofer). WhatsApp inmediato a Molina. Ranking mensual top 5 unidades
con más DAS-disabled.

#### 6️⃣ V7 — Monitor suscripciones Volvo vencidas
**Esfuerzo: S. Valor: 🔥** (preventivo, evita perder data)

Dashboard muestra 6 suscripciones vencidas hoy. Si vencen las críticas
(Posicionamiento, Telemetría, Alerts API), perdemos data sin enterarnos.

Plan: scraper extiende sync_taller.py para leer el widget de suscripciones
semanalmente. Si hay vencidas → alerta a Santiago para renovar antes.

#### 7️⃣ V8 — Frenadas/Aceleraciones/ESC/Distance Alert por 100 km
**Esfuerzo: S. Valor: 🔥🔥**

Hoy comparamos choferes por # eventos absolutos. Un chofer que hizo 3000 km
naturalmente tiene más eventos que uno que hizo 1000 km. Volvo normaliza
por 100 km — comparación justa.

Plan: extender VOLVO_SCORES_DIARIOS con los promedios/100km que Volvo
expone en informe Seguridad. Agregar columnas al ranking ICM:
"Frenadas/100km", "Aceleraciones/100km", "ESC/100km".

### ❌ DESCARTADOS con justificación

- **Libro de Registro Volvo**: chat con taller. Vecchi no lo usa, nuestro
  módulo de Taller es propio.
- **Mensajería Volvo**: chat con asistencia. WhatsApp ya cubre.
- **Tienda de servicios Volvo**: gestión comercial externa.
- **Administración usuarios/vehículos Volvo**: gestión externa, no fluye
  nada operativo a la app.
- **Informe Resumen + Seguimiento**: duplican lo que tenemos en pantallas propias.

---

## 📅 2026-05-24 — Análisis Sitrack vs nuestra app — propuestas pendientes

Auditoría completa del portal Sitrack (43 endpoints / vistas inventariados) + cruce
con nuestra app. **6 propuestas priorizadas por ROI**. Hoy se cerraron 2 — las 4
restantes quedan acá como roadmap para próximas sesiones.

### ✅ HECHO hoy

- **P2 — Histórico real de iButton** (`7d9919d`). Pipeline desde `SITRACK_EVENTOS`
  con CF diaria + backfill + pantalla "Auditoría asignaciones" que cruza contra
  `ASIGNACIONES_VEHICULO`. 1.755 tramos cargados.
- **P4 (parcial) — Cola de descargas YPF Añelo** (`78f50aa` + `2ad40be`). Reemplaza
  PTO Volvo por geocercas Sitrack configurables. Filtro por rango de fecha+hora.
  Falta: el KPI específico "tiempo promedio descarga" + ranking choferes + alerta
  outliers (acumular ~1 mes de data primero y después decidir).

### ⏳ PENDIENTE — ordenadas por ROI

#### 🥇 P1 — Auto-poblar viajes desde Sitrack (ROI MÁXIMO)
**Esfuerzo: M (3-7 días). Valor: 🔥🔥🔥**

Hoy: cada viaje en `VIAJES_LOGISTICA` se carga MANUAL (chofer / unidad / origen /
destino / fecha_carga / fecha_descarga / km). Es la fricción más grande del módulo.

**Plan:**
1. Definir geocercas en Sitrack para los 5-10 lugares clave (YPF Añelo, plantas
   Vecchi, destinos GASPERINI, etc.). 1 vez, en Sitrack web.
2. Scraper nuevo `sitrack_sync/sync_viajes.py` cada 30 min:
   - `tiempoEnZona.php` (rango ayer→hoy) — entradas/salidas por chofer
   - `tiempoViaje.php` (rango ayer→hoy) — viajes detectados
3. CF que ingiere y propone viajes:
   - Patrón "estadía >30min origen → movimiento → estadía >30min destino"
   - Crea `VIAJES_LOGISTICA` con `estado='PROPUESTO_SITRACK'` (no `EN_CURSO`)
   - Pre-llena chofer, unidad, fecha_carga, fecha_descarga, tarifa sugerida
4. Pantalla nueva "Viajes propuestos" en hub Logística — admin revisa y confirma
   con 1 click.

**Impacto:** ahorro de horas/mes de operador, 0 errores de tipeo, métricas reales
de duración. **Esto sólo justifica el proyecto.**

#### 🥈 P3 — DTCs históricos para Emmanuel (alto valor, rápido)
**Esfuerzo: S (1-2 días). Valor: 🔥🔥🔥**

Hoy: sólo tell-tales del momento actual (Volvo `VOLVO_ESTADO`). Si un Check Engine
se prende y apaga sin que Emmanuel mire en ese instante, lo perdemos.

**Plan:**
1. Extender `sync_icm.py` (o nuevo `sync_dtcs.py`) para llamar
   `historicoCodigoFalla.php` (últimos 7 días) → array de DTCs por unidad.
2. Persistir `VEHICULOS_DTC_HISTORICO/{patente}_{ts}` (idempotente por timestamp).
3. **Sumar al "Parte de mantenimiento" 08:00 de Emmanuel**
   (`resumenMantenimientoVehiculosDiario`):
   - "Tractor AB421DP: 3 códigos de falla últimos 7 días (P0507, P0420, P1259)"
   - DTC recurrente 3+ veces → highlight rojo "REVISAR"
4. Pantalla "Historial DTCs" en mantenimiento detalle por unidad.

**Impacto:** mantenimiento PREDICTIVO real (no reactivo). Emmanuel anticipa fallas.

#### 🥉 P5 — Consumo combustible cubriendo NO-Volvo
**Esfuerzo: M. Valor: 🔥🔥**

Hoy: `report_consumo.dart` sale de `TELEMETRIA_HISTORICO` (Volvo) — sólo cubre los
53 Volvo. Las unidades no-Volvo quedan fuera.

**Plan:**
1. Scraper consulta `/site5/fuel_consumption/` (toda la flota).
2. Persistir `SITRACK_CONSUMO_DIARIO/{patente}_{YYYY-MM-DD}`.
3. Modificar `report_consumo.dart` para cruzar Volvo + Sitrack — consumo unificado.

**Impacto:** cobertura total de la flota Vecchi.

#### 6️⃣ P6 — Auditar geocercas + Reglas Sitrack
**Esfuerzo: S. Valor: 🔥** (bajo en código, alto en operación)

Hoy: no sabemos qué reglas / geocercas tiene Vecchi configuradas en Sitrack.

**Plan:**
1. Santiago abre las Reglas en Sitrack y lista qué hay vs qué falta.
2. Configurar las que faltan (ej. "Salir de zona Bahía Blanca después de las 02:00"
   → alerta operativa).
3. Documentar en un doc o card admin.

**Impacto:** complementa el sistema de alertas existente con triggers nativos
Sitrack que NO requieren código nuestro.

### ❌ DESCARTADOS con justificación

- **Adm Mantenimiento de Sitrack** (G11): nuestra solución es más rica (Volvo
  serviceDistance + horas motor + historial taller + Emmanuel). Migrar = retroceder.
- **DVR cámaras cabina** (G9): Vecchi probable no tiene cámaras. N/A.
- **Enviar Mensaje a teclado cabina** (G8): WhatsApp ya cubre. Bajísimo ROI.
- **H. Temperatura** (G13) + **Validar Carga Combustible** (G14): no aplican al
  negocio Vecchi (transporta arena seca, carga combustible en estaciones).

---

## 📅 2026-05-22 PM (3) — Auditoría general + dedup Emmanuel + F.931 iOS + cachatore

Sesión grande de cierre. 7 commits (`f334604` → `46626c6`), todo en main + pusheado.
CF afectadas **deployadas** (toman efecto ya); cambios de app van en el **release de hoy**.

### Hecho — dedup del parte de mantenimiento a Emmanuel (`f334604`, CF deployada)
- Emmanuel recibía 2 informes con lo MISMO (luces de tablero Volvo). Se **eliminó** el
  "Resumen diario — Alertas de mantenimiento" del bot (`cron_mantenimiento_diario` +
  builder `buildResumenMantenimientoDiario`). El **Parte de mantenimiento** de la CF
  (`resumenMantenimientoVehiculosDiario`) ahora suma lo único exclusivo del otro:
  eventos TPM/TTM/tacógrafo (24 h, con horario). `ALERTAS_RESUMEN_DESTINATARIO_DNI`
  quedó **obsoleta** (sin efecto). Pendiente menor: limpiar la regla `alertasVolvoDiario`
  de `health.js` + el texto de ayuda en `admin_estado_bot_widgets.dart` (tarea spawneada).

### Hecho — cachatore (`1babce3` + `8d9d970`, deploy por auto-update PC dedicada)
- **Búsqueda visible en los logs**: el barrido latente ahora loguea (throttle 30 s) qué
  está buscando y qué ve ("la agenda no tiene huecos…") para que entre latidos no
  parezca colgado.
- **Aviso de cancelación**: al cancelar un turno, manda WhatsApp al **chofer** + al
  **encargado de logística (Errazu, 25022800)**, igual que reservar/reagendar.

### Hecho — auditoría general profunda (agentes por subsistema, hallazgos VERIFICADOS)
1 ALTO + 6 MEDIO, todos arreglados con tests donde aplica:
- **[ALTO]** `report_liquidacion.dart`: `slugSeguro` hacía `substring(0, raw.length)` sobre
  el string ya saneado → **RangeError** y NO salía la liquidación (ej. "Vecchi S.R.L."). `eb3dcb9` +7 tests.
- **[MEDIO]** `jornadas_v2`: `bloque_excedido` no se reseteaba por bloque → aviso de "4h
  continuas" salía 1 vez por jornada. `d1e79ae` (CF deployada) +test.
- **[MEDIO]** RBAC `app_router`: cada ruta admin ahora pide su capability **fina** (antes
  todas pedían `verPanelAdmin` que GOMERIA/SEG_HIGIENE tienen → podían abrir pantallas
  ajenas por deep-link). `eb3dcb9`.
- **[MEDIO]** `mantenimiento.ts`: doble "notificaciones reanudadas" si fallaba el delete →
  flag `reanudacion_encolada`. `d1e79ae` (CF deployada).
- **[MEDIO]** `volvo.ts`: `_esAlertaMantenimiento` leía solo `.type` (vacío en el 100% de
  la data real; el subtipo viene en `triggerType`) → ahora `triggerType ?? type`. `d1e79ae` (CF deployada).
- **[MEDIO]** `cachatore_hub`: `_confirmar` sin try/catch → spinner infinito si fallaba
  Firestore. `eb3dcb9`.
- **[MEDIO]** `admin_shell`: ráfaga de avisos de revisiones viejas al abrir (consumía el
  flag con el snapshot de cache) → ignora `isFromCache`. `eb3dcb9`.

### Hecho — F.931 no se veía en iOS (`9872c41` → `46626c6`)
- Síntoma "cartel azul con código" = banner de pdfrx `FPDF_GetLastError=3`. Verificado:
  data/permisos/URL OK (el 931 es un PDF real de **18 MB**). pdfrx `PdfViewer.uri`
  streamea/cachea y falla con PDFs pesados en iOS. **Fix**: en móvil descargamos el PDF
  completo (dio) y lo renderizamos in-app desde bytes (`PdfViewer.data`) con spinner de %;
  web sigue con `PdfViewer.uri`; "Abrir en el navegador" queda solo de último recurso.
  **Validar en TestFlight** con VOGEL.

### Bundle BAJO HECHO (commit `b747407`, mismo día PM)
Cerrado el bundle de menores. CF `estadoVolvoPoller` deployada con lock-tick.
- HECHO: estadoVolvoPoller lock; commands.js phone strict canónico; historico.js
  -15 helpers obsoletos; checklist `_ItemPregunta` Stateful con controller; cuotas
  docstring honesto; `icm_historico_service.dart` deprecado a stub.
- SKIPPED con justificación (no son bugs reales): SITRACK_EVENTOS limit (ya tiene
  warn + volumen << cap); Python TZ -3 (AR no DST); dedup del bot por texto
  (defensa secundaria, cambiar = behavior change con riesgo).

### Limpieza alertasVolvoDiario HECHA (commit `1c2da83`, mismo día PM)
Removida la regla obsoleta de `health.js` + texto de ayuda + `_etiquetaTipo` del
card "Reglas de notificación" — `ALERTAS_RESUMEN_DESTINATARIO_DNI` ya no aparece
en la app y no engaña a quien intente cambiarla. El card pasa de 4 a 3 reglas.

### ⚠️ Lo único que queda
**(opcional, no es código)** Re-subir el F.931 como PDF más liviano para que abra
al instante en la app (hoy son 18 MB; ya funciona, pero la primera carga toma
varios segundos en datos móviles). Es del lado de Vecchi (admin que sube), no
del lado de la app.

---

## 📅 2026-05-22 PM (2) — Revisión profunda ICM + preparación para PREMIOS/CASTIGOS

Santiago: "revisión profunda del ICM archivo por archivo, card por card... quiero
que quede perfecto porque vamos a empezar con el sistema de premios y
penalizaciones". 2 agentes de auditoría (UI + pipeline) + exploración EN VIVO de
Sitrack y Volvo (sesiones logueadas).

### Hecho — blindaje de correctitud (commit `5651843`, en main, necesita release)
- Universo rankeable = actividad **Y** DNI real (cierra el "fantasma sin chofer"
  en top5/Excel/tablero). Comparativa mes-a-mes ya no confunde 0=sin-infracciones
  con 0=sin-actividad. Conteos del header coherentes con las filas. Excel UNIDADES
  respeta excluirPatente. Formato AR en infracciones. + tests de regresión.

### Hecho — fundación para premios (commits `20ca8a0` + `1931a0e`, necesita release)
- **Tendencia diaria en la card de inicio**: `tendencia_diaria[]` (ICM de flota
  día por día, de `rankingItemsByDay`) en `ICM_OFICIAL/{mes}`. La card ya no
  espera meses; muestra el mes en curso día por día. Backfill 2026-05 cargado.
- **Ranking SEMANAL + mensual**: `sync_icm.py` escribe también
  `ICM_OFICIAL_SEMANAL/{lunes YYYY-MM-DD}` cada corrida; ranking con chips
  Semana/Mes/Mes anterior. Regla deployada. Data real ya en prod (semana
  2026-05-18: ICM 16.66, peor HIDALGO 95.5 ≠ peor mensual LESCANO 61).

### Hecho — snapshot inmutable de cierre (commit `e4f538c`)
- `ICM_OFICIAL_CIERRE/{YYYY-MM}` (mes anterior, congela día ≥4) +
  `ICM_OFICIAL_CIERRE_SEMANAL/{lunes}` (semana lun→dom anterior, congela desde el
  martes). create-once (`congelado:true`, nunca sobreescribe) → la liquidación se
  hará sobre un número que no cambia. Validado: congeló abril (15.67) + semana
  2026-05-11 (20.23); 2da corrida confirmó inmutabilidad. Reglas read deployadas.
- **BUSCIO/no-choferes filtrados** del ranking (commit `b393951`); BASTIAS ya con
  DNI cargado (Santiago). Docs limpios: 0 sin-DNI, 0 no-choferes.

### ⚠️ PENDIENTE
1. **Flujo de premios/castigos** (cuando Santiago lo defina): leer los CIERRE,
   calcular premio/castigo (top 5 mejores/peores semanal+mensual ya disponibles),
   y decidir "cómo avisar". El respaldo de datos ya está listo.
2. **Mapa de calor** (hoy placeholder): Sitrack tiene Control Conducción /
   H. Posición / Monitor Eventos con eventos geolocalizados → construible.
3. **Enriquecer más** (opcional, gratis en la misma respuesta): distancia+tiempo
   urbano vs ruta por chofer, excesos/agresiva por vehículo.
4. **Volvo "Informe de seguridad"**: score de conducta propio de Volvo, candidato
   a métrica SECUNDARIA interna para premios. Extracción aparte (no es el oficial).

---

## 📅 2026-05-22 PM — ICM OFICIAL de Sitrack ingerido + automatización dedicada

Santiago: "esa página de Sitrack es de donde saca YPF el ICM, ¿no podemos
replicar esa info?". **Sí, y resuelve de raíz el "framing" del ítem de abajo:**
Sitrack (proveedor satelital) YA calcula el ICM con la cartografía de segmento
vial que nosotros NO tenemos → ingerimos SU número en vez de estimar.

### Hecho + validado
- **`sitrack_sync/`** (Playwright): login portal site5 (usuario **SantiagoRRey**,
  reCAPTCHA pasivo) → endpoint `get_ranking_data` (JSON por chofer, match por
  **DNI**) → `ICM_OFICIAL/{YYYY-MM}`. Escala INVERTIDA (más bajo = mejor; flota
  ~20, peor LESCANO 64.5). Parser puro + 6 tests. Regla read deployada.
- **Automatización dedicada**: 2 Scheduled Tasks (Volvo taller 05:10, Sitrack
  ICM 06:10) validadas end-to-end por la tarea (`LastTaskResult 0`), reinicio-OK.
  Detalle + lecciones (prioridad 7→5, pipe→archivo, Volvo por **fetch directo**
  porque la SPA no renderiza bajo la tarea) en `project_bot_pc_dedicada.md`.
- **Bot**: `BOT_PC_ID` de la dedicada corregido a `dedicada` (era `oficina`);
  log nombra admins/destinatarios de resúmenes (no solo choferes). Tests 129/129.

### Fase B — rework del módulo a la escala oficial ✅ HECHO
- Módulo ICM (ranking / reporte mensual / detalle), card de inicio del tablero
  ejecutivo y Excel de auditoría ahora leen `ICM_OFICIAL` (más bajo = mejor,
  severidad de Sitrack NO/LOW/MEDIUM/HIGH). Service nuevo
  `icm_oficial_service.dart` (modelos + helper de color + derivaciones) con 12
  tests puros. `flutter analyze` limpio + 405 tests verdes. Commits `2ddc903`
  (módulo + card) y `56ea03c` (Excel). Validado contra la data real de 2026-05.
- El CESVI propio (cliente `icm_calculator`/`icm_historico_service` + server
  `recomputeIcmSemanalScheduled` → `ICM_SEMANAL`) queda VIVO pero
  **desconectado de la UI**. Esto vuelve MOOT el ítem "framing" de abajo.

### ⚠️ PENDIENTE
- **Release de la app** (lo larga Santiago): sin release los usuarios siguen
  viendo el módulo viejo (CESVI ~94). El número oficial ya está en Firestore;
  la card de inicio se actualizará al reabrirse SOLO tras el release (cambió el
  código que la arma, no solo el dato).
- **Decisión futura (no urgente)**: si nadie consume `ICM_SEMANAL` ni el CESVI
  semanal, retirar el cron `recomputeIcmSemanalScheduled` + el path cliente
  CESVI. Hoy quedan como oráculo de los tests de paridad — no tocar sin decidir.

---

## 📅 2026-05-22 — Rediseño del ICM (#49): "todo marca ~100"

Santiago: "estamos haciendo mal los cálculos, los rankings no me parecen
acordes, las cards marcan todo 100". Diagnóstico contra datos reales lo
explicó: el ICM se calculaba sobre las **JORNADAS del vigilador** (rotas:
ventanas 10-22h con 1.3h de manejo) → el **41% de las infracciones caía
fuera de toda ventana**; y el km salía del odómetro **por evento** (los
eventos bruscos no traen odómetro) → el filtro km>=10 descartaba casi
todo → ICM_SEMANAL/W20 = **99.59 todo verde**.

### Hecho + deployado + validado en vivo
- Unidad: **(chofer, día ART)** en vez de jornada (no pierde eventos).
- **km POR PATENTE** (odómetro de eventos de movimiento 98%) prorrateado
  al chofer. Sin fatiga (no hay señal real). Umbrales **YPF 91/71** (era
  80/60) en los 4 lugares. `combinarJornadas` peso=max(km,1). Flota =
  media simple. Detalle en memoria `project_modulo_icm.md`.
- Server deployado + **W20 recomputado**: pasó de **99.59 → 93.92**, con
  28 verdes / **13 amarillos** / 0 rojos sobre 41 choferes (antes todo
  verde). Tests flutter 74/74 + functions 188/188. Commit `8eb6502`.
- La card de inicio lee el doc del server → ya muestra el número nuevo
  **sin release** (se actualiza al reabrir la pantalla).

### ⚠️ SUPERSEDED por la Fase B (ICM oficial, arriba)
El rediseño CESVI se hizo y deployó, pero la **Fase B lo reemplazó en la UI**:
en vez de estimar internamente (no teníamos segmento vial), ahora ingerimos el
ICM oficial de Sitrack y lo mostramos tal cual (es el que audita YPF). El CESVI
queda vivo en el server pero desconectado de pantallas. Único pendiente real:
el **release** (ver arriba).

---

## 📅 2026-05-21 EOD — Arco Volvo: jornada + mantenimiento de punta a punta

Sesión gigante. Plan "todo desde Volvo, ICM queda en Sitrack". Ver memoria
`project_volvo_estado_fundacion.md` (detalle completo) y `project_modulo_icm.md`.

### Hecho y deployado (Cloud Functions — auto-deploy ON, ya están en vivo)
- **Fundación `estadoVolvoPoller`** verificada con los 53 camiones reales. Fix
  `limpiarNulos` (no borrar tell-tales por contenido) + `conductor_estado` + 2ª
  consulta UPTIME para testigos (commits `0350b0c` `6396c90` `72008f6`).
- **Jornada #36 → Volvo** (`d015e80`): el bug de paradas no detectadas era medir
  staleness sobre `consultado_en` (siempre fresco). Ahora `decidirManejando` gana
  la fuente MÁS FRESCA (Volvo `posicion_ts` real + speed; fallback SITRACK
  `report_date`). Verificado en vivo. Suite functions 186/186.
- **Parte de mantenimiento a Emmanuel #43** (`130453d` `8826257`): cron
  `resumenMantenimientoVehiculosDiario` 08:00 ART → WhatsApp con advertencias
  exactas (tell-tales en español) + declara cobertura honesta (hoy 20/53).

### Hecho — Mantenimiento por km #44 + #45 (componente NUEVO `volvo_sync/`)
- Scraper Playwright de Volvo Connect (login `logistica@cooper-trans.com.ar`,
  HTML estándar SIN MFA/CAPTCHA, sesión reusable). Trae historial de taller
  (`ecs-workshophistory` GraphQL) → `ULTIMO_SERVICE_KM/FECHA` + historial completo
  a `VEHICULOS_TALLER`. Parser PURO (último service por functionGroup, NO
  visitReason ni última visita). Reglas deployadas. Commits `a4b3945` `208e563`
  `cfdcd19`. **Flota sincronizada 1 vez (53 unidades).**
- App: campo de service **read-only** ("automático desde Volvo", `fb0f1f3`) +
  **pantalla de Mantenimiento unificada** (`9505e27`): lista → detalle por unidad
  con Service + Advertencias + Telemetría + Historial de taller completo.

### ⚠️ PENDIENTE para que quede 100% automático y visible
1. **Deploy `volvo_sync` en la PC dedicada** (cierra #44/#45 al 100% auto):
   `pip install playwright` + `playwright install chromium` + copiar
   `volvo_sync/claves.json` (creds, gitignoreado) + tarea programada DIARIA
   `python sync_taller.py --commit`. Hoy corrió 1 vez a mano desde la PC oficina.
2. **Release de la app** (Windows/Android/iOS) — propaga: jornada (transparente),
   campo service read-only, pantalla Mantenimiento unificada.
3. **Avisarle a Emmanuel** que desde mañana 8 AM le llega un WhatsApp diario con
   las advertencias de los camiones (que no le caiga de sorpresa).

### Hallazgos que cierran ideas
- **Testigos del tablero = límite de GENERACIÓN del camión**, NO de la API ni de
  acceso: los ~33 camiones viejos (2017-18) no transmiten "Estado actual" a NINGÚN
  lado (confirmado en la web). #43 techo real ~20/53. NO es activable.
- **Peso por eje (#46): 0/53 — descartado.** La flota no lo transmite.

---

## 📅 2026-05-20 EOD — Web institucional VAVG + acceso web a la app (proyecto nuevo)

Remodelación completa de la web pública del cliente + se le agregó el acceso web a la
app. **EN VIVO.** Proyecto separado en `C:\Users\Colo Logistica\web_coopertrans\` (NO
versionado en git). Detalle en `ESTADO_PROYECTO.md` §16 y memoria
`project_web_institucional.md`.

### Hecho (en vivo)
- Sitio nuevo marca **VAVG** en `https://cooper-trans.com.ar` (reemplazó al Flash/PHP viejo).
- App web en `https://cooper-trans.com.ar/sistema/` — mismo DNI + contraseña.
- Sitio viejo respaldado (`cooper-trans_sitio_viejo_backup_2026-05-19.zip`) y limpiado del server.
- `release_completo.ps1` ahora también compila + sube `/sistema` (best-effort, flag `-SkipWeb`).

### Deploys / push pendientes (Santiago, desde su PC)
- Push de los 2 commits del repo: `0d940c1` (branding `web/index.html`) + `d1a3af3`
  (integración web en release). Salen solos en el próximo `release_completo` (paso git
  push), o `git push` a mano cuando quieras.
- (Sigue pendiente lo del 19-may: `firebase deploy --only functions` + verificar
  rules/indexes del 18-may.)

### Pendiente / ideas
- **Versionar `web_coopertrans` en git local** (anti-pérdida; hoy el proyecto web NO está
  en ningún repo → bus-factor).
- Para actualizar la web/app desde la OTRA PC: copiar `web_coopertrans` + `ftp_datos.txt` allá.
- Fotos de flota del hero son media-res (recortes del brochure ~700px). Si hay fotos
  propias en alta, mejoran.

---

## 📅 2026-05-19 EOD — Cierre del día (vigilador fix + split functions completo + tests CF)

Sesión larga: fix de un bug real reportado por Santiago + completar el
split de `functions/index.ts` + sacar de "deferred" los tests de flujo
de las Cloud Functions.

### 🐛 Bug REAL del día: aviso falso de "12h jornada" (Oscar + César)

Dos choferes recibieron "Llegás al límite de 12 horas de jornada" sin
avisos progresivos previos y sin estar silenciados. **Causa raíz**: el
disparador era `bloques_completos >= 3`, pero un "bloque" se cuenta con
cualquier manejo + pausa de 15+ min. Un chofer con pausas frecuentes y
cortas llega a 3 bloques con poco manejo real. Verificado con datos
reales (`scripts/diagnosticar_jornada_chofer.js`): César tenía 3 bloques
con **7h54 manejo neto** → aviso falso. **Fix**: avisos por MANEJO NETO
acumulado (heads-up 11h, límite firme 12h). Clarificación Santiago: el
límite son 12h de manejo neto (las paradas de 15 min suceden DENTRO).

### Commits del día (9)

**Vigilador jornada (3)**:
- `1c9e0af` — cuota por manejo neto (CF jornadas_v2)
- `97e9acb` — `/jornada` del bot usa manejo neto + heads-up 11h + script diagnóstico
- `bf18767` — corrección límite: 12h (no 11h)

**Bot WhatsApp (2)**:
- `25c49cb` — comando admin `/enviar-jornada <DNI>` (manda al chofer su estado de jornada) + fix time-sensitive `jornada_v2_cuota_proxima`
- `cd3e658` — fix mock Firestore de agrupador.test.js (faltaba orderBy/limit) → bot 129/129

**Descargas PTO (1)**:
- `b647fc5` — dedup por (patente, ventana 15 min) en pantalla descargas

**Split functions/index.ts COMPLETADO (5)** — `6884 → 45 LOC (-99%)`:
- `383939c` auth.ts · `8dffd96` audit.ts · `6076075` comun.ts ·
  `e80bfae` volvo.ts · `442450c` telemetria.ts + index entry point puro

**Tests de flujo CF (2)** — sacado de "deferred":
- `acb6c5a` — `evaluarTickJornada` (máquina de estados pura) + 21 tests
- `b61375e` — 5 builders de resúmenes (puros) + 23 tests

### Estado de las suites

```
flutter test:        310/310 ✓  (sin cambios hoy)
functions npm test:  148/148 ✓  (de 104 → +44 tests del vigilador y resúmenes)
whatsapp-bot test:   129/129 ✓  (de 120 → +8 /enviar-jornada, +1 fix mock)
```

### Deploys pendientes (para Santiago, desde su PC)

1. `git push` — (probablemente ya pusheado sobre la marcha)
2. `firebase deploy --only functions` — propaga: **fix vigilador manejo
   neto** (jornadas_v2) + **split completo** (redeploy de las 31
   functions, cero cambio de comportamiento) + builders de resúmenes.
   Tarda unos minutos por el volumen.
3. **Bot**: el push dispara el auto-update de la PC dedicada en ≤5 min
   (toma `/enviar-jornada` + fixes). No requiere tocar la PC.
4. **Verificar del 18/5 si no se corrió**: `firebase deploy --only
   firestore:rules` (guard BORRADORES_VIAJE) + `firebase deploy --only
   firestore:indexes` (index JORNADAS DESC) — comandos separados.

### Validación natural mañana 8 AM ART

Que el resumen de jornadas a Molina (`resumenExcesosJornadaDiario`)
refleje bien los excesos con la lógica nueva de manejo neto.

---

## 📅 2026-05-18 EOD — Cierre del día (auditoría completa + tests + splits + bug horaArt)

**Sesión gigante** de auditoría profunda del proyecto con 6 agentes
paralelos + ~20 commits de fixes, refactors estructurales y tests.

### Lo más importante: 🐛 1 bug REAL descubierto por test

`functions/src/jornadas_v2.ts:horaArt()` devolvía **24** (no 0) para
medianoche ART en Node V8. La lógica de veda nocturna chequeaba
`horaActual < 6` → con 24, falso → **el chofer que arrancaba 00:00-00:59
ART NO recibía aviso de veda nocturna**. Ventana ciega de 1h/día por
al menos 3 refactors. Fix de 1 línea (`return h === 24 ? 0 : h`).
Commit `a4ab509`.

### Commits del día (16+)

**Sentry (4)**:
- `38315b1` — Panel: eficiencia combustible en L/100km (métrica AR)
- `ed24c66` — Filtros + rate limiter anti-storm en `beforeSend`
- `0bd873c` — SentryNavigatorObserver (breadcrumbs de ruta)
- `201c300` — Release name unificado Windows/Android/iOS

**Auditoría — fixes (8)**:
- `f68ecdb` — Regresión CHECKLISTS (chofer no veía si rotación de patente) + DNI maskeado en 4 logs
- `e499da2` — Bot: `/pausar` serverTimestamp + delay anti-baneo chunks 5-15s + rate limit pattern + cache silenciados
- `12fb37a` — Cloud Functions: limits defensivos + warn al alcanzar (resumen conducta, ICM semanal, EMPLEADOS)
- `0855510` — Rules: BORRADORES_VIAJE guard de owner + Index JORNADAS DESC + TTL COLA_WHATSAPP
- `7730393` — `npm audit fix` resuelve CVE HIGH (fast-xml-builder) + MODERATE (ws)
- `04716d7` — Cleanup: 4 scripts deprecated → `_deprecated/` + borrar logs viejos
- `0abbeca` — Docs: README 16 crons (vs 9 documentados) + MANUAL 6 roles (vs 4) + comment ICM outdated
- `4361c31` — CI: pin Flutter 3.41.7 en `ci.yml` + `ci_post_clone.sh` + `.flutter-version`

**Refactors estructurales (5)**:
- `95f6c27` — Split `logistica_viaje_form_screen.dart` 2823 → 5 archivos (patrón `part of`)
- `90edd44` — Extract helpers compartidos functions a `helpers.ts` (drift fix: jornadas_v2 capitaliza nombres + round-robin)
- `a6a90f5` — Split `functions/index.ts` iter 1-3: cleanup + dashboard + icm + mantenimiento
- `75f61f1` — Split iter 4: sitrack.ts
- `38f4acf` — Split iter 5: resumenes_diarios.ts (50% completado en total)

**Bot fix (1)**:
- `52c36a9` — TTL 36h en los 3 resúmenes diarios del bot (cierra gap residual del fix Fase 2)

**Tests (2)**:
- `a4ab509` — 16 tests TS (jornadas v2 helpers) + 20 tests Dart (ICM helpers) + **bug horaArt 24→0**
- `fd28d17` — 15 tests Dart ICM flujo completo con `fake_cloud_firestore`

### Estado de la suite post-sesión

```
flutter test:        310/310 ✓  (de 275 anteriores +35 nuevos)
functions npm test:   62/62 ✓  (de 46 anteriores +16 nuevos)
```

### Deploys pendientes (para Santiago)

1. `git push` — ~20 commits acumulados desde tu PC
2. `firebase deploy --only firestore:rules` — para que entre el guard BORRADORES_VIAJE
3. `firebase deploy --only firestore:indexes` — para crear el index JORNADAS DESC (comando separado por bug conocido del CLI)
4. `firebase deploy --only functions` — propaga: **fix bug horaArt** (veda nocturna 00:00) + limits defensivos + helpers extraidos + módulos splitteados
5. **Próximo build app** (Windows/Android/iOS) — propaga fixes Sentry + DNI mask + km/L → L/100km + regresión CHECKLISTS
6. **PC dedicada** toma fix bot automático en ≤5 min vía Scheduled Task auto-update (TTL 36h resúmenes + serverTimestamp pausar + rate limit cache)

### Pendiente para próximas sesiones

**Completar split de `functions/index.ts`** (50% restante, ver memoria `project_split_functions_index.md`):
- `auth.ts` (~1700 LOC, 5 functions: login + cambiar/resetear pwd + actualizar rol + rename DNI)
- `volvo_alertas.ts` (~1900 LOC) + `volvo_scores.ts` (~400 LOC)
- `telemetria.ts` (~350 LOC, depende de helpers Volvo, hacer DESPUÉS de volvo)

**Tests de flujos completos CF** (deferred honestamente — sesión propia):
- `tickVigiladorJornada` + resúmenes diarios CF
- Requieren `firebase-functions-test` SDK + mock manual de Firestore (Timestamp/FieldValue sentinels + estado mutable)
- Plan: arrancar por `resumenBotDiario` (el más simple) como proof of concept del setup
- Tiempo estimado: 3-4h SOLO para tener mock + 1 test funcionando, después escalar

**Items del audit deferred por decisión consciente**:
- Race ready/destroy bot whatsapp.js (complejo, baja probabilidad)
- Match sufijo 10 dígitos `/jornada` (decisión de negocio: aceptar riesgo bajo)
- DNIs hardcoded → META/destinatarios_alertas (esperar cambio real de persona)
- Code-signing Windows installer ($80/año, decisión gasto)
- Major bumps Flutter (sentry 8→9, win32 5→6, fl_chart 0→1 — riesgo breaking)

Ver memoria `project_tests_logica_negocio.md` y `feedback_sentry_observabilidad.md` para detalle.

---

## 📅 2026-05-16 EOD — Cierre del día (iOS TestFlight operativo)

**Logro del día**: 🎉 **App instalable en iPhone via TestFlight**.
Build #11 Xcode Cloud con log 100% limpio (3 exports OK, 0 errores).
TestFlight Internal Testing andando — Santiago ya tiene la app
instalada en su iPhone.

### Commits del día (4)
- `5f97188` — `CFBundleIconName=AppIcon` en Info.plist (faltaba ícono
  en TestFlight, requisito iOS 13+).
- `14eb01a` — `ENABLE_APP_INTENTS_INTEGRATION=NO` en Podfile post_install
  (apaga 19 warnings cosméticos por pod).
- `cd585f0` — `install_profile_optional` en `ci_post_clone.sh` para
  silenciar errores ruidosos del log (~200 errores de "No profiles
  for..." en exports Ad Hoc + Development).
- `a7acc95` — `NSLocationAlwaysAndWhenInUseUsageDescription` en
  Info.plist (warning ITMS-90683 del email Apple post-upload).

### Lo que se hizo en App Store Connect / portal Apple
- 2 profiles nuevos creados en developer.apple.com:
  - `Coopertrans Movil Ad Hoc` (NLN3W2KT9J-style)
  - `Coopertrans Movil Development`
  - Ambos con dummy UDID `00008101-001A2B3C4D5E6F70` (Apple no valida
    que el UDID sea real, solo formato).
- 2 secrets nuevos subidos al workflow Xcode Cloud:
  - `IOS_ADHOC_PROFILE_BASE64`
  - `IOS_DEV_PROFILE_BASE64`
- Workflow ahora tiene **5 secrets** total (cert + password + 3 profiles).
- Build #11 disparado → todo OK.
- Grupo "Vecchi Choferes" creado en TestFlight Pruebas Externas (vacío
  todavía).

### Pendiente de push (sin pushear todavía)
```powershell
git push  # commit a7acc95 (Info.plist con NSLocationAlways...)
```
Sin esto, el próximo Build #12 vuelve a tirar el warning ITMS-90683
(no bloquea, pero queda ruidoso).

### Pendiente para próxima sesión — completar External Testing
El Build #11 está OK en TestFlight Internal pero falta para External:

1. **App Store Connect → Distribución → Información de la app**:
   - Categoría principal: `Productividad` (o `Negocios`)
   - Clasificación por edades: completar cuestionario respondiendo
     "No"/"Ninguno" a todo → resultado `4+`.
   - NO hace falta cargar Encryption Documentation (exenta por usar
     solo cifrado estándar del OS — `ITSAppUsesNonExemptEncryption=false`).

2. **TestFlight → "Información para las pruebas"** (sidebar Adicional):
   - Email comentarios: `santiagocoopertrans@gmail.com`
   - Información de contacto: nombre + email + tel
   - Descripción Beta (~200 chars sobre qué hace la app)
   - Política de privacidad: URL de Firebase Hosting (la misma que
     Play Store)
   - Qué probar: "Login con DNI + clave. Probar navegación general"
   - Cuenta de prueba: DNI + clave de un admin/test

3. **TestFlight → "Vecchi Choferes"** → tab Compilaciones → "+" →
   agregar Build 11 → **Submit for Beta App Review** (1-2 días, primer
   build external).

4. Después de Beta Review aprobado:
   - Cargar choferes vía CSV (sin header: `email,first_name,last_name`)
     o vía Public Link (`testflight.apple.com/join/XXXXXX`).
   - Solo Apple IDs válidos (típicamente Gmail).

### Helpers iOS para futuro
- `G:\Mi unidad\ClaudeCodeSync\secrets-ios\convertir_profiles_extra.ps1` —
  convierte .mobileprovision a base64 limpio para subir como secret.
- `G:\Mi unidad\ClaudeCodeSync\secrets-ios\README.md` — manual completo
  con instrucciones de regeneración cert + 3 profiles.

---

## 📅 2026-05-15 EOD — Cierre del día (lo que quedó deployable)

Sesión gigante: 17 commits + bump 1.0.55+58 → 1.0.56+59. Lo que sigue
es el orden recomendado para mañana sábado / lunes:

### Deploys pendientes
```powershell
# Trae lo del día (release_completo.ps1 ya pusheó hasta 974dbaf):
git push                              # por si quedó algo

# Backend:
firebase deploy --only firestore:rules,firestore:indexes
firebase deploy --only functions

# Una vez deployado el vigilador v2, limpiar la legacy:
node scripts/limpiar_jornadas_chofer_legacy.js --dry-run
node scripts/limpiar_jornadas_chofer_legacy.js --apply
```

### Releases ya hechos hoy
- ✅ 1.0.55+58 (release_completo.ps1) — adelantos para todo personal +
  primera versión del cron `resumenConductaManejoDiario`.
- ✅ 1.0.56+59 (974dbaf) — módulo ICM completo (hub + ranking + reporte
  semanal + detalle por chofer + mapa de calor placeholder) + reporte
  Excel ICM en menú Reportes + sobrevelocidades por chofer en resumen
  Molina + capability `verIcm` (admin/supervisor/seg_higiene).

### Cosas a validar mañana 8 AM ART (cuando llegue el resumen Molina)
- Mensaje del cron `resumenConductaManejoDiario` con el formato nuevo
  unificado (Sitrack + Volvo AEBS/ESP, sin jerga técnica) + línea
  "Peor exceso: X km/h (límite Y, +Z)" cuando hubo sobrevelocidad
  (event_id 8/9).
- Mensaje del cron `resumenExcesosJornadaDiario` (vigilador v2 con
  modelo bloques 3×4h).

---

## 📅 2026-05-16 (sáb) — ya cumplido / re-evaluar consumer Sitrack

El re-análisis de la ventana 60h se corrió 2026-05-15 (`scripts/analizar_sitrack_eventos.js --horas 60`):
- 7437 eventos / 124 evt/h.
- Conducción peligrosa = 573 eventos (7.7%): 407 salida de carril, 92
  sobrevelocidad, 37 giro brusco, 23 frenada brusca, 10 distancia
  frenado insuficiente, 1 aceleración brusca, 2 colisión.
- 87.9% chofer identificado, 52.3% con cartografía.

**Decisión tomada 2026-05-15**: NO armar consumer Sitrack adicional —
los 10 tipos peligrosos ya entran al `resumenConductaManejoDiario` y
al módulo ICM. Está cubierto end-to-end.

---

## 🟡 Pendientes operativos (sin fecha fija)

> Limpieza 2026-05-28: se quitaron los ya cerrados (multi-tramo features, bot PC
> dedicada, acceso remoto, iOS listing) — detalle en la entrada del 28-may arriba.
> Queda lo realmente abierto:

### Volvo Driver/Tachograph Files API
Módulos activos pero feeds vacíos. Pedir a Volvo Argentina alta de 48
choferes + activación transmisión por unidad.

### ICM — iconos custom (cosmético menor)
✅ El CESVI propio fue **RETIRADO** 2026-05-28: `icm_calculator` + `icm_cesvi` +
`icm_historico_service` + cron `recomputeIcmSemanalScheduled` + colección
`ICM_SEMANAL` + sus tests. La UI usa solo el ICM oficial de Sitrack. Queda como
pendiente cosmético: iconos custom para ICM verde/amarillo/rojo (hoy
`Icons.leaderboard` + color de fondo). ✅ PROD cerrado 2026-05-28: function
`recomputeIcmSemanalScheduled` eliminada + `firestore:rules` deployadas +
colección `ICM_SEMANAL` borrada (firestore:delete).

### Sitrack P4 — ranking + outliers de descarga
El tiempo promedio de descarga ya lo muestra la pantalla Descargas. Falta el
ranking por chofer + alerta de outliers (el que tardó >> que el promedio).
Esperar ~1 mes de data para que el promedio sea representativo.
