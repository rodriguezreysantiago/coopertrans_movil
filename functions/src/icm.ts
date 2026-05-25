// =============================================================================
// recomputeIcmSemanalScheduled — agregados ICM semanales en `ICM_SEMANAL`
// =============================================================================
// Refactor mayor 2026-05-19: implementación EXACTA CESVI homologada
// (presentación Carsync). Ver `icm_cesvi.ts` para las funciones puras
// y los pesos por tipo.
//
// **Rediseño 2026-05-22 (Santiago, "todo marca ~100"): unidad = (chofer,
// día ART), NO las jornadas del vigilador** (estaban rotas y dejaban el
// 41% de las infracciones fuera de ventana; el km salía de odómetro por
// evento y los eventos bruscos no traen odómetro → casi todo se
// descartaba). Ahora: bucket por día, km POR PATENTE (eventos de
// movimiento traen odómetro), sin fatiga. Es una ESTIMACIÓN INTERNA — no
// el ICM oficial homologado de YPF/Carsync (que pondera por segmento
// vial, dato que no tenemos).
//
// Cada lunes 6 AM ART calcula los agregados de la SEMANA ANTERIOR
// (lun-dom que acaba de cerrar) y los persiste en `ICM_SEMANAL/{YYYY-WW}`.
//
// El cliente Flutter (módulo ICM) lee primero de esta colección (rápido,
// ~50 docs históricos máximo) y solo cae al cálculo on-the-fly desde
// SITRACK_EVENTOS para la semana actual que aún no cerró. Eso evita
// recomputar 12 semanas de eventos cada vez que se abre el reporte.
//
// Schema del doc `ICM_SEMANAL/{YYYY-WW}` (compat hacia atrás mantenido):
//   {
//     semana_id: string ("2026-W20" — ISO week format),
//     semana_inicio_ts: Timestamp (lunes 00:00 ART),
//     semana_fin_ts: Timestamp (siguiente lunes 00:00 ART),
//     semana_label: string ("12-18 May"),
//     icm_promedio: number (0-100, media simple de ICM por chofer),
//     total_eventos: number (count de eventos CESVI puros),
//     choferes_activos: number,
//     choferes_verdes: number,    // ICM >= 91 (Bajo)
//     choferes_amarillos: number, // 71 <= ICM < 91 (Medio)
//     choferes_rojos: number,     // ICM < 71 (Alto)
//     choferes: [{ dni, nombre, icm, total_eventos, ratio_100km,
//                  categoria, eventos_por_tipo, km_recorridos,
//                  jornadas_contadas }],
//     top_5_mejores: [{ dni, nombre, icm }],
//     top_5_peores: [{ dni, nombre, icm }],
//     calculado_en: Timestamp (server),
//   }

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { TIPOS_CESVI_PUROS } from "./index";
import { cargarExcluidos } from "./excluidos";
import {
  EventoSitrackICM,
  calcularIcmJornada,
  combinarJornadas,
  categorizar,
} from "./icm_cesvi";

/** Cap defensivo: una patente no recorre > 2000 km en un día. Si el
 * delta de odómetro de la patente en el día lo supera, es casi seguro un
 * reset de odómetro Sitrack — ese día de esa patente no aporta km. */
const KM_MAX_PATENTE_DIA = 2000;

/** Día calendario ART (UTC-3, sin DST) de un timestamp en ms →
 * 'YYYY-MM-DD'. Mismo criterio que el cliente (icm_calculator.dart). */
function diaArt(ms: number): string {
  const art = new Date(ms - 3 * 3600 * 1000);
  const y = art.getUTCFullYear();
  const m = (art.getUTCMonth() + 1).toString().padStart(2, "0");
  const d = art.getUTCDate().toString().padStart(2, "0");
  return `${y}-${m}-${d}`;
}

