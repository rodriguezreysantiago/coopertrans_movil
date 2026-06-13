/**
 * Archivo frío de SITRACK_EVENTOS a GCS (Fase 3 auditoría 2026-06-12).
 *
 * Los eventos CRUDOS de Sitrack tienen TTL de 90 días (`expira_en`) — pasado eso
 * Firestore los borra. Pero son la PRUEBA re-procesable ante una disputa laboral
 * o auditoría YPF: jornadas / ICM / descargas se DESTILAN de ellos. Este cron
 * mensual exporta los meses ya cerrados a GCS en NDJSON (clase ARCHIVE vía
 * lifecycle del bucket, centavos/año) ANTES de que el TTL los borre.
 *
 * Bucket DEDICADO `coopertrans-movil-archivo-frio` — SIN lifecycle de borrado (a
 * diferencia de `coopertrans-movil-backups`, que rota a 30 días). Default
 * STANDARD + lifecycle que transiciona a ARCHIVE a los 30 días. Setup one-time
 * (crear bucket + IAM del SA de functions + índice compuesto): ver RUNBOOK.
 *
 * Robustez (review adversarial 2026-06-13):
 *   - CATCH-UP: cada corrida archiva el mes anterior (M-1) Y, si falta, el mes
 *     previo (M-2) — así una corrida fallida se recupera en la siguiente sin
 *     perder el mes (el margen al TTL de M-2 es ~25 días el día 5). Se trackean
 *     los meses ya archivados en STATS/archivo_frio_eventos.meses.
 *   - EVENTOS SIN FECHA: los docs con `report_date: null` (Sitrack no mandó
 *     fecha) quedan FUERA de las queries de rango por report_date → se archivan
 *     aparte por `recibido_en` (best-effort: si falla el índice no rompe el path
 *     crítico).
 *   - Idempotente: re-correr sobreescribe el `.ndjson` del mes (STANDARD, sin fee
 *     de borrado-temprano).
 */
import { getStorage } from "firebase-admin/storage";
import { Timestamp } from "firebase-admin/firestore";
import * as logger from "firebase-functions/logger";
import { db } from "./setup";
import { onScheduleConLatido } from "./comun";

const BUCKET_FRIO = "coopertrans-movil-archivo-frio";
const PREFIJO = "sitrack-eventos";
const PAGINA = 2000;

/**
 * Ventana [inicio, finExclusivo) del mes que está `offsetMeses` atrás de `ahora`,
 * en UTC, + etiqueta `YYYY-MM`. offset=1 → mes anterior; offset=2 → dos meses
 * atrás. PURA (testeada en archivo_frio.test.js).
 */
export function ventanaDeMes(
  ahora: Date,
  offsetMeses: number,
): { inicio: Date; finExclusivo: Date; etiqueta: string } {
  const y = ahora.getUTCFullYear();
  const m = ahora.getUTCMonth(); // 0-11 (mes actual)
  const inicio = new Date(Date.UTC(y, m - offsetMeses, 1, 0, 0, 0, 0));
  const finExclusivo = new Date(Date.UTC(y, m - offsetMeses + 1, 1, 0, 0, 0, 0));
  const yy = inicio.getUTCFullYear();
  const mm = String(inicio.getUTCMonth() + 1).padStart(2, "0");
  return { inicio, finExclusivo, etiqueta: `${yy}-${mm}` };
}

/** Mes anterior completo (offset 1). PURA. */
export function ventanaMesAnterior(ahora: Date): {
  inicio: Date;
  finExclusivo: Date;
  etiqueta: string;
} {
  return ventanaDeMes(ahora, 1);
}

/**
 * Serializa un doc de evento a una línea JSON re-procesable: los Timestamp de
 * Firestore se convierten a ISO-8601 (UTC) para que el NDJSON no dependa de los
 * tipos del SDK. Agrega `_id` (el report_id / doc id). PURA.
 */
export function serializarDoc(
  id: string,
  data: Record<string, unknown>,
): string {
  const limpio: Record<string, unknown> = { _id: id };
  for (const [k, v] of Object.entries(data)) {
    limpio[k] = v instanceof Timestamp ? v.toDate().toISOString() : v;
  }
  return JSON.stringify(limpio);
}

/**
 * Pagina una query (cursor por SNAPSHOT — robusto ante valores duplicados en el
 * campo de orden) y empuja cada doc serializado a `lineas`. Devuelve cuántos
 * agregó. El cursor por snapshot usa (campoOrden, __name__) → no saltea docs con
 * el mismo timestamp.
 */
async function drenarQuery(
  base: FirebaseFirestore.Query,
  lineas: string[],
): Promise<number> {
  let cursor: FirebaseFirestore.QueryDocumentSnapshot | null = null;
  let n = 0;
  for (;;) {
    let q = base.limit(PAGINA);
    if (cursor) q = q.startAfter(cursor);
    const snap = await q.get();
    if (snap.empty) break;
    for (const d of snap.docs) {
      lineas.push(serializarDoc(d.id, d.data()));
      n++;
    }
    cursor = snap.docs[snap.docs.length - 1];
    if (snap.size < PAGINA) break;
  }
  return n;
}

/**
 * Archiva un mes [inicio, finExclusivo) a `gs://BUCKET/PREFIJO/{etiqueta}.ndjson`.
 * Incluye: (1) eventos por `report_date` en la ventana, (2) eventos SIN fecha
 * (`report_date == null`) recibidos en la ventana (best-effort). Devuelve el
 * total de eventos archivados. NDJSON en memoria (≤ ~50 MB/mes; memory 1GiB da
 * margen; si el volumen supera ~100k/mes, migrar a createWriteStream).
 */
