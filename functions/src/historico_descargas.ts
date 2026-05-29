// =============================================================================
// HISTÓRICO DE DESCARGAS — reconstrucción desde SITRACK_EVENTOS
// =============================================================================
//
// El cron `zonaDescargaPoller` mira SOLO la última posición de cada unidad
// (SITRACK_POSICIONES) cada 5 min, así que si por cualquier motivo no
// detectó una entrada/salida en tiempo real (bug, caída, mismatch de
// campos), esa descarga se pierde para siempre — la pos vieja se sobrescribe.
//
// SITRACK_EVENTOS, en cambio, es histórico: cada reporte queda con su
// timestamp + lat/lng. Reconstruimos pasando cada evento por el mismo
// chequeo de "está dentro de la zona" que usa el poller, agrupando por
// (patente × zona), y detectando ventanas continuas que cumplan la
// estadía mínima configurada.
//
// Uso: callable `backfillHistoricoDescargas({ dias: 7 })` o
// `({ desde_iso, hasta_iso })` para un rango exacto. Solo ADMIN. Idempotente
// — el docId del histórico es determinístico (mismo slug+patente+entrada_ms
// que usa el cron en vivo), así que correrlo dos veces sobre el mismo
// rango sobreescribe los mismos docs sin crear duplicados.
//
// Caso de uso original: bug 2026-05-28 que skipeaba TODAS las unidades
// silencioso (m.latitude vs m.lat). Después del fix, los datos de esos
// días había que rearmarlos desde SITRACK_EVENTOS — esta CF.

import { onCall } from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { ZonaConfig, unidadEnZona } from "./zonas_descarga";

/** Si entre 2 eventos consecutivos de la misma (patente × zona) hay un
 *  gap mayor a esto, cerramos la ventana actual y abrimos otra. Cubre
 *  blackouts cortos de GPS (túnel, batería) sin partir descargas reales.
 *  El cron en vivo usa el mismo criterio implícito vía staleness 15 min;
 *  acá somos un poco más permisivos porque los eventos llegan espaciados.
 */
const GAP_MAX_MS = 30 * 60 * 1000;

interface EventoMin {
  patente: string;
  lat: number;
  lng: number;
  ts: Timestamp;
  driverDni?: string;
  driverNombre?: string;
}

interface Descarga {
  patente: string;
  slug: string;
  nombreZona: string;
  entrada: Timestamp;
  salida: Timestamp;
  ultimoLat: number;
  ultimoLng: number;
  driverDni?: string;
  driverNombre?: string;
  eventosCount: number;
}

/** Función pura: dado un set de eventos y las zonas activas, devuelve las
 *  descargas detectadas. Sin I/O — testeable. */
export function reconstruirDescargas(
  eventos: EventoMin[],
  zonas: ZonaConfig[],
): Descarga[] {
  if (eventos.length === 0 || zonas.length === 0) return [];

  // Agrupar por patente para procesar cada unidad por separado.
  const porPatente = new Map<string, EventoMin[]>();
  for (const e of eventos) {
    if (!porPatente.has(e.patente)) porPatente.set(e.patente, []);
    porPatente.get(e.patente)!.push(e);
  }

  const descargas: Descarga[] = [];

  for (const [patente, evts] of porPatente) {
    evts.sort((a, b) => a.ts.toMillis() - b.ts.toMillis());

    // Para cada zona, recorrer eventos detectando ventanas in/out.
    for (const zona of zonas) {
      let entrada: Timestamp | null = null;
      let ultimoDentroEvt: EventoMin | null = null;
      let eventosCount = 0;
      let driverDni: string | undefined;
      let driverNombre: string | undefined;

      const cerrarVentana = () => {
        if (entrada && ultimoDentroEvt) {
          const dur = ultimoDentroEvt.ts.toMillis() - entrada.toMillis();
          if (dur >= zona.estadiaMinMs) {
            descargas.push({
              patente,
              slug: zona.slug,
              nombreZona: zona.nombre,
              entrada,
              salida: ultimoDentroEvt.ts,
              ultimoLat: ultimoDentroEvt.lat,
              ultimoLng: ultimoDentroEvt.lng,
              driverDni,
              driverNombre,
              eventosCount,
            });
          }
        }
        entrada = null;
        ultimoDentroEvt = null;
        eventosCount = 0;
        driverDni = undefined;
        driverNombre = undefined;
      };

      for (const e of evts) {
        const adentro = unidadEnZona(e.lat, e.lng, zona);

        if (adentro) {
          if (!entrada) {
            // Apertura de ventana
            entrada = e.ts;
            ultimoDentroEvt = e;
            eventosCount = 1;
            driverDni = e.driverDni;
            driverNombre = e.driverNombre;
          } else {
            // Continúa la ventana actual — verificar gap
            const gap = e.ts.toMillis() - ultimoDentroEvt!.ts.toMillis();
            if (gap > GAP_MAX_MS) {
              // Gap demasiado largo, cerrar la ventana en el último
              // evento adentro y abrir una nueva en este.
              cerrarVentana();
              entrada = e.ts;
              ultimoDentroEvt = e;
              eventosCount = 1;
              driverDni = e.driverDni;
              driverNombre = e.driverNombre;
            } else {
              ultimoDentroEvt = e;
              eventosCount++;
              // Nos quedamos con el primer chofer no vacío (algunos
              // eventos llegan sin driver_dni cuando el motor está off).
              if (!driverDni && e.driverDni) {
                driverDni = e.driverDni;
                driverNombre = e.driverNombre;
              }
            }
          }
        } else {
          // Afuera — cerrar ventana si había una abierta.
          if (entrada) cerrarVentana();
        }
      }
      // Al final del rango: si quedó una ventana abierta (la unidad
      // siguió adentro hasta el corte), cerrarla con el último evento.
      if (entrada) cerrarVentana();
    }
  }

  return descargas;
}