export const recomputeIcmSemanalScheduled = onSchedule(
  {
    // Lunes 6 AM ART — la semana que termina justo el domingo 23:59
    // ya está cerrada y completa.
    schedule: "0 6 * * 1",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 240,
    memory: "512MiB",
  },
  async () => {
    logger.info("[recomputeIcmSemanalScheduled] iniciando");

    // ─── 1. Calcular rango de la SEMANA ANTERIOR en ART ────────────
    const ahora = new Date();
    const fechaArtHoy = new Intl.DateTimeFormat("en-CA", {
      timeZone: "America/Argentina/Buenos_Aires",
      year: "numeric", month: "2-digit", day: "2-digit",
    }).format(ahora);
    const lunesActualMs = Date.parse(`${fechaArtHoy}T00:00:00-03:00`);
    const lunesAnteriorMs = lunesActualMs - 7 * 24 * 60 * 60 * 1000;

    const semanaInicio = new Date(lunesAnteriorMs);
    const semanaFin = new Date(lunesActualMs);
    const semanaId = _isoWeekId(semanaInicio);
    const semanaLabel = _semanaLabel(semanaInicio, semanaFin);

    logger.info("[recomputeIcmSemanalScheduled] rango", {
      semanaId, semanaLabel,
      desde: semanaInicio.toISOString(),
      hasta: semanaFin.toISOString(),
    });

    // ─── 2. Lookup nombres de empleados ───────────────────────────
    const empSnap = await db.collection("EMPLEADOS").limit(5000).get();
    // Audit 2026-05-24: aviso si EMPLEADOS crece cerca del cap. Hoy
    // ~100 docs, muy lejos del límite. Si dispara, paginar con cursor.
    if (empSnap.size >= 4500) {
      logger.warn(
        "[recomputeIcmSemanalScheduled] EMPLEADOS cerca del límite 5000",
        { size: empSnap.size },
      );
    }
    const nombrePorDni = new Map<string, string>();
    for (const d of empSnap.docs) {
      const data = d.data();
      const dni = (data.DNI ?? d.id).toString();
      const nombre = (data.NOMBRE ?? "").toString().trim();
      if (nombre) nombrePorDni.set(dni, nombre);
    }

    // ─── 3. Cargar excluidos (3 choferes tanqueros + testers) ────
    const excluidos = await cargarExcluidos(db);

    // ─── 4. Cargar eventos Sitrack del rango (CESVI puros + eventos
    // de movimiento para km por patente) ───────────────────────────
    const LIMIT_SITRACK = 200000;
    const evSnap = await db
      .collection("SITRACK_EVENTOS")
      .where("report_date", ">=", Timestamp.fromMillis(lunesAnteriorMs))
      .where("report_date", "<", Timestamp.fromMillis(lunesActualMs))
      .limit(LIMIT_SITRACK)
      .get();
    if (evSnap.size >= LIMIT_SITRACK) {
      logger.warn(
        "[recomputeIcmSemanalScheduled] SITRACK_EVENTOS alcanzó limit " +
        `(${LIMIT_SITRACK}). ICM puede estar incompleto.`,
      );
    }

    // Indexar UNA sola pasada. Claves compuestas con `|`:
    // 'dni|dia' y 'patente|dia'.
    interface MinMax { min: number; max: number }
    // Eventos CESVI (66/67/383/8/9) por (dni, día).
    const cesviPorDniDia = new Map<string, EventoSitrackICM[]>();
    // Odómetro min/max por (patente, día) — de cada evento con odómetro.
    const odoPatDia = new Map<string, MinMax>();
    // Patentes que tocó cada (dni, día).
    const patentesPorDniDia = new Map<string, Set<string>>();
    // Conteo de eventos por (patente, día) → {dni: count} para prorratear
    // km cuando varios choferes usaron la patente el mismo día (turnos).
    const eventosPatDiaDni = new Map<string, Map<string, number>>();
    // Para el detalle del chofer.
    const patentesPorChofer = new Map<string, Map<string, number>>();
    const eventosNombrePorChofer = new Map<string, Map<string, number>>();
    for (const docu of evSnap.docs) {
      const data = docu.data();
      const tsMs = (data.report_date as Timestamp | undefined)?.toMillis?.();
      if (!tsMs) continue;
      const dia = diaArt(tsMs);
      const pat = (data.asset_id ?? "").toString().trim().toUpperCase();
      if (pat && excluidos.patentes.has(pat)) continue;
      const odo = typeof data.odometer === "number" ? data.odometer :
        (typeof data.gps_odometer === "number" ? data.gps_odometer : null);
      if (pat && odo !== null && odo > 0) {
        const k = `${pat}|${dia}`;
        const mm = odoPatDia.get(k) ?? { min: Infinity, max: -Infinity };
        if (odo < mm.min) mm.min = odo;
        if (odo > mm.max) mm.max = odo;
        odoPatDia.set(k, mm);
      }
      const dni = (data.driver_dni ?? "").toString().trim();
      if (!dni || excluidos.dnis.has(dni)) continue;
      const claveDD = `${dni}|${dia}`;
      if (pat) {
        let s = patentesPorDniDia.get(claveDD);
        if (!s) { s = new Set<string>(); patentesPorDniDia.set(claveDD, s); }
        s.add(pat);
        const kp = `${pat}|${dia}`;
        let m = eventosPatDiaDni.get(kp);
        if (!m) { m = new Map<string, number>(); eventosPatDiaDni.set(kp, m); }
        m.set(dni, (m.get(dni) ?? 0) + 1);
      }
      const eId = typeof data.event_id === "number" ? data.event_id : -1;
      if (!TIPOS_CESVI_PUROS.has(eId)) continue;
      const ev: EventoSitrackICM = {
        eventId: eId,
        reportDateMs: tsMs,
        assetId: pat,
        driverDni: dni,
        speed: typeof data.speed === "number" ? data.speed :
          (typeof data.gps_speed === "number" ? data.gps_speed : null),
        cartographyLimitSpeed:
          typeof data.cartography_limit_speed === "number" ?
            data.cartography_limit_speed : null,
        areaType: (data.area_type ?? "unknown").toString(),
        odometer: odo,
      };
      const arr = cesviPorDniDia.get(claveDD) ?? [];
      arr.push(ev);
      cesviPorDniDia.set(claveDD, arr);
      const nombre = (data.event_name ?? `Evento ${eId}`).toString();
      let mn = eventosNombrePorChofer.get(dni);
      if (!mn) { mn = new Map<string, number>(); eventosNombrePorChofer.set(dni, mn); }
      mn.set(nombre, (mn.get(nombre) ?? 0) + 1);
      if (pat) {
        let mp = patentesPorChofer.get(dni);
        if (!mp) { mp = new Map<string, number>(); patentesPorChofer.set(dni, mp); }
        mp.set(pat, (mp.get(pat) ?? 0) + 1);
      }
    }

    // km de un (dni, día) = Σ por patente que tocó del delta de odómetro
    // de esa patente ese día, prorrateado por la porción de eventos del
    // chofer (cambio de turno). Cap KM_MAX_PATENTE_DIA por reset.
    const kmDniDia = (claveDD: string): number => {
      const pats = patentesPorDniDia.get(claveDD);
      if (!pats || pats.size === 0) return 0;
      const sep = claveDD.indexOf("|");
      const dni = claveDD.substring(0, sep);
      const dia = claveDD.substring(sep + 1);
      let km = 0;
      for (const pat of pats) {
        const kp = `${pat}|${dia}`;
        const mm = odoPatDia.get(kp);
        if (!mm || !(mm.max > mm.min) || mm.min === Infinity) continue;
        const delta = mm.max - mm.min;
        if (delta <= 0 || delta > KM_MAX_PATENTE_DIA) continue;
        const conteo = eventosPatDiaDni.get(kp);
        if (!conteo || conteo.size === 0) continue;
        let total = 0;
        for (const v of conteo.values()) total += v;
        const mio = conteo.get(dni) ?? 0;
        if (total <= 0 || mio <= 0) continue;
        km += delta * (mio / total);
      }
      return km;
    };

    // ─── 5. Buckets (dni, día) → ICM CESVI ────────────────────────
    // El set de buckets es la unión de los que tienen eventos CESVI y
    // los que tienen patente con km — así un chofer que manejó limpio
    // (solo eventos de movimiento) entra en ICM 100, y uno con
    // infracciones pero sin odómetro no se pierde. SIN fatiga (no hay
    // señal real de tiempo recorrido en el feed → bloque vacío).
    interface DiaCalc {
      dni: string;
      icm: number;
      km: number;
      desglose: ReturnType<typeof calcularIcmJornada>["desglose"];
    }
    const porChofer = new Map<string, DiaCalc[]>();
    const claves = new Set<string>([
      ...cesviPorDniDia.keys(),
      ...patentesPorDniDia.keys(),
    ]);
    for (const clave of claves) {
      const sep = clave.indexOf("|");
      const dni = clave.substring(0, sep);
      const eventos = cesviPorDniDia.get(clave) ?? [];
      const km = kmDniDia(clave);
      if (eventos.length === 0 && km <= 0) continue;
      const resultado = calcularIcmJornada(eventos, []);
      const lista = porChofer.get(dni) ?? [];
      lista.push({ dni, icm: resultado.icm, km, desglose: resultado.desglose });
      porChofer.set(dni, lista);
    }
    logger.info("[recomputeIcmSemanalScheduled] buckets (dni,día) procesados", {
      eventosCargados: evSnap.size,
      bucketsConActividad: claves.size,
      choferesConActividad: porChofer.size,
    });

    // ─── 6. Combinar días en ICM agregado por chofer (km-weighted) ─
    interface ChoferAgg {
      dni: string;
      nombre: string;
      icm: number;
      total_eventos: number;
      ratio_100km: number;
      categoria: string;
      eventos_por_tipo: Record<string, number>;
      km_recorridos: number;
      jornadas_contadas: number;
    }
    const choferes: ChoferAgg[] = [];
    for (const [dni, jornadas] of porChofer.entries()) {
      const agregado = combinarJornadas(jornadas);
      const totalEventosCesvi =
        agregado.desgloseSumado.aceleracionesBruscas +
        agregado.desgloseSumado.frenadasBruscas +
        agregado.desgloseSumado.girosBruscos +
        agregado.desgloseSumado.sobrevelocidades;
      const ratio = agregado.kmTotales > 0 ?
        totalEventosCesvi / (agregado.kmTotales / 100) : 0;
      choferes.push({
        dni,
        nombre: nombrePorDni.get(dni) ?? `DNI ${dni}`,
        icm: Number(agregado.icm.toFixed(2)),
        total_eventos: totalEventosCesvi,
        ratio_100km: Number(ratio.toFixed(2)),
        categoria: agregado.categoria,
        eventos_por_tipo: {
          "Aceleración brusca": agregado.desgloseSumado.aceleracionesBruscas,
          "Frenada brusca": agregado.desgloseSumado.frenadasBruscas,
          "Giro brusco": agregado.desgloseSumado.girosBruscos,
          "Sobrevelocidad": agregado.desgloseSumado.sobrevelocidades,
        },
        km_recorridos: Number(agregado.kmTotales.toFixed(1)),
        jornadas_contadas: agregado.jornadas,
      });
    }

    // ─── 8. Agregados flota ───────────────────────────────────────
    const choferesConDatos = choferes.filter((c) => c.categoria !== "SIN_DATOS");
    const totalEventos = choferes.reduce((acc, c) => acc + c.total_eventos, 0);
    // ICM promedio = media simple de los ICM por chofer (cada chofer
    // cuenta igual). NO km-weighted a nivel flota: nuestro odómetro es
    // disperso y su disponibilidad correlaciona con unidades nuevas (más
    // limpias), lo que sesgaría el promedio hacia arriba escondiendo a
    // los peores choferes (km=0). El ICM de CADA chofer ya viene
    // km-weighted por sus días. Consistente con el cálculo on-the-fly
    // del cliente (icm_historico_service).
    const icmPromedio = choferesConDatos.length > 0 ?
      Number((choferesConDatos.reduce((acc, c) => acc + c.icm, 0) /
        choferesConDatos.length).toFixed(2)) : 0;
    const verdes = choferesConDatos.filter((c) => c.categoria === "BAJO").length;
    const amarillos = choferesConDatos.filter((c) => c.categoria === "MEDIO").length;
    const rojos = choferesConDatos.filter((c) => c.categoria === "ALTO").length;
    const sinDatos = choferes.filter((c) => c.categoria === "SIN_DATOS").length;
    const sortedAsc = [...choferesConDatos].sort((a, b) => a.icm - b.icm);
    const top5Peores = sortedAsc.slice(0, 5).map((c) => ({
      dni: c.dni, nombre: c.nombre, icm: c.icm,
    }));
    const top5Mejores = sortedAsc.slice(-5).reverse().map((c) => ({
      dni: c.dni, nombre: c.nombre, icm: c.icm,
    }));

    // ─── 9. Persistir en ICM_SEMANAL/{YYYY-WW} ─────────────────────
    await db.collection("ICM_SEMANAL").doc(semanaId).set({
      semana_id: semanaId,
      semana_inicio_ts: Timestamp.fromMillis(lunesAnteriorMs),
      semana_fin_ts: Timestamp.fromMillis(lunesActualMs),
      semana_label: semanaLabel,
      icm_promedio: icmPromedio,
      total_eventos: totalEventos,
      choferes_activos: choferesConDatos.length,
      choferes_sin_datos: sinDatos,
      choferes_verdes: verdes,
      choferes_amarillos: amarillos,
      choferes_rojos: rojos,
      choferes,
      top_5_mejores: top5Mejores,
      top_5_peores: top5Peores,
      formula_version: "cesvi-1.0", // marcador para migración futura
      calculado_en: FieldValue.serverTimestamp(),
    });

    logger.info("[recomputeIcmSemanalScheduled] OK", {
      semanaId, icmPromedio, totalEventos,
      choferesConDatos: choferesConDatos.length,
      sinDatos, verdes, amarillos, rojos,
    });
  }
);

