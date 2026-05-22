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
import { FieldValue } from "firebase-admin/firestore";

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

export interface UnidadAdvertencias {
  patente: string;
  advertencias: Advertencia[];
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

/** Peor severidad de una unidad (las advertencias ya vienen ordenadas). */
function rankUnidad(u: UnidadAdvertencias): number {
  if (u.advertencias.length === 0) return 99;
  return RANK_SEVERIDAD[u.advertencias[0].severidad];
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
    const lineas = u.advertencias
      .map((a) => `   ${EMOJI_SEVERIDAD[a.severidad]} ${a.nombre}`)
      .join("\n");
    return `🚛 *${u.patente}*\n${lineas}`;
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
    "_🔴 crítico · 🟠 importante · 🟡 medio · ⚪ menor. Testigos exactos del " +
    "tablero del camión (Volvo Connect)._\n" +
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
      const unidades: UnidadAdvertencias[] = [];
      let totalOperativas = 0;
      let monitoreadas = 0; // transmiten testigos (tienen tell_tales)
      for (const d of snap.docs) {
        const patente = d.id;
        if (excluidos.patentes.has(patente.toUpperCase())) continue;
        totalOperativas++;
        const data = d.data();
        const tt = Array.isArray(data.tell_tales) ? data.tell_tales : [];
        if (tt.length > 0) monitoreadas++;
        const advertencias = clasificarAdvertencias(
          tt as Array<{ id: string; estado: string }>
        );
        if (advertencias.length > 0) unidades.push({ patente, advertencias });
      }

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
        unidadesConAdvertencias: unidades.length,
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