/** Persiste un set de descargas con el MISMO docId determinístico que el
 *  cron en vivo: `${slug}_${patente}_${entrada_ms}`. Idempotente. */
async function persistirDescargas(descargas: Descarga[]): Promise<number> {
  if (descargas.length === 0) return 0;
  let writes = 0;
  // Batches de 400 (Firestore limita a 500 ops/batch).
  for (let i = 0; i < descargas.length; i += 400) {
    const chunk = descargas.slice(i, i + 400);
    const batch = db.batch();
    for (const d of chunk) {
      const docId = `${d.slug}_${d.patente}_${d.entrada.toMillis()}`;
      const duracionMs = d.salida.toMillis() - d.entrada.toMillis();
      batch.set(db.collection("ZONA_DESCARGA_HISTORICO").doc(docId), {
        slug_zona: d.slug,
        nombre_zona: d.nombreZona,
        patente: d.patente,
        chofer_dni: d.driverDni ?? null,
        chofer_nombre: d.driverNombre ?? null,
        entrada_ts: d.entrada,
        salida_ts: d.salida,
        duracion_min: Math.round(duracionMs / 60000),
        duracion_seg: Math.round(duracionMs / 1000),
        ultimo_lat: d.ultimoLat,
        ultimo_lng: d.ultimoLng,
        archivado_en: FieldValue.serverTimestamp(),
        // Marca de origen — útil para auditar qué docs vienen del backfill
        // vs del cron en vivo.
        origen_backfill: true,
      });
      writes++;
    }
    await batch.commit();
  }
  return writes;
}

/** Carga las zonas activas y un set de eventos del rango. Reusa la lógica
 *  pura. Retorna stats. */