// Re-exports para que el helper de categorización quede accesible desde
// el cliente y para tests (compat con consumidores externos del módulo).
export { categorizar as categorizarIcm };

// Helper: ID semana ISO 8601 ("YYYY-WNN") de un Date.
// Fix auditoria 2026-05-16: antes mezclaba UTC y local. Ahora UTC
// consistente desde el primer paso.
function _isoWeekId(d: Date): string {
  const target = new Date(Date.UTC(
    d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()
  ));
  const dayNum = (target.getUTCDay() + 6) % 7;
  target.setUTCDate(target.getUTCDate() - dayNum + 3);
  const firstThursday = new Date(Date.UTC(target.getUTCFullYear(), 0, 4));
  const week = 1 + Math.round(
    ((target.getTime() - firstThursday.getTime()) / 86400000 -
      3 + ((firstThursday.getUTCDay() + 6) % 7)) / 7
  );
  const year = target.getUTCFullYear();
  return `${year}-W${week.toString().padStart(2, "0")}`;
}

// Helper: label legible de una semana ("12-18 May" o "30 Abr - 6 May").
function _semanaLabel(inicio: Date, fin: Date): string {
  const meses = [
    "Ene", "Feb", "Mar", "Abr", "May", "Jun",
    "Jul", "Ago", "Sep", "Oct", "Nov", "Dic",
  ];
  const finDom = new Date(fin.getTime() - 24 * 60 * 60 * 1000);
  const inicioArt = new Date(inicio.getTime() - 3 * 60 * 60 * 1000);
  const finArt = new Date(finDom.getTime() - 3 * 60 * 60 * 1000);
  if (inicioArt.getUTCMonth() === finArt.getUTCMonth()) {
    return `${inicioArt.getUTCDate()}-${finArt.getUTCDate()} ` +
      meses[inicioArt.getUTCMonth()];
  }
  return `${inicioArt.getUTCDate()} ${meses[inicioArt.getUTCMonth()]} - ` +
    `${finArt.getUTCDate()} ${meses[finArt.getUTCMonth()]}`;
}