async function archivarMes(
  inicio: Date,
  finExclusivo: Date,
  etiqueta: string,
): Promise<number> {
  const desde = Timestamp.fromDate(inicio);
  const hasta = Timestamp.fromDate(finExclusivo);
  const lineas: string[] = [];

  // (1) Eventos con fecha, por report_date.
  const conFecha = await drenarQuery(
    db.collection("SITRACK_EVENTOS")
      .where("report_date", ">=", desde)
      .where("report_date", "<", hasta)
      .orderBy("report_date", "asc"),
    lineas,
  );

  // (2) Eventos SIN fecha (report_date null), por recibido_en. Best-effort: si
  // el índice compuesto (report_date, recibido_en) no está listo, NO rompemos el
  // archivo del mes — logueamos y seguimos. El índice se crea en el setup.
  let sinFecha = 0;
  try {
    sinFecha = await drenarQuery(
      db.collection("SITRACK_EVENTOS")
        .where("report_date", "==", null)
        .where("recibido_en", ">=", desde)
        .where("recibido_en", "<", hasta)
        .orderBy("recibido_en", "asc"),
      lineas,
    );
  } catch (e) {
    logger.warn("[archivoFrio] query de eventos sin-fecha falló (best-effort)", {
      tipo: "archivo_frio_sinfecha_error",
      mes: etiqueta,
      error: (e as Error).message,
    });
  }

  const total = conFecha + sinFecha;
  // Subimos SIEMPRE (incluso 0 eventos = archivo vacío) para dejar evidencia de
  // que el mes fue procesado.
  const ruta = `${PREFIJO}/${etiqueta}.ndjson`;
  const contenido = total > 0 ? lineas.join("\n") + "\n" : "";
  await getStorage().bucket(BUCKET_FRIO).file(ruta).save(
    Buffer.from(contenido, "utf8"),
    {
      resumable: false,
      contentType: "application/x-ndjson",
      metadata: {
        metadata: {
          mes: etiqueta,
          eventos: String(total),
          con_fecha: String(conFecha),
          sin_fecha: String(sinFecha),
        },
      },
    },
  );
  logger.info("[archivoFrio] mes archivado", {
    mes: etiqueta, total, conFecha, sinFecha, ruta,
  });
  return total;
}

export const archivarEventosSitrackFrio = onScheduleConLatido(
  "archivarEventosSitrackFrio",
  {
    // Día 5 de cada mes, 04:00 ART. El evento más viejo del mes anterior tiene
    // ~56 días remanentes de TTL al correr → margen amplio. Si una corrida falla,
    // la del mes siguiente recupera ese mes vía catch-up (M-2), con ~25 días de
    // margen al TTL — antes de eso el watchdog (33 días) ya alertó.
    schedule: "0 4 5 * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 540,
    memory: "1GiB",
  },
  async () => {
    const ahora = new Date();
    const statsRef = db.collection("STATS").doc("archivo_frio_eventos");
    const statsSnap = await statsRef.get();
    // meses: { "YYYY-MM": { count, run_at } } — registro de meses ya archivados,
    // para el catch-up (no re-archivar M-2 si ya está) y para detectar gaps.
    const meses = (statsSnap.data()?.meses ?? {}) as Record<string, unknown>;

    // M-1 (target del mes, siempre) + M-2 (catch-up: solo si falta). M-2 sigue
    // dentro de la ventana de TTL el día 5 (~25 días de margen).
    const target = ventanaDeMes(ahora, 1);
    const previo = ventanaDeMes(ahora, 2);
    const resultados: Array<{ mes: string; estado: string; total?: number }> = [];

    try {
      // M-1: siempre (es el mes recién cerrado).
      const t1 = await archivarMes(target.inicio, target.finExclusivo, target.etiqueta);
      meses[target.etiqueta] = { count: t1, run_at: Timestamp.now() };
      resultados.push({ mes: target.etiqueta, estado: "ok", total: t1 });

      // M-2: solo si NO está archivado (catch-up de una corrida fallida).
      if (!meses[previo.etiqueta]) {
        const t2 = await archivarMes(previo.inicio, previo.finExclusivo, previo.etiqueta);
        meses[previo.etiqueta] = { count: t2, run_at: Timestamp.now() };
        resultados.push({ mes: previo.etiqueta, estado: "catchup_ok", total: t2 });
        logger.warn("[archivoFrio] CATCH-UP: el mes M-2 no estaba archivado", {
          mes: previo.etiqueta, total: t2,
        });
      } else {
        resultados.push({ mes: previo.etiqueta, estado: "ya_archivado" });
      }
    } catch (e) {
      // Marca el error en STATS (además del latido fallido del watchdog) y
      // propaga para que onScheduleConLatido registre la corrida como fallida.
      await statsRef.set({
        meses,
        ultimo_estado: "error",
        ultimo_error: (e as Error).message,
        ultimo_run_at: Timestamp.now(),
      }, { merge: true });
      logger.error("[archivoFrio] FALLÓ", {
        error: (e as Error).message, resultados,
      });
      throw e;
    }

    await statsRef.set({
      meses,
      ultimo_estado: "ok",
      ultimo_mes: target.etiqueta,
      ultimo_run_at: Timestamp.now(),
    }, { merge: true });
    logger.info("[archivoFrio] OK", { resultados });
  },
);
