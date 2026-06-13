/**
 * Cloud Functions de Coopertrans Móvil — ENTRY POINT.
 *
 * Tras el split (2026-05-18 → 2026-05-19), este archivo es SOLO el punto
 * de entrada que Firebase carga (`lib/index.js` compilado). Re-exporta
 * cada módulo temático con `export *` para que Firebase vea todos los
 * endpoints. La lógica vive en los archivos hermanos — ninguna cloud
 * function se define acá.
 *
 * `import "./setup"` va PRIMERO: dispara initializeApp + setGlobalOptions
 * antes de que cualquier módulo acceda a Firestore.
 *
 * Historia: index.ts llegó a tener 6884 LOC con 31 cloud functions. El
 * split lo redujo a este entry point + 11 módulos. Ver memoria
 * `project_split_functions_index.md`.
 */

import "./setup";

// Módulos del split (cada uno re-exporta sus cloud functions + helpers):
//   - comun.ts             helpers compartidos (asignaciones + locks + fetch + tipos)
//   - auth.ts              login + passwords + roles + rename DNI
//   - audit.ts             auditLogWrite
//   - volvo.ts             5 functions Volvo (proxy + alertas + scores + triggers)
//   - telemetria.ts        telemetriaSnapshotScheduled
//   - cleanup_y_recibos.ts asignarNumeroReciboAdelanto + purgarColaWhatsappAntigua
//   - dashboard_stats.ts   recomputeDashboardStats
//   - mantenimiento.ts     backup + bot_health + vigilador jornadas + silenciados
//   - sitrack.ts           sitrackPosicionPoller + sitrackEventosPoller
//   - resumenes_diarios.ts 4 resúmenes diarios 08:00 ART
//
// Orden: comun + auth primero porque exportan helpers que sitrack/
// mantenimiento/resumenes importan vía "./index" (re-export).
export * from "./comun";
export * from "./auth";
export * from "./audit";
export * from "./volvo";
export * from "./volvo_estado";
export * from "./volvo_telltales";
export * from "./volvo_mantenimiento";
export * from "./telemetria";
export * from "./cleanup_y_recibos";
export * from "./dashboard_stats";
export * from "./mantenimiento";
export * from "./sitrack";
export * from "./zonas_descarga";
export * from "./historico_descargas";
export * from "./historico_ibuttons";
export * from "./jornada_historico";
export * from "./resumenes_diarios";
// Vigilador de jornada v3 — registro a posteriori (Paso 2). Cron DARK por flag
// (META/config_vigilador_v3.registro_batch_activo, default false) + backfill
// ADMIN. No toca el v2 (JORNADAS) ni el histórico. Ver jornadas_v3_batch.ts.
export * from "./jornadas_v3_batch";
// Cruce diario PARADAS_REPORTADAS (lo que el chofer avisó por WhatsApp) vs las
// pausas que v3 detectó. Si v3 confirma → marca la parada confirmada_v3. Si no
// → escala a REPORTES_DISCREPANCIA para que la oficina revise. Corre 07:00 ART.
export * from "./paradas_reportadas";
// Devolución por WhatsApp al chofer cuando su reclamo (REPORTES_DISCREPANCIA) se
// marca revisado con veredicto: cita el reclamo + el resultado. Trigger onUpdate,
// idempotente. Solo reclamos directos (no los auto-generados de paradas).
export * from "./reportes_discrepancia";
// Cierre automático de reclamos de jornada (cron 08:00 ART): cruza los pendientes
// contra v3 + GPS crudo y setea el veredicto (que dispara la devolución). A los
// que el GPS desmiente les contesta con la evidencia. Flag
// META/config_cierre_reportes.activo (default dry-run). Ver cierre_reportes_jornada.ts.
export * from "./cierre_reportes_jornada";
// Cron de los crons (cada 3 h): compara el latido de CRON_HEALTH de los 24
// onSchedule contra su cadencia esperada y avisa por Telegram + WhatsApp si
// alguno está muerto o viene fallando. Ver cron_health.ts.
export * from "./cron_health";
// Censo mensual de colecciones (día 1, 03:30 ART): count() de toda la base →
// STATS/censo_{mes} + diff vs mes anterior → WhatsApp (crecimientos >40% y
// colecciones nuevas resaltados). Ver censo_colecciones.ts.
export * from "./censo_colecciones";
// Push FCM (Vertical 2 deep-links+push): cola COLA_PUSH multi-productor →
// trigger procesarColaPush resuelve tokens (EMPLEADOS/{dni}/dispositivos) y
// envía, podando los muertos. Ver push.ts.
export * from "./push";
