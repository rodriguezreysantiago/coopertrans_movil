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
//   - icm.ts               recomputeIcmSemanalScheduled
//   - mantenimiento.ts     backup + bot_health + vigilador jornadas + silenciados
//   - sitrack.ts           sitrackPosicionPoller + sitrackEventosPoller
//   - resumenes_diarios.ts 4 resúmenes diarios 08:00 ART
//
// Orden: comun + auth primero porque exportan helpers que icm/sitrack/
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
export * from "./icm";
export * from "./mantenimiento";
export * from "./sitrack";
export * from "./zonas_descarga";
export * from "./resumenes_diarios";
