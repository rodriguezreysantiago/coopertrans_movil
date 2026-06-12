// =============================================================================
// DASHBOARD STATS — agregaciones server-side para admin_panel
// =============================================================================
// Extraído de index.ts el 2026-05-18 (split del archivo de 6884 LOC).
//
// Antes admin_panel hacía 3 StreamBuilders (EMPLEADOS, VEHICULOS, REVISIONES)
// y calculaba KPIs O(N×M) client-side en cada snapshot push. Funcionaba con
// flotas chicas (~177 docs) pero la deuda escalaba: cada cambio en cualquier
// doc gatillaba recalc completo en cada cliente admin abierto.
//
// Ahora: una scheduled function recalcula y persiste el agregado en
// `STATS/dashboard`. La app lee 1 doc en lugar de N+M+R. Stale máx ~5 min,
// totalmente aceptable para un dashboard administrativo.
//
// Schema del doc `STATS/dashboard` (ver `lib/features/admin_dashboard/...`):
//   {
//     v: 1,
//     choferes_activos, unidades_total, unidades_asignadas,
//     revisiones_pendientes, vencidos, proximos_7, proximos_30,
//     actualizado_en: Timestamp,
//     duracion_ms, docs_leidos
//   }
//
// Helpers replicados de Dart cliente (ver
// `lib/core/constants/{app_constants,vencimientos_config}.dart` +
// `lib/shared/utils/formatters.dart`). Si cambia la lógica de un lado,
// CAMBIAR EL OTRO. Tests E2E manualmente: cargar empleado nuevo, esperar
// ≤5 min, verificar que choferes_activos sube en el dashboard.

import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";

import { db } from "./setup";
import { onScheduleConLatido } from "./comun";
import { cargarExcluidos } from "./excluidos";

const DASHBOARD_STATS_SCHEMA_VERSION = 1;

// Roles cuyos miembros tienen vehículo asignable y por ende cuentan
// como "choferes activos". Espejo de `AppRoles.tieneVehiculo` en Dart.
const ROLES_CON_VEHICULO = new Set<string>(["CHOFER", "USUARIO"]);

// Estados que indican que un vehículo está asignado a un chofer.
// Espejo de la lógica en `_Stats.from()` cliente.
const ESTADOS_VEHICULO_OCUPADO = new Set<string>(["OCUPADO", "ASIGNADO"]);

// Sufijos de `VENCIMIENTO_*` para EMPLEADOS. Espejo de
// `AppDocsEmpleado.etiquetas` en Dart. Los 4 docs laborales (ART, F.931,
// SCVO, sindical) NO van acá — son por empresa, no por empleado.
const VENCIMIENTOS_EMPLEADO_SUFIJOS = [
  "LICENCIA_DE_CONDUCIR",
  "PREOCUPACIONAL",
  "CURSO_DE_MANEJO_DEFENSIVO",
];

// Sufijos `VENCIMIENTO_*` para TRACTOR/CHASIS. Espejo de
// `AppVencimientos.tractor` en Dart.
const VENCIMIENTOS_TRACTOR_SUFIJOS = [
  "RTO",
  "SEGURO",
  "EXTINTOR_CABINA",
  "EXTINTOR_EXTERIOR",
];

// Sufijos `VENCIMIENTO_*` para ENGANCHE (resto de tipos). Espejo de
// `AppVencimientos.enganche`.
const VENCIMIENTOS_ENGANCHE_SUFIJOS = ["RTO", "SEGURO"];

/**
 * `true` si el doc NO está dado de baja. Espejo de `AppActivo.esActivo`:
 *   - ACTIVO=true → true (alta explícita).
 *   - ACTIVO=null/ausente → true (default; doc viejo pre-soft-delete).
 *   - ACTIVO=false → false (baja).
 */
function _statsEsActivo(data: Record<string, unknown>): boolean {
  return data.ACTIVO !== false;
}

/**
 * Normaliza un rol al canónico (USUARIO legacy → CHOFER). Espejo de
 * `AppRoles.normalizar`.
 */
function _statsNormalizarRol(rol: unknown): string {
  const r = String(rol ?? "").toUpperCase();
  if (r === "USUARIO") return "CHOFER";
  return r;
}

/**
 * Calcula días restantes hasta una fecha. Acepta Timestamp, Date, ISO
 * string (YYYY-MM-DD), AR string (DD/MM/YYYY o DD-MM-YYYY). Devuelve
 * `null` si no se puede parsear (consistente con
 * `AppFormatters.calcularDiasRestantes` cliente — el caller cuenta esos
 * como "vencidos" en el peor caso).
 */
