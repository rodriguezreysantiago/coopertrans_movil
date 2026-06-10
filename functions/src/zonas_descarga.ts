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
import { adquirirLockTick } from "./comun";

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

      // ─── 3b) Eventos recientes para la detección de entrada por EVENTOS ─
      // (fix cobertura en vivo 2026-05-29). El snapshot del paso 4 pierde
      // descargas cuando la unidad no reporta justo estando adentro (motor
      // apagado → snapshot stale fuera; o entra/maniobra entre ciclos). Los
      // EVENTOS (SITRACK_EVENTOS, densos) capturan esa entrada — misma señal
      // que usa el backfill, traída al vivo. Una query (~150 docs/15 min).
      // Formato como el backfill: patente en `asset_id`, coords en
      // `latitude`/`longitude` (NO `lat`/`lng`, que son de SITRACK_POSICIONES).
      const VENTANA_EVENTOS_MS = 15 * 60 * 1000;
      const eventosRecientesPorPatente = new Map<string, PosicionUnidad[]>();
      try {
        const desdeEv = Timestamp.fromMillis(Date.now() - VENTANA_EVENTOS_MS);
        const evSnap = await db.collection("SITRACK_EVENTOS")
          .where("report_date", ">=", desdeEv)
          .get();
        for (const d of evSnap.docs) {
          const m = d.data();
          const patente = (m.asset_id as string | undefined)
            ?.trim().toUpperCase();
          const lat = typeof m.latitude === "number" ? m.latitude : null;
          const lng = typeof m.longitude === "number" ? m.longitude : null;
          const ts = m.report_date as Timestamp | undefined;
          if (!patente || lat === null || lng === null || !ts) continue;
          if (lat === 0 && lng === 0) continue;
          let arr = eventosRecientesPorPatente.get(patente);
          if (!arr) {
            arr = [];
            eventosRecientesPorPatente.set(patente, arr);
          }
          arr.push({
            patente, lat, lng, ts,
            driverDni: (m.driver_dni as string | undefined)?.trim() ||
              undefined,
            driverNombre: (m.driver_name as string | undefined)?.trim() ||
              undefined,
          });
        }
        for (const arr of eventosRecientesPorPatente.values()) {
          arr.sort((a, b) => a.ts.toMillis() - b.ts.toMillis());
        }
      } catch (e) {
        logger.warn(
          "[zonaDescargaPoller] no se pudo cargar SITRACK_EVENTOS, " +
            "detección solo por snapshot",
          { error: (e as Error).message },
        );
      }

      const ahora = Timestamp.now();
      const batch = db.batch();
      let writes = 0;
      const stats = {
        entradas: 0, salidas: 0, archivados: 0, dentro: 0,
        entradasPorEvento: 0, // entradas que el snapshot habría perdido
      };

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

      // ─── 4b) Entrada por EVENTOS recientes (ADITIVO — fix cobertura) ──
      // Para las unidades que el snapshot NO marcó adentro (paso 4) pero que
      // SÍ tienen un evento dentro de la zona en la ventana reciente, las
      // metemos en cola igual. Solo SUMA detecciones; `visitadosCola` evita
      // re-procesar las que ya entraron por snapshot. La salida (paso 5) y el
      // archivado no cambian — una vez en cola, la ventana de 4h la sostiene
      // aunque el motor se apague.
      for (const [patente, evs] of eventosRecientesPorPatente) {
        for (const zona of zonas) {
          const docId = `${patente}_${zona.slug}`;
          if (visitadosCola.has(docId)) continue; // ya entró por snapshot
          const evsDentro = evs.filter((e) => unidadEnZona(e.lat, e.lng, zona));
          if (evsDentro.length === 0) continue;
          visitadosCola.add(docId);
          stats.dentro++;
          const primero = evsDentro[0]; // proxy de entrada (más viejo en ventana)
          const ultimo = evsDentro[evsDentro.length - 1];
          if (colaActual.get(docId)) {
            // Ya estaba en cola → solo refrescar última posición.
            batch.set(db.collection("ZONA_DESCARGA_COLA").doc(docId), {
              ultima_pos_ts: ultimo.ts,
              ultimo_lat: ultimo.lat,
              ultimo_lng: ultimo.lng,
              ...(ultimo.driverDni ? { chofer_dni: ultimo.driverDni } : {}),
              ...(ultimo.driverNombre ?
                { chofer_nombre: ultimo.driverNombre } : {}),
            }, { merge: true });
            writes++;
          } else {
            // Entrada nueva que el snapshot se había perdido.
            stats.entradas++;
            stats.entradasPorEvento++;
            batch.set(db.collection("ZONA_DESCARGA_COLA").doc(docId), {
              patente,
              slug_zona: zona.slug,
              nombre_zona: zona.nombre,
              entrada_ts: primero.ts,
              ultima_pos_ts: ultimo.ts,
              ultimo_lat: ultimo.lat,
              ultimo_lng: ultimo.lng,
              chofer_dni: ultimo.driverDni ?? null,
              chofer_nombre: ultimo.driverNombre ?? null,
              origen_entrada: "evento",
            });
            writes++;
          }
        }
      }

      // ─── 5) Salidas: docs en cola que NO están adentro ────────
      // Una unidad se cierra (sale de la cola) en 2 casos:
      //  (a) REPORTA posición fresca (<4h) pero fuera de esta zona → la
      //      vemos en otro lado → SALIÓ de verdad → cerrar YA.
      //  (b) NO reporta hace > 4h (stale) → asumimos que ya no está →
      //      cerrar.
      // Solo se ESPERA si NO reporta fresco PERO su última posición
      // (dentro) es < 4h: ahí asumimos que sigue en el predio con el GPS
      // dormido (motor apagado) y esperamos al próximo ciclo.
      //
      // BUG anterior (caso AG218ZD 2026-05-29): solo se contemplaba (b),
      // así que una unidad que SALÍA reportando (motor encendido, en la
      // ruta) quedaba trabada en la cola hasta 4 h porque su última pos
      // DENTRO seguía siendo < 4h. La pista era `ultima_pos_ts` (la
      // última vez adentro), que no se refresca cuando la unidad está
      // afuera → nunca superaba el límite mientras la descarga era
      // reciente.
      // Reporta fresco = aparece en el snapshot O en los eventos recientes.
      // Incluir los eventos permite CERRAR por eventos una unidad que entró
      // por eventos y ya salió (sin esperar el stale de 4h del snapshot).
      const patentesFrescas = new Set<string>([
        ...posiciones.map((p) => p.patente),
        ...eventosRecientesPorPatente.keys(),
      ]);
      for (const [docId, data] of colaActual.entries()) {
        if (visitadosCola.has(docId)) continue;
        const ultPosTs = data.ultima_pos_ts as Timestamp | undefined;
        const reportaFresco = patentesFrescas.has(data.patente as string);
        // Sigue en el predio sin señal → esperar (no reporta y la última
        // pos adentro es reciente). Si reporta fresco, SALIÓ → cerrar.
        if (!reportaFresco && ultPosTs && ultPosTs.toMillis() > limiteMs) {
          continue;
        }

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