export async function procesarRangoDescargas(
  desde: Date,
  hasta: Date,
): Promise<{
  zonas: number;
  eventos: number;
  descargas: number;
  writes: number;
}> {
  // ─── Zonas activas ────────────────────────────────────────────
  const zonasSnap = await db.collection("ZONAS_DESCARGA")
    .where("activo", "==", true)
    .get();
  const zonas: ZonaConfig[] = zonasSnap.docs.map((d) => {
    const m = d.data();
    return {
      slug: (m.slug || d.id) as string,
      nombre: (m.nombre || "") as string,
      shape: (m.shape || "circulo") as "circulo" | "poligono",
      centro: m.centro as { lat: number; lng: number } | undefined,
      radioMts: typeof m.radio_mts === "number" ? m.radio_mts : undefined,
      vertices: Array.isArray(m.vertices) ?
        (m.vertices as { lat: number; lng: number }[]) : [],
      estadiaMinMs: (typeof m.estadia_min_min === "number" ?
        m.estadia_min_min : 5) * 60 * 1000,
    };
  });

  if (zonas.length === 0) {
    return { zonas: 0, eventos: 0, descargas: 0, writes: 0 };
  }

  // ─── Eventos del rango ────────────────────────────────────────
  const snap = await db.collection("SITRACK_EVENTOS")
    .where("report_date", ">=", Timestamp.fromDate(desde))
    .where("report_date", "<", Timestamp.fromDate(hasta))
    .get();

  const eventos: EventoMin[] = [];
  for (const d of snap.docs) {
    const m = d.data();
    // SITRACK_EVENTOS persiste la patente en `asset_id` (no `asset_name`,
    // que llega vacío en la cuenta `ws41629VecchiSRL`) y las coords como
    // `latitude`/`longitude` (no `lat`/`lng` como SITRACK_POSICIONES).
    const patente = (m.asset_id as string | undefined)?.trim().toUpperCase();
    const lat = typeof m.latitude === "number" ? m.latitude : null;
    const lng = typeof m.longitude === "number" ? m.longitude : null;
    const ts = m.report_date as Timestamp | undefined;
    if (!patente || lat === null || lng === null || !ts) continue;
    if (lat === 0 && lng === 0) continue;
    eventos.push({
      patente,
      lat,
      lng,
      ts,
      driverDni: (m.driver_dni as string | undefined)?.trim() || undefined,
      driverNombre: (m.driver_name as string | undefined)?.trim() || undefined,
    });
  }

  const descargas = reconstruirDescargas(eventos, zonas);
  const writes = await persistirDescargas(descargas);

  return {
    zonas: zonas.length,
    eventos: eventos.length,
    descargas: descargas.length,
    writes,
  };
}

/** Borra los docs de `ZONA_DESCARGA_HISTORICO` con `entrada_ts` en el
 *  rango [desde, hasta). Necesario antes de un backfill cuando cambia
 *  la geometría de una zona — el docId (slug+patente+entrada_ms)
 *  cambia y los docs viejos quedan duplicados con los nuevos. */
export async function limpiarHistoricoDescargasRango(
  desde: Date,
  hasta: Date,
): Promise<number> {
  const snap = await db.collection("ZONA_DESCARGA_HISTORICO")
    .where("entrada_ts", ">=", Timestamp.fromDate(desde))
    .where("entrada_ts", "<", Timestamp.fromDate(hasta))
    .get();
  let borrados = 0;
  for (let i = 0; i < snap.docs.length; i += 400) {
    const chunk = snap.docs.slice(i, i + 400);
    const batch = db.batch();
    for (const d of chunk) batch.delete(d.ref);
    await batch.commit();
    borrados += chunk.length;
  }
  return borrados;
}

// ============================================================================
// Callable de backfill — uso manual
// ============================================================================

