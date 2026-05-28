// =============================================================================
// ZONAS DE DESCARGA — cola en vivo + histórico (reemplazo de detección PTO)
// =============================================================================
//
// Reemplazo del módulo "DESCARGAS PTO" (que se basaba en el evento PTO de
// Volvo y daba falsos positivos + solo cubría flota Volvo).
//
// Detecta presencia REAL de cada unidad en geocercas configurables
// (definidas por el operador admin desde la pantalla "Zonas de descarga"),
// cruzando con las últimas posiciones que ya popula `sitrackPosicionPoller`
// en `SITRACK_POSICIONES`.
//
// Resultado:
//   - `ZONA_DESCARGA_COLA/{patente}_{slug}`: existe MIENTRAS la unidad
//     está dentro de la zona Y cumple estadía mínima → la pantalla
//     "Descargas" arma la cola en vivo (1° = el más viejo adentro).
//   - `ZONA_DESCARGA_HISTORICO/{slug}_{patente}_{ms}`: cada estadía
//     completada con entrada/salida/duración. Base para KPIs.
//
// Cron cada 5 min (mismo ritmo que SITRACK_POSICIONES, sino la cola
// quedaría más vieja que el dato fuente).

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db } from "./setup";
import { adquirirLockTick } from "./index";

// NOTA: reentradas espurias (la misma unidad sale y vuelve en <2 min,
// típico cuando pierde GPS por un túnel o da una vuelta) actualmente
// generan 2 descargas separadas en el histórico. Para la primera
// versión esto está OK — si Santiago observa casos reales, fusionamos
// con un look-back al último doc del histórico antes de archivar.

export interface ZonaConfig {
  slug: string;
  nombre: string;
  shape: "circulo" | "poligono";
  centro?: { lat: number; lng: number };
  radioMts?: number;
  vertices?: { lat: number; lng: number }[];
  estadiaMinMs: number; // convertido desde minutos
}

interface PosicionUnidad {
  patente: string;
  lat: number;
  lng: number;
  ts: Timestamp;
  driverDni?: string;
  driverNombre?: string;
}

// ─── Geometría ───────────────────────────────────────────────────

/** Distancia entre dos puntos lat/lng en metros (Haversine). */
export function distanciaMts(
  lat1: number, lng1: number, lat2: number, lng2: number,
): number {
  const R = 6371000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a = Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) *
      Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

/** Punto dentro de polígono (ray casting). */
export function puntoEnPoligono(
  lat: number, lng: number, vertices: { lat: number; lng: number }[],
): boolean {
  let dentro = false;
  for (let i = 0, j = vertices.length - 1; i < vertices.length; j = i++) {
    const xi = vertices[i].lng;
    const yi = vertices[i].lat;
    const xj = vertices[j].lng;
    const yj = vertices[j].lat;
    const intersect = ((yi > lat) !== (yj > lat)) &&
      (lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi);
    if (intersect) dentro = !dentro;
  }
  return dentro;
}

export function unidadEnZona(
  lat: number, lng: number, zona: ZonaConfig,
): boolean {
  if (zona.shape === "circulo" && zona.centro && zona.radioMts) {
    return distanciaMts(lat, lng, zona.centro.lat, zona.centro.lng) <=
      zona.radioMts;
  }
  if (zona.shape === "poligono" && (zona.vertices?.length ?? 0) >= 3) {
    return puntoEnPoligono(lat, lng, zona.vertices!);
  }
  return false;
}

// ─── Cron principal ──────────────────────────────────────────────

