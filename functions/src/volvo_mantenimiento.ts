// =============================================================================
// MANTENIMIENTO DE FLOTA (Volvo) — parte diario a Emmanuel (#43)
// =============================================================================
//
// Lee VOLVO_ESTADO (tell-tales capturados por estadoVolvoPoller, incl. la 2da
// consulta UPTIME) y arma el parte de ADVERTENCIAS EXACTAS por unidad para el
// jefe de mantenimiento de la flota (CORCHETE EMMANUEL). Cada testigo va con su
// nombre real en español (ABS del acoplado, AEBS, etc.) y priorizado por
// sistema — no "se prendió una luz".
//
// Cron 08:00 ART, mismo patrón que los otros resúmenes diarios: idempotencia
// atómica + TTL en COLA_WHATSAPP + lock liberable si falla la encolada.
//
// Nota v1: el parte refleja el ESTADO ACTUAL de los testigos, así que una
// advertencia persistente (un YELLOW que no se arregla) se repite cada día —
// es un recordatorio. Si Emmanuel lo quiere "sólo cuando cambia", se ajusta.

import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { FieldValue, Timestamp } from "firebase-admin/firestore";

import { db, BANNER_TESTING } from "./setup";
import {
  adquirirIdempotenciaDiaria,
  MANTENIMIENTO_VEHICULOS_DNI,
  TTL_RESUMEN_DIARIO_MIN,
} from "./comun";
import { expiraEnMin, formatFechaArg, primerNombre } from "./helpers";
import {
  Advertencia,
  SeveridadAdvertencia,
  clasificarAdvertencias,
} from "./volvo_telltales";
import { cargarExcluidos } from "./excluidos";

/**
 * Evento de VOLVO_ALERTAS (Vehicle Alerts API) que NO es un testigo del
 * tablero pero le interesa al mantenimiento: presión / temperatura de
 * neumático y tacógrafo fuera de servicio. Hasta 2026-05-22 los reportaba
 * el bot en un resumen aparte (duplicado para Emmanuel) — ahora se suman
 * al Parte, con horario, porque son eventos puntuales (no estado).
 */
export interface EventoMantenimiento {
  /** Tipo normalizado: TPM, TTM, TACHO_OUT_OF_SCOPE_MODE_CHANGE. */
  tipo: string;
  nombre: string;
  severidad: SeveridadAdvertencia;
  fechaHora: Date;
}

export interface UnidadAdvertencias {
  patente: string;
  advertencias: Advertencia[];
  /** Eventos de neumáticos / tacógrafo de las últimas 24 h (opcional). */
  eventos?: EventoMantenimiento[];
}

/**
 * Cobertura de testigos: cuántas unidades transmiten el bloque UPTIME (y por
 * ende podemos vigilarles el tablero) sobre el total operativo. CLAVE para no
 * darle a Emmanuel falsa tranquilidad: "4 con advertencias" sin aclarar que
 * sólo vemos 20/53 haría parecer sano a un camión que en realidad está mudo.
 */
export interface CoberturaFlota {
  monitoreadas: number;
  total: number;
}

const EMOJI_SEVERIDAD: Record<SeveridadAdvertencia, string> = {
  critico: "🔴",
  alto: "🟠",
  medio: "🟡",
  bajo: "⚪",
};

const RANK_SEVERIDAD: Record<SeveridadAdvertencia, number> = {
  critico: 0,
  alto: 1,
  medio: 2,
  bajo: 3,
};

/**
 * Eventos de VOLVO_ALERTAS que sumamos al Parte (presión/temp de neumático y
 * tacógrafo). Clave = tipo normalizado de la alerta. Neumáticos = alto (🟠),
 * tacógrafo = medio (🟡).
 */
const EVENTOS_MANT: Record<
  string,
  { nombre: string; severidad: SeveridadAdvertencia }
> = {
  TPM: { nombre: "Presión de neumático", severidad: "alto" },
  TTM: { nombre: "Temperatura de neumático", severidad: "alto" },
  TACHO_OUT_OF_SCOPE_MODE_CHANGE: {
    nombre: "Tacógrafo fuera de servicio",
    severidad: "medio",
  },
};

