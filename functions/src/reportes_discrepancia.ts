// =============================================================================
// REPORTES_DISCREPANCIA — devolución por WhatsApp al chofer cuando se resuelve
// =============================================================================
// Cuando un reclamo del chofer (REPORTES_DISCREPANCIA, creado por la tool
// `reportar_discrepancia` del bot) pasa a "revisado" con veredicto, le mandamos
// al chofer una devolución por WhatsApp CITANDO su reclamo + el resultado: le
// dimos la razón (`cierto`) o el dato del sistema estaba bien (`no_cierto`).
// Cierra el loop — antes el chofer reclamaba y nunca recibía una respuesta.
// Pedido Santiago 2026-06-11.
//
// Dispara para los DOS caminos de cierre: la app ("Reportes de choferes" →
// marcarRevisado) y el script `cerrar_reportes_resueltos_por_v3.js`. Idempotente
// por docId determinístico en COLA_WHATSAPP (robusto al at-least-once de los
// triggers Firestore).
//
// Alcance V1 (decisión Santiago): SOLO reclamos DIRECTOS del chofer. Los
// auto-generados de paradas (origen=parada_reportada_auto) tienen un detalle
// técnico no citable como "su reclamo" → quedan fuera por ahora.

import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import { FieldValue } from "firebase-admin/firestore";

import { db, BANNER_TESTING } from "./setup";
import { expiraEnMin, primerNombre } from "./helpers";

/** Subset del doc REPORTES_DISCREPANCIA que mira la lógica de devolución. */
export interface ReporteLite {
  estado?: string;
  veredicto?: string;
  origen?: string;
  detalle?: string;
  chofer_dni?: string;
}

/**
 * ¿Esta transición debe disparar la devolución al chofer? True solo cuando el
 * reporte queda RESUELTO recién ahora (o cambia el veredicto tras una reapertura)
 * y es un reclamo DIRECTO con detalle citable. Falso para los auto-generados de
 * paradas y para updates que no cambian el estado de resolución (ej. editar una
 * nota de un ya-revisado con el mismo veredicto).
 */
export function debeEnviarDevolucion(
  before: ReporteLite | undefined,
  after: ReporteLite | undefined
): boolean {
  if (!after) return false;
  const v = (after.veredicto ?? "").toString();
  const resuelto =
    after.estado === "revisado" && (v === "cierto" || v === "no_cierto");
  if (!resuelto) return false;
  if (after.origen === "parada_reportada_auto") return false; // no citable
  if (!(after.chofer_dni ?? "").toString().trim()) return false;
  if (!(after.detalle ?? "").toString().trim()) return false;
  const antesV = (before?.veredicto ?? "").toString();
  // Recién resuelto (antes no estaba revisado) o el veredicto cambió.
  return before?.estado !== "revisado" || antesV !== v;
}

/** Arma el texto de la devolución (vos rioplatense, cita el reclamo). Puro. */
export function construirMensajeDevolucion(p: {
  saludoNombre: string;
  detalle: string;
  veredicto: string;
  nota: string;
  fechaRec: string;
}): string {
  const saludo = p.saludoNombre ? `Hola ${p.saludoNombre}` : "Hola";
  const cuerpo =
    p.veredicto === "cierto"
      ? `✅ Tenías razón. ${p.nota || "Lo verificamos y quedó tenido en cuenta."}`
      : "Lo cruzamos con el sistema/GPS y el dato figura correcto." +
        (p.nota ? " " + p.nota : "");
  const cierre =
    p.veredicto === "cierto"
      ? "Gracias por avisar."
      : "Igual gracias por avisar — ante cualquier duda escribinos.";
  return (
    `${saludo}, revisamos tu reclamo${p.fechaRec ? ` del ${p.fechaRec}` : ""}:\n\n` +
    `_"${p.detalle}"_\n\n` +
    `${cuerpo}\n\n` +
    `${cierre}\n\n` +
    BANNER_TESTING +
    "_Bot-On — Coopertrans Móvil_"
  );
}

/** DD/MM ART de un Timestamp Firestore (o "" si no es válido). */
function fechaDdMmArt(ts: unknown): string {
  const d =
    ts && typeof (ts as { toDate?: () => Date }).toDate === "function"
      ? (ts as { toDate: () => Date }).toDate()
      : null;
  if (!d) return "";
  return d.toLocaleDateString("es-AR", {
    timeZone: "America/Argentina/Buenos_Aires",
    day: "2-digit",
    month: "2-digit",
  });
}

export const onReporteDiscrepanciaRevisado = onDocumentUpdated(
  "REPORTES_DISCREPANCIA/{id}",
  async (event) => {
    const before = event.data?.before.data();
    const after = event.data?.after.data();
    if (!debeEnviarDevolucion(before, after)) return;
    const a = after as Record<string, unknown>;

    const reporteId = event.params.id;
    const choferDni = (a.chofer_dni ?? "").toString().trim();
    const veredicto = (a.veredicto ?? "").toString();

    const empSnap = await db.collection("EMPLEADOS").doc(choferDni).get();
    if (!empSnap.exists) {
      logger.warn("[devolucionReporte] EMPLEADOS no existe", { choferDni, reporteId });
      return;
    }
    const emp = empSnap.data() ?? {};
    if (emp.ACTIVO === false) {
      logger.info("[devolucionReporte] chofer inactivo, no aviso", { choferDni, reporteId });
      return;
    }
    const tel = (emp.TELEFONO ?? "").toString().trim();
    if (!tel || tel === "-") {
      logger.warn("[devolucionReporte] chofer sin TELEFONO", { choferDni, reporteId });
      return;
    }
    const saludoNombre =
      (emp.APODO ?? "").toString().trim() ||
      primerNombre((emp.NOMBRE ?? "").toString().trim());

    const mensaje = construirMensajeDevolucion({
      saludoNombre,
      detalle: (a.detalle ?? "").toString().trim(),
      veredicto,
      nota: (a.nota_revision ?? "").toString().trim(),
      fechaRec: fechaDdMmArt(a.creado_en),
    });

    // Idempotencia robusta al at-least-once de los triggers: docId determinístico
    // (reporte + veredicto). create() falla con ALREADY_EXISTS si ya se encoló →
    // el chofer recibe la devolución UNA sola vez por veredicto.
    const colaId = `devolucion__${reporteId}__${veredicto}`;
    try {
      await db.collection("COLA_WHATSAPP").doc(colaId).create({
        telefono: tel,
        mensaje,
        estado: "PENDIENTE",
        encolado_en: FieldValue.serverTimestamp(),
        expira_en: expiraEnMin(180),
        enviado_en: null,
        error: null,
        intentos: 0,
        origen: "devolucion_reporte",
        destinatario_coleccion: "EMPLEADOS",
        destinatario_id: choferDni,
        campo_base: "REPORTE_DEVOLUCION",
        admin_dni: "BOT",
        admin_nombre: "Bot devolución de reportes",
        reporte_id: reporteId,
      });
      logger.info("[devolucionReporte] encolada", { reporteId, choferDni, veredicto });
    } catch (e) {
      const err = e as { code?: number; message?: string };
      if (err.code === 6 || /ALREADY_EXISTS/i.test(String(err.message))) {
        logger.info("[devolucionReporte] ya encolada (idempotente)", { reporteId, veredicto });
        return;
      }
      throw e;
    }
  }
);