export const zonaDescargaPoller = onSchedule(
  {
    schedule: "every 5 minutes",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    const liberar = await adquirirLockTick(
      "zona_descarga_poller", 4 * 60 * 1000,
    );
    if (!liberar) return;
    try {
      // ─── 1) Cargar zonas activas ──────────────────────────────
      const zonasSnap = await db.collection("ZONAS_DESCARGA")
        .where("activo", "==", true)
        .get();
      if (zonasSnap.empty) {
        logger.info("[zonaDescargaPoller] sin zonas activas — skip");
        return;
      }
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

      // ─── 2) Cargar posiciones recientes (últimas 4 h) ──────────
      // Sitrack actualiza cada ~5 min con motor encendido, pero baja
      // a ~1 reporte/hora con motor apagado. En una descarga típica
      // (chofer llega, apaga motor, descarga, espera turno) la última
      // posición conocida puede quedarse "stale" 30-90 min aunque la
      // unidad físicamente sigue en el predio.
      //
      // Ventana 4 h: si la última posición es de ese rango y cae
      // dentro de una zona, asumimos que la unidad sigue ahí. Si se
      // fue y pierde señal antes de salir, queda en la cola hasta
      // 4 h después — tolerable.
      //
      // Antes era 15 min y se perdían unidades con motor off recién
      // llegadas a una planta (caso real 2026-05-28, AH628EI en
      // NECOCHEA con DIETRICH).
      const limiteMs = Date.now() - 4 * 60 * 60 * 1000;
      const posSnap = await db.collection("SITRACK_POSICIONES").get();
      const posiciones: PosicionUnidad[] = [];
      for (const doc of posSnap.docs) {
        const m = doc.data();
        const ts = m.report_date as Timestamp | undefined;
        if (!ts || ts.toMillis() < limiteMs) continue;
        // Nombres de campo según los persiste `sitrackPosicionPoller`
        // en `SITRACK_POSICIONES`: `lat`/`lng` (no `latitude`/`longitude`)
        // y `driver_nombre` (no `driver_name`). Mismatch viejo que hacía
        // que TODAS las unidades fueran skipeadas silencioso — la cola
        // de descargas quedaba siempre vacía aunque las unidades sí
        // estaban en zona. Fix 2026-05-28.
        const lat = m.lat;
        const lng = m.lng;
        if (typeof lat !== "number" || typeof lng !== "number") continue;
        if (lat === 0 && lng === 0) continue;
        posiciones.push({
          patente: doc.id,
          lat,
          lng,
          ts,
          driverDni: m.driver_dni as string | undefined,
          driverNombre: m.driver_nombre as string | undefined,
        });
      }
      logger.info("[zonaDescargaPoller] iniciando", {
        zonas: zonas.length, unidadesRecientes: posiciones.length,
      });

      // ─── 3) Cargar cola actual ────────────────────────────────
      const colaSnap = await db.collection("ZONA_DESCARGA_COLA").get();
      const colaActual = new Map<string, FirebaseFirestore.DocumentData>();
      for (const d of colaSnap.docs) colaActual.set(d.id, d.data());

      const ahora = Timestamp.now();
      const batch = db.batch();
      let writes = 0;
      const stats = { entradas: 0, salidas: 0, archivados: 0, dentro: 0 };

      // ─── 4) Detectar adentro/afuera por (unidad × zona) ───────
      // Set de docIds visitados — los que NO se visitan están "afuera".
      const visitadosCola = new Set<string>();

      for (const pos of posiciones) {
        for (const zona of zonas) {
          const docId = `${pos.patente}_${zona.slug}`;
          const adentro = unidadEnZona(pos.lat, pos.lng, zona);
          const existente = colaActual.get(docId);

          if (adentro) {
            stats.dentro++;
            visitadosCola.add(docId);
            if (existente) {
              // Update: solo refrescar última posición
              batch.set(db.collection("ZONA_DESCARGA_COLA").doc(docId), {
                ultima_pos_ts: pos.ts,
                ultimo_lat: pos.lat,
                ultimo_lng: pos.lng,
                ...(pos.driverDni ? { chofer_dni: pos.driverDni } : {}),
                ...(pos.driverNombre ? { chofer_nombre: pos.driverNombre } : {}),
              }, { merge: true });
              writes++;
            } else {
              // Entrada nueva
              stats.entradas++;
              batch.set(db.collection("ZONA_DESCARGA_COLA").doc(docId), {
                patente: pos.patente,
                slug_zona: zona.slug,
                nombre_zona: zona.nombre,
                entrada_ts: pos.ts,
                ultima_pos_ts: pos.ts,
                ultimo_lat: pos.lat,
                ultimo_lng: pos.lng,
                chofer_dni: pos.driverDni ?? null,
                chofer_nombre: pos.driverNombre ?? null,
              });
              writes++;
            }
          }
        }
      }

      // ─── 5) Salidas: docs en cola que NO están adentro ────────
      for (const [docId, data] of colaActual.entries()) {
        if (visitadosCola.has(docId)) continue;
        // Pudo no aparecer porque la unidad está stale (>15 min). Solo
        // archivamos si la última posición es > 15 min — sino esperamos
        // próximo ciclo. La unidad se "saca" de la cola igualmente.
        const ultPosTs = data.ultima_pos_ts as Timestamp | undefined;
        if (ultPosTs && ultPosTs.toMillis() > limiteMs) continue;

        stats.salidas++;
        const entradaTs = data.entrada_ts as Timestamp;
        const salidaTs = ultPosTs ?? ahora;
        const duracionMs = salidaTs.toMillis() - entradaTs.toMillis();
        const slug = data.slug_zona as string;
        const zona = zonas.find((z) => z.slug === slug);
        const estadiaMinMs = zona?.estadiaMinMs ?? 5 * 60 * 1000;

        if (duracionMs >= estadiaMinMs) {
          // Archivar al histórico (descarga válida)
          stats.archivados++;
          const histId = `${slug}_${data.patente}_${entradaTs.toMillis()}`;
          batch.set(db.collection("ZONA_DESCARGA_HISTORICO").doc(histId), {
            slug_zona: slug,
            nombre_zona: data.nombre_zona ?? null,
            patente: data.patente,
            chofer_dni: data.chofer_dni ?? null,
            chofer_nombre: data.chofer_nombre ?? null,
            entrada_ts: entradaTs,
            salida_ts: salidaTs,
            duracion_min: Math.round(duracionMs / 60000),
            duracion_seg: Math.round(duracionMs / 1000),
            ultimo_lat: data.ultimo_lat ?? null,
            ultimo_lng: data.ultimo_lng ?? null,
            archivado_en: FieldValue.serverTimestamp(),
          });
          writes++;
        }
        // En cualquier caso (haya o no archivado), sacar de la cola.
        batch.delete(db.collection("ZONA_DESCARGA_COLA").doc(docId));
        writes++;

        // Reentradas: si dentro de REENTRADA_TOLERANCIA_MS la misma
        // patente vuelve a la misma zona, la próxima iteración del cron
        // va a crear otra entrada nueva. NO la fusionamos automáticamente
        // porque eso requiere mirar la salida más reciente del histórico
        // — para la primera versión esto está OK; si Santiago ve casos de
        // doble descarga, hacemos el join en una próxima iteración.
      }

      if (writes > 0) await batch.commit();
      logger.info("[zonaDescargaPoller] OK", { writes, stats });
    } catch (e) {
      logger.error("[zonaDescargaPoller] error", {
        error: (e as Error).message,
      });
    } finally {
      await liberar();
    }
  },
);