/**
 * Clasifica una alerta de VOLVO_ALERTAS como evento de mantenimiento.
 * Devuelve null si no es TPM / TTM / tacógrafo. Volvo manda el tipo directo
 * o como GENERIC con el subtipo en `detalle_generic.triggerType` / `.type`
 * (mismo criterio que usaba el cron del bot). PURO (testeable).
 */
export function clasificarEventoMant(
  tipo: unknown,
  detalleGeneric: unknown
): { tipo: string; nombre: string; severidad: SeveridadAdvertencia } | null {
  const t = String(tipo ?? "").trim().toUpperCase();
  if (EVENTOS_MANT[t]) return { tipo: t, ...EVENTOS_MANT[t] };
  if (t === "GENERIC") {
    const dg = (detalleGeneric ?? {}) as {
      triggerType?: unknown;
      type?: unknown;
    };
    const sub =
      String(dg.triggerType ?? "").trim().toUpperCase() ||
      String(dg.type ?? "").trim().toUpperCase();
    if (sub && EVENTOS_MANT[sub]) return { tipo: sub, ...EVENTOS_MANT[sub] };
  }
  return null;
}

/** Hora HH:MM en horario Argentina (para los eventos con timestamp). */
function fmtHoraArt(d: Date): string {
  return new Intl.DateTimeFormat("en-GB", {
    timeZone: "America/Argentina/Buenos_Aires",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(d);
}

/** Peor severidad de una unidad (entre testigos del tablero y eventos). */
function rankUnidad(u: UnidadAdvertencias): number {
  let best = 99;
  for (const a of u.advertencias) {
    best = Math.min(best, RANK_SEVERIDAD[a.severidad]);
  }
  for (const e of u.eventos ?? []) {
    best = Math.min(best, RANK_SEVERIDAD[e.severidad]);
  }
  return best;
}

/**
 * Arma el texto del parte de mantenimiento. PURO (testeable sin Firestore).
 * `unidades` debe traer SOLO unidades con ≥ 1 advertencia. Las ordena peor
 * primero. Si está vacío → mensaje "sin advertencias".
 */
export function construirParteMantenimiento(
  unidades: UnidadAdvertencias[],
  saludo: string,
  fmtFecha: string,
  cobertura?: CoberturaFlota
): string {
  // Nota de cobertura: si NO vemos todas las unidades, lo decimos explícito.
  let notaCobertura = "";
  if (cobertura && cobertura.total > 0) {
    const sinDatos = cobertura.total - cobertura.monitoreadas;
    if (sinDatos > 0) {
      notaCobertura =
        `\n_⚠️ Monitoreados ${cobertura.monitoreadas}/${cobertura.total} ` +
        `camiones. ${sinDatos} todavía no transmiten los testigos del tablero ` +
        "— no podemos ver su estado (hay que activarlo en Volvo)._\n";
    } else {
      notaCobertura =
        `\n_Monitoreados ${cobertura.monitoreadas}/${cobertura.total} ` +
        "camiones._\n";
    }
  }

  if (unidades.length === 0) {
    return (
      `${saludo},\n\n` +
      `🔧 *Parte de mantenimiento — ${fmtFecha}*\n\n` +
      "✅ Sin advertencias en los camiones monitoreados. Ninguno reporta " +
      "testigos en rojo o amarillo.\n" +
      notaCobertura +
      "\n" +
      BANNER_TESTING +
      "_Bot-On — Coopertrans Móvil_"
    );
  }

  const ordenadas = [...unidades].sort((a, b) => {
    const d = rankUnidad(a) - rankUnidad(b);
    return d !== 0 ? d : a.patente.localeCompare(b.patente, "es");
  });

  // Conteo de críticos para el encabezado.
  let criticos = 0;
  for (const u of ordenadas) {
    if (u.advertencias.some((a) => a.severidad === "critico")) criticos++;
  }

  const bloques = ordenadas.map((u) => {
    // Testigos del tablero (estado actual).
    const lineasAdv = u.advertencias.map(
      (a) => `   ${EMOJI_SEVERIDAD[a.severidad]} ${a.nombre}`
    );
    // Eventos de neumáticos / tacógrafo (24 h) condensados por tipo, con
    // horario: "🟠 2x Presión de neumático (14:23 / 17:08)".
    const porTipoEv = new Map<string, EventoMantenimiento[]>();
    for (const ev of u.eventos ?? []) {
      if (!porTipoEv.has(ev.tipo)) porTipoEv.set(ev.tipo, []);
      porTipoEv.get(ev.tipo)!.push(ev);
    }
    const lineasEv = [...porTipoEv.values()].map((evs) => {
      const horas = evs
        .map((e) => fmtHoraArt(e.fechaHora))
        .sort()
        .join(" / ");
      const prefijo = evs.length > 1 ? `${evs.length}x ` : "";
      return `   ${EMOJI_SEVERIDAD[evs[0].severidad]} ${prefijo}${evs[0].nombre} (${horas})`;
    });
    return `🚛 *${u.patente}*\n${[...lineasAdv, ...lineasEv].join("\n")}`;
  });

  const n = ordenadas.length;
  const sustantivo = n === 1 ? "camión" : "camiones";
  const encabezado =
    `${n} ${sustantivo} con advertencias` +
    (criticos > 0 ? ` (${criticos} con falla crítica 🔴)` : "");

  return (
    `${saludo},\n\n` +
    `🔧 *Parte de mantenimiento — ${fmtFecha}*\n\n` +
    `${encabezado}:\n\n` +
    bloques.join("\n\n") +
    "\n\n" +
    "_🔴 crítico · 🟠 importante · 🟡 medio · ⚪ menor. Testigos del tablero " +
    "(Volvo Connect); las líneas con horario son eventos de neumáticos / " +
    "tacógrafo de las últimas 24 h._\n" +
    notaCobertura +
    "\n" +
    BANNER_TESTING +
    "_Bot-On — Coopertrans Móvil_"
  );
}

export const resumenMantenimientoVehiculosDiario = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "America/Argentina/Buenos_Aires",
    timeoutSeconds: 120,
    memory: "256MiB",
  },
  async () => {
    logger.info("[resumenMantenimientoVehiculos] iniciando");

    const hoyKey = formatFechaArg(Date.now()).replace(/\//g, "-");
    const histRef = db
      .collection("AVISOS_AUTOMATICOS_HISTORICO")
      .doc(`mantenimiento_vehiculos_${hoyKey}`);
    if (
      !(await adquirirIdempotenciaDiaria(histRef, "mantenimiento_vehiculos"))
    ) {
      logger.info("[resumenMantenimientoVehiculos] ya enviado hoy, skip");
      return;
    }

    let exitoCron = false;
    try {
      // Skip combustibles líquidos (no es operativa Vecchi).
      const excluidos = await cargarExcluidos(db);

      const snap = await db.collection("VOLVO_ESTADO").limit(5000).get();
      // Map por patente (UPPER) para poder fusionar testigos del tablero
      // (VOLVO_ESTADO) con los eventos de neumáticos / tacógrafo (VOLVO_ALERTAS).
      const porPatente = new Map<string, UnidadAdvertencias>();
      let totalOperativas = 0;
      let monitoreadas = 0; // transmiten testigos (tienen tell_tales)
      for (const d of snap.docs) {
        const patente = d.id;
        const key = patente.toUpperCase();
        if (excluidos.patentes.has(key)) continue;
        totalOperativas++;
        const data = d.data();
        const tt = Array.isArray(data.tell_tales) ? data.tell_tales : [];
        if (tt.length > 0) monitoreadas++;
        const advertencias = clasificarAdvertencias(
          tt as Array<{ id: string; estado: string }>
        );
        if (advertencias.length > 0) {
          porPatente.set(key, { patente, advertencias });
        }
      }

      // Eventos de neumáticos / tacógrafo de las últimas 24 h. Hasta 2026-05-22
      // los reportaba el bot en un resumen aparte (origen cron_mantenimiento_diario)
      // que le llegaba DUPLICADO a Emmanuel con este Parte. Se unificaron acá: el
      // Parte ya traía los testigos del tablero; esto suma lo único que faltaba
      // (presión/temperatura de neumático y tacógrafo fuera de servicio).
      let totalEventos = 0;
      try {
        const desde24h = Timestamp.fromMillis(Date.now() - 24 * 60 * 60 * 1000);
        const alertasSnap = await db
          .collection("VOLVO_ALERTAS")
          .where("creado_en", ">=", desde24h)
          .get();
        for (const d of alertasSnap.docs) {
          const data = d.data();
          const patenteRaw = (data.patente ?? "").toString().trim();
          const key = patenteRaw.toUpperCase();
          if (!key || key === "—") continue;
          if (excluidos.patentes.has(key)) continue;
          const ev = clasificarEventoMant(data.tipo, data.detalle_generic);
          if (!ev) continue;
          const creadoEn = data.creado_en;
          const fechaHora =
            creadoEn && typeof creadoEn.toDate === "function"
              ? creadoEn.toDate()
              : new Date();
          const entry: UnidadAdvertencias =
            porPatente.get(key) ?? { patente: patenteRaw, advertencias: [] };
          if (!entry.eventos) entry.eventos = [];
          entry.eventos.push({ ...ev, fechaHora });
          porPatente.set(key, entry);
          totalEventos++;
        }
      } catch (e) {
        // Si la query de eventos falla, seguimos con los testigos del tablero
        // (mejor un Parte parcial que ninguno).
        logger.warn("[resumenMantenimientoVehiculos] eventos 24h fallaron", {
          error: (e as Error).message,
        });
      }

      const unidades: UnidadAdvertencias[] = [...porPatente.values()];

      // Destinatario (Emmanuel)
      const empSnap = await db
        .collection("EMPLEADOS")
        .doc(MANTENIMIENTO_VEHICULOS_DNI)
        .get();
      if (!empSnap.exists) {
        logger.error("[resumenMantenimientoVehiculos] destinatario no existe", {
          dni: MANTENIMIENTO_VEHICULOS_DNI,
        });
        return;
      }
      const empData = empSnap.data() ?? {};
      const tel = (empData.TELEFONO ?? "").toString().trim();
      if (!tel || tel === "-") {
        logger.error("[resumenMantenimientoVehiculos] destinatario sin TELEFONO");
        return;
      }
      const apodo = (empData.APODO ?? "").toString().trim();
      const nombreFull = (empData.NOMBRE ?? "").toString().trim();
      const saludoNombre = apodo || primerNombre(nombreFull) || "";
      const saludo = saludoNombre ? `Hola ${saludoNombre}` : "Hola";
      const fmtFecha = formatFechaArg(Date.now());

      const mensaje = construirParteMantenimiento(unidades, saludo, fmtFecha, {
        monitoreadas,
        total: totalOperativas,
      });

      await db.collection("COLA_WHATSAPP").add({
        telefono: tel,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(TTL_RESUMEN_DIARIO_MIN),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "resumen_mantenimiento_vehiculos",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: MANTENIMIENTO_VEHICULOS_DNI,
        campo_base: "MANTENIMIENTO",
        admin_dni: "BOT",
        admin_nombre: "Bot parte mantenimiento Volvo",
      });

      exitoCron = true;
      logger.info("[resumenMantenimientoVehiculos] OK", {
        unidadesReportadas: unidades.length,
        eventos24h: totalEventos,
        monitoreadas,
        totalOperativas,
        destinatario: MANTENIMIENTO_VEHICULOS_DNI,
      });
    } finally {
      if (!exitoCron) {
        // Liberar lock para reintentar en el próximo disparo.
        await histRef.delete().catch(() => undefined);
      }
    }
  }
);