function _statsCalcularDiasRestantes(fecha: unknown): number | null {
  if (fecha === null || fecha === undefined || fecha === "") return null;
  let d: Date | null = null;
  if (fecha instanceof Date) {
    d = fecha;
  } else if (
    typeof (fecha as { toDate?: () => Date }).toDate === "function"
  ) {
    // Firestore Timestamp.
    d = (fecha as { toDate: () => Date }).toDate();
  } else {
    const s = String(fecha).trim();
    if (s === "" || s === "---" || s.toLowerCase() === "nan") return null;
    // Limpiar parte de hora si vino "YYYY-MM-DD HH:MM:SS"
    const soloFecha = s.split("T")[0].split(" ")[0];
    const f = soloFecha.replace(/\//g, "-");
    const partes = f.split("-");
    if (partes.length !== 3) return null;
    let yyyy: number;
    let mm: number;
    let dd: number;
    if (partes[0].length === 4) {
      // ISO YYYY-MM-DD.
      yyyy = parseInt(partes[0], 10);
      mm = parseInt(partes[1], 10);
      dd = parseInt(partes[2], 10);
    } else {
      // AR DD-MM-YYYY.
      dd = parseInt(partes[0], 10);
      mm = parseInt(partes[1], 10);
      yyyy = parseInt(partes[2], 10);
    }
    if (
      Number.isNaN(yyyy) || Number.isNaN(mm) || Number.isNaN(dd) ||
      mm < 1 || mm > 12 || dd < 1 || dd > 31
    ) {
      return null;
    }
    d = new Date(yyyy, mm - 1, dd);
  }
  if (!d || Number.isNaN(d.getTime())) return null;
  // Normalizar a midnight (mismo cálculo que cliente).
  // Auditoria 2026-05-18: TZ-aware. Cloud Functions corre en UTC, asi
  // que `new Date()` da hora UTC y `getDate()` UTC. Entre 21:00-23:59
  // ART (00:00-02:59 UTC del dia siguiente) decia "1 dia menos" → los
  // KPIs del dashboard adelantaban 3h los vencimientos. Calculamos
  // "hoy" en TZ ART explicito via Intl.DateTimeFormat.
  const fmtAr = new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Argentina/Buenos_Aires",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const hoyArtStr = fmtAr.format(new Date()); // "YYYY-MM-DD"
  const [hYY, hMM, hDD] = hoyArtStr.split("-").map((s) => parseInt(s, 10));
  // Construimos las dos fechas en UTC midnight para que el diff sea
  // estable independiente del runtime TZ.
  const vto = Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  const hoy = Date.UTC(hYY, hMM - 1, hDD);
  const diffMs = vto - hoy;
  return Math.floor(diffMs / (24 * 60 * 60 * 1000));
}

interface DashboardCounters {
  choferes_activos: number;
  unidades_total: number;
  unidades_asignadas: number;
  revisiones_pendientes: number;
  vencidos: number;
  proximos_7: number;
  proximos_30: number;
}

/**
 * Cuenta una fecha contra los buckets vencidos / proximos_7 / proximos_30.
 * Mismo criterio que `_Stats.from` cliente: null/no-parseable → vencido
 * (peor caso, para que el admin se entere si hay un campo corrupto).
 */
function _statsContarFecha(fecha: unknown, c: DashboardCounters): void {
  if (fecha === null || fecha === undefined || fecha === "") return;
  const dias = _statsCalcularDiasRestantes(fecha);
  if (dias === null || dias < 0) {
    c.vencidos++;
  } else if (dias <= 7) {
    c.proximos_7++;
  } else if (dias <= 30) {
    c.proximos_30++;
  }
}

/**
 * Recalcula los KPIs desde cero leyendo EMPLEADOS + VEHICULOS +
 * REVISIONES. Mismo cálculo que `_Stats.from` cliente. Llamada por el
 * scheduled cada 5 min y por el callable de force-refresh (futuro).
 */
async function _statsRecomputeDashboard(): Promise<DashboardCounters & { docs_leidos: number }> {
  const counters: DashboardCounters = {
    choferes_activos: 0,
    unidades_total: 0,
    unidades_asignadas: 0,
    revisiones_pendientes: 0,
    vencidos: 0,
    proximos_7: 0,
    proximos_30: 0,
  };

  // Cargar excluidos UNA vez (cacheado 10 min). Skip los 3 choferes y
  // sus vehículos (tanques + tractores asociados) para no inflar los
  // KPIs con operativa de combustibles líquidos (ver excluidos.ts).
  const excluidos = await cargarExcluidos(db);

  // Empleados con vehículo (.limit(5000) defensivo, igual que cliente).
  const empleadosSnap = await db.collection("EMPLEADOS").limit(5000).get();
  for (const doc of empleadosSnap.docs) {
    const data = doc.data();
    if (!_statsEsActivo(data)) continue;
    // Skip choferes excluidos (combustibles líquidos).
    if (excluidos.dnis.has(doc.id)) continue;
    const rol = _statsNormalizarRol(data.ROL);
    if (!ROLES_CON_VEHICULO.has(rol)) continue;
    const estado = String(data.estado_cuenta ?? "ACTIVO").toUpperCase();
    if (estado === "ACTIVO") counters.choferes_activos++;
    for (const sufijo of VENCIMIENTOS_EMPLEADO_SUFIJOS) {
      _statsContarFecha(data[`VENCIMIENTO_${sufijo}`], counters);
    }
  }

  // Vehículos.
  const vehiculosSnap = await db.collection("VEHICULOS").limit(5000).get();
  for (const doc of vehiculosSnap.docs) {
    const data = doc.data();
    if (!_statsEsActivo(data)) continue;
    // Skip vehículos excluidos (tanques + tractores de combustibles líquidos).
    if (excluidos.patentes.has(doc.id.toUpperCase())) continue;
    counters.unidades_total++;
    const estado = String(data.ESTADO ?? "").toUpperCase();
    if (ESTADOS_VEHICULO_OCUPADO.has(estado)) {
      counters.unidades_asignadas++;
    }
    const tipo = String(data.TIPO ?? "").toUpperCase();
    const esTractor = tipo === "TRACTOR" || tipo === "CHASIS";
    const sufijos = esTractor ?
      VENCIMIENTOS_TRACTOR_SUFIJOS :
      VENCIMIENTOS_ENGANCHE_SUFIJOS;
    for (const sufijo of sufijos) {
      _statsContarFecha(data[`VENCIMIENTO_${sufijo}`], counters);
    }
  }

  // Revisiones pendientes. Las aprobadas/rechazadas se borran del
  // collection en condiciones normales, pero filtramos por
  // estado=PENDIENTE defensivamente — si algún día queda basura
  // sin borrar, el contador no se infla. Además mantiene el
  // semántico claro (no contar todo lo que esté en la colección).
  const revisionesSnap = await db
    .collection("REVISIONES")
    .where("estado", "==", "PENDIENTE")
    .limit(500)
    .get();
  counters.revisiones_pendientes = revisionesSnap.size;

  return {
    ...counters,
    docs_leidos: empleadosSnap.size + vehiculosSnap.size + revisionesSnap.size,
  };
}

/**
 * Scheduled cada 30 min. Recalcula KPIs y los persiste en `STATS/dashboard`.
 * Stale máximo 30 min — aceptable para un dashboard admin.
 *
 * Auditoría 2026-05-30: bajado de 5 a 30 min. Recalculaba leyendo EMPLEADOS +
 * VEHICULOS + REVISIONES cada 5 min aunque nada hubiera cambiado (~72k reads/día
 * al pedo). El panel tolera 30 min de atraso sin problema.
 *
 * Costo: 3 reads × ~177 docs cada 30 min ≈ ~25k reads/mes (antes ~150k).
 */
export const recomputeDashboardStats = onScheduleConLatido(
  "recomputeDashboardStats",
  {
    schedule: "every 30 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 60,
    memory: "256MiB",
  },
  async () => {
    const inicio = Date.now();
    try {
      const stats = await _statsRecomputeDashboard();
      const duracionMs = Date.now() - inicio;
      await db.collection("STATS").doc("dashboard").set({
        v: DASHBOARD_STATS_SCHEMA_VERSION,
        ...stats,
        actualizado_en: FieldValue.serverTimestamp(),
        duracion_ms: duracionMs,
        computed_by: "scheduled",
      });
      logger.info("[recomputeDashboardStats] OK", {
        ...stats,
        duracion_ms: duracionMs,
      });
    } catch (e) {
      const err = e as Error;
      logger.error("[recomputeDashboardStats] error", {
        message: err.message,
        stack: err.stack,
      });
      // No re-throw — siguiente ciclo reintenta. El dashboard cliente
      // seguirá leyendo el último STATS/dashboard exitoso (stale).
    }
  }
);