export const backfillHistoricoDescargas = onCall(
  {
    timeoutSeconds: 540,
    memory: "1GiB",
    region: "us-central1",
  },
  async (req) => {
    const rol = (req.auth?.token?.rol as string | undefined) || "";
    if (rol !== "ADMIN") {
      throw new Error("Solo ADMIN puede correr el backfill.");
    }

    // 2 modos: por cantidad de días hacia atrás, o por rango ISO exacto.
    const desdeIso = req.data?.desde_iso as string | undefined;
    const hastaIso = req.data?.hasta_iso as string | undefined;

    const rangos: { ini: Date; fin: Date; label: string }[] = [];

    if (desdeIso && hastaIso) {
      const ini = new Date(desdeIso);
      const fin = new Date(hastaIso);
      if (isNaN(ini.getTime()) || isNaN(fin.getTime())) {
        throw new Error("desde_iso / hasta_iso invalidos.");
      }
      if (fin.getTime() <= ini.getTime()) {
        throw new Error("hasta_iso debe ser posterior a desde_iso.");
      }
      // Partir en días para no traer demasiados eventos en una sola query.
      const UN_DIA = 24 * 60 * 60 * 1000;
      for (let t = ini.getTime(); t < fin.getTime(); t += UN_DIA) {
        const ic = new Date(t);
        const fc = new Date(Math.min(t + UN_DIA, fin.getTime()));
        rangos.push({
          ini: ic,
          fin: fc,
          label: ic.toISOString().substring(0, 10),
        });
      }
    } else {
      const dias = Number(req.data?.dias ?? 1);
      if (!Number.isInteger(dias) || dias < 1 || dias > 30) {
        throw new Error("dias debe ser entero entre 1 y 30.");
      }
      // Hoy 00:00 ART = 03:00 UTC. Procesar [hoy-dias, hoy).
      const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
      const hoyArt = new Date(Date.UTC(
        ahoraArt.getUTCFullYear(),
        ahoraArt.getUTCMonth(),
        ahoraArt.getUTCDate(),
        3, 0, 0, 0,
      ));
      for (let i = 1; i <= dias; i++) {
        const fin = new Date(hoyArt.getTime() - (i - 1) * 24 * 60 * 60 * 1000);
        const ini = new Date(fin.getTime() - 24 * 60 * 60 * 1000);
        rangos.push({
          ini,
          fin,
          label: ini.toISOString().substring(0, 10),
        });
      }
    }

    // Por DEFAULT limpia los docs viejos del rango antes de reconstruir.
    // Necesario cuando cambia la geometría de una zona (radio/polígono)
    // — el docId determinístico cambia y queda duplicado con el doc
    // viejo. `limpiar: false` deja el comportamiento puro upsert.
    const limpiar = req.data?.limpiar !== false;

    let totalEventos = 0;
    let totalDescargas = 0;
    let totalWrites = 0;
    let totalBorrados = 0;
    const detalle: {
      fecha: string;
      borrados: number;
      eventos: number;
      descargas: number;
      writes: number;
    }[] = [];

    for (const r of rangos) {
      logger.info(`[backfillHistoricoDescargas] procesando ${r.label}`, {
        desde: r.ini.toISOString(),
        hasta: r.fin.toISOString(),
        limpiar,
      });
      try {
        const borrados = limpiar ?
          await limpiarHistoricoDescargasRango(r.ini, r.fin) : 0;
        const res = await procesarRangoDescargas(r.ini, r.fin);
        totalBorrados += borrados;
        totalEventos += res.eventos;
        totalDescargas += res.descargas;
        totalWrites += res.writes;
        detalle.push({
          fecha: r.label,
          borrados,
          eventos: res.eventos,
          descargas: res.descargas,
          writes: res.writes,
        });
      } catch (e) {
        logger.error(`[backfillHistoricoDescargas] error ${r.label}`, {
          error: (e as Error).message,
        });
        detalle.push({
          fecha: r.label,
          borrados: -1, eventos: -1, descargas: -1, writes: -1,
        });
      }
    }

    return {
      ok: true,
      rangos_procesados: rangos.length,
      limpiar,
      total_borrados: totalBorrados,
      total_eventos: totalEventos,
      total_descargas: totalDescargas,
      total_writes: totalWrites,
      detalle,
    };
  },
);

// ============================================================================
// Backfill AUTOMÁTICO diario — red de seguridad del histórico
// ============================================================================
//
// El cron en vivo `zonaDescargaPoller` (snapshot SITRACK_POSICIONES cada
// 5 min) se PIERDE descargas: el camión apaga el motor (deja de reportar →
// snapshot stale) o la estadía es corta / con maniobras entre ciclos. Caso
// real 2026-05-29: backfill detectó 17 descargas del día vs 7 del cron.
//
// Este cron re-procesa el DÍA ANTERIOR completo desde SITRACK_EVENTOS (más
// denso y fiable que el snapshot) con LIMPIEZA previa — idéntico a
// `scripts/backfill_descargas.js --dias 1`. El cron en vivo sigue para la
// COLA en tiempo real; este completa el HISTÓRICO. 04:30 ART da margen para
// que el día anterior haya cerrado y todos sus eventos estén persistidos.
export const backfillDescargasDiario = onSchedule(
  {
    schedule: "30 4 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async () => {
    // Día anterior completo en ART: [ayer 00:00 ART, hoy 00:00 ART).
    // 00:00 ART = 03:00 UTC del mismo día calendario ART.
    const ahoraArt = new Date(Date.now() - 3 * 60 * 60 * 1000);
    const fin = new Date(Date.UTC(
      ahoraArt.getUTCFullYear(),
      ahoraArt.getUTCMonth(),
      ahoraArt.getUTCDate(),
      3, 0, 0, 0,
    ));
    const ini = new Date(fin.getTime() - 24 * 60 * 60 * 1000);
    logger.info("[backfillDescargasDiario] iniciando", {
      desde: ini.toISOString(), hasta: fin.toISOString(),
    });
    try {
      const borrados = await limpiarHistoricoDescargasRango(ini, fin);
      const res = await procesarRangoDescargas(ini, fin);
      logger.info("[backfillDescargasDiario] OK", {
        borrados,
        zonas: res.zonas,
        eventos: res.eventos,
        descargas: res.descargas,
        writes: res.writes,
      });
    } catch (e) {
      logger.error("[backfillDescargasDiario] error", {
        error: (e as Error).message,
      });
    }
  },
);
