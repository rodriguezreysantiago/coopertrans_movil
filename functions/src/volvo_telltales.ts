/**
 * Diccionario de tell-tales (testigos del tablero) rFMS Volvo → español, con
 * clasificación de severidad para el parte de mantenimiento de Emmanuel (#43).
 *
 * PURO (sin I/O) → testeable. Lo usa el resumen diario (volvo_mantenimiento.ts)
 * y, espejado en Dart, la pantalla de la app.
 *
 * El equipo manda por unidad ~44 testigos con un `estado`:
 *   - RED            → falla seria (crítico).
 *   - YELLOW         → advertencia (según sistema: frenos/motor = alto; luces = bajo).
 *   - INFO           → estado informativo (freno de mano puesto, etc.) — NO es falla.
 *   - OFF / NOT_AVAILABLE / AVAILABLE → normal/no presente — se ignora.
 *
 * Para que el parte a Emmanuel sea ÚTIL y no ruidoso, sólo reportamos
 * advertencias reales (RED + YELLOW) y las priorizamos por sistema.
 */

export type CategoriaTellTale =
  | "frenos"
  | "motor"
  | "direccion"
  | "seguridad_activa"
  | "seguridad_pasiva"
  | "neumaticos"
  | "transmision"
  | "suspension"
  | "fluidos"
  | "electrico"
  | "luces"
  | "confort"
  | "mantenimiento"
  | "otros";

export type SeveridadAdvertencia = "critico" | "alto" | "medio" | "bajo";

export interface TellTaleDef {
  es: string;
  categoria: CategoriaTellTale;
}

/** ISO tellTale (rFMS) → nombre en español + sistema. */
export const TELLTALES: Record<string, TellTaleDef> = {
  // Frenos
  ABS_TRAILER: { es: "ABS del acoplado", categoria: "frenos" },
  EBS_TRAILER_1_2: { es: "EBS del acoplado", categoria: "frenos" },
  ANTI_LOCK_BRAKE_FAILURE: { es: "Falla de ABS", categoria: "frenos" },
  BRAKE_MALFUNCTION: { es: "Falla de frenos", categoria: "frenos" },
  EBS: { es: "Frenos electrónicos (EBS)", categoria: "frenos" },
  WORN_BRAKE_LININGS: { es: "Pastillas de freno gastadas", categoria: "frenos" },
  RETARDER: { es: "Retardador / freno motor", categoria: "frenos" },
  PARKING_BRAKE: { es: "Freno de mano", categoria: "frenos" },
  // Motor
  ENGINE_OIL: { es: "Aceite de motor", categoria: "motor" },
  ENGINE_OIL_LEVEL: { es: "Nivel de aceite de motor", categoria: "motor" },
  ENGINE_OIL_TEMPERATURE: { es: "Temperatura de aceite", categoria: "motor" },
  ENGINE_COOLANT_LEVEL: { es: "Nivel de refrigerante", categoria: "motor" },
  ENGINE_COOLANT_TEMPERATURE: {
    es: "Temperatura de refrigerante",
    categoria: "motor",
  },
  ENGINE_EMISSION_FAILURE: { es: "Falla de emisiones", categoria: "motor" },
  ENGINE_MIL_INDICATOR: { es: "Check engine (MIL)", categoria: "motor" },
  AIR_FILTER_CLOGGED: { es: "Filtro de aire tapado", categoria: "motor" },
  FUEL_FILTER_DIFF_PRESSURE: {
    es: "Filtro de combustible",
    categoria: "motor",
  },
  WATER_IN_FUEL: { es: "Agua en el combustible", categoria: "motor" },
  // Dirección
  STEERING_FAILURE: { es: "Falla de dirección", categoria: "direccion" },
  // Seguridad activa
  ADVANCED_EMERGENCY_BREAKING: {
    es: "Frenado de emergencia (AEBS)",
    categoria: "seguridad_activa",
  },
  ESC_INDICATOR: {
    es: "Control de estabilidad (ESC)",
    categoria: "seguridad_activa",
  },
  LANE_DEPARTURE_INDICATOR: {
    es: "Aviso de cambio de carril",
    categoria: "seguridad_activa",
  },
  ACC: { es: "Control crucero adaptativo (ACC)", categoria: "seguridad_activa" },
  // Seguridad pasiva
  AIRBAG: { es: "Airbag", categoria: "seguridad_pasiva" },
  SEAT_BELT: { es: "Cinturón de seguridad", categoria: "seguridad_pasiva" },
  // Neumáticos
  TIRE_MALFUNCTION: {
    es: "Presión / falla de neumáticos",
    categoria: "neumaticos",
  },
  // Transmisión
  TRANSMISSION_MALFUNCTION: {
    es: "Falla de transmisión",
    categoria: "transmision",
  },
  TRANSMISSION_FLUID_TEMPERATURE: {
    es: "Temperatura de aceite de caja",
    categoria: "transmision",
  },
  // Suspensión
  HEIGHT_CONTROL: { es: "Control de altura (suspensión)", categoria: "suspension" },
  // Fluidos
  FUEL_LEVEL: { es: "Nivel de combustible", categoria: "fluidos" },
  ADBLUE_LEVEL: { es: "Nivel de AdBlue", categoria: "fluidos" },
  WINDSCREEN_WASHER_FLUID: {
    es: "Líquido limpiaparabrisas",
    categoria: "fluidos",
  },
  // Eléctrico
  BATTERY_CHARGING_CONDITION: { es: "Carga de batería", categoria: "electrico" },
  // Luces
  LOW_BEAM_DIPPED_BEAM: { es: "Luz baja", categoria: "luces" },
  HIGH_BEAM_MAIN_BEAM: { es: "Luz alta", categoria: "luces" },
  FRONT_FOG_LIGHT: { es: "Antiniebla delantero", categoria: "luces" },
  REAR_FOG_LIGHT: { es: "Antiniebla trasero", categoria: "luces" },
  POSITION_LIGHTS: { es: "Luces de posición", categoria: "luces" },
  BRAKE_LIGHTS: { es: "Luces de freno", categoria: "luces" },
  TURN_SIGNALS: { es: "Giros / intermitentes", categoria: "luces" },
  HAZARD_WARNING: { es: "Balizas", categoria: "luces" },
  // Confort
  PARKING_HEATER: { es: "Calefactor estacionario", categoria: "confort" },
  // Mantenimiento
  SERVICE_CALL_FOR_MAINTENANCE: {
    es: "Service requerido",
    categoria: "mantenimiento",
  },
  // Otros
  TACHOGRAPH_INDICATOR: { es: "Tacógrafo", categoria: "otros" },
  TRAILER_CONNECTED: { es: "Acoplado conectado", categoria: "otros" },
  GENERAL_FAILURE: { es: "Falla general", categoria: "otros" },
};

/** Severidad base de un YELLOW según el sistema afectado. */
const YELLOW_POR_CATEGORIA: Record<CategoriaTellTale, SeveridadAdvertencia> = {
  frenos: "alto",
  motor: "alto",
  direccion: "alto",
  seguridad_activa: "alto",
  seguridad_pasiva: "alto",
  neumaticos: "alto",
  transmision: "alto",
  suspension: "medio",
  fluidos: "medio",
  electrico: "medio",
  mantenimiento: "medio",
  luces: "bajo",
  confort: "bajo",
  otros: "bajo",
};

const ORDEN_SEVERIDAD: Record<SeveridadAdvertencia, number> = {
  critico: 0,
  alto: 1,
  medio: 2,
  bajo: 3,
};

export interface Advertencia {
  id: string;
  nombre: string;
  categoria: CategoriaTellTale;
  estado: string; // RED | YELLOW
  severidad: SeveridadAdvertencia;
}

/** Nombre español del testigo; si es desconocido, humaniza el ID rFMS. */
export function nombreTellTale(id: string): string {
  const def = TELLTALES[id];
  if (def) return def.es;
  // Humaniza: ABS_TRAILER → "Abs trailer".
  const txt = id.replace(/_/g, " ").toLowerCase().trim();
  return txt.charAt(0).toUpperCase() + txt.slice(1);
}

/**
 * Clasifica UN testigo. Devuelve null si no es una advertencia accionable
 * (INFO, OFF, NOT_AVAILABLE, AVAILABLE, vacío → no se reporta a Emmanuel).
 */
export function clasificarAdvertencia(
  id: string,
  estado: string
): Advertencia | null {
  const e = (estado ?? "").toString().trim().toUpperCase();
  if (e !== "RED" && e !== "YELLOW") return null;
  const def = TELLTALES[id];
  const categoria: CategoriaTellTale = def ? def.categoria : "otros";
  const severidad: SeveridadAdvertencia =
    e === "RED" ? "critico" : YELLOW_POR_CATEGORIA[categoria];
  return {
    id,
    nombre: nombreTellTale(id),
    categoria,
    estado: e,
    severidad,
  };
}

/**
 * Convierte la lista cruda de tell-tales de una unidad en advertencias
 * accionables, ordenadas crítico → alto → medio → bajo (y alfabético dentro).
 */
export function clasificarAdvertencias(
  tellTales: Array<{ id: string; estado: string }>
): Advertencia[] {
  const out: Advertencia[] = [];
  for (const t of tellTales ?? []) {
    if (!t || !t.id) continue;
    const a = clasificarAdvertencia(t.id, t.estado);
    if (a) out.push(a);
  }
  out.sort((x, y) => {
    const d = ORDEN_SEVERIDAD[x.severidad] - ORDEN_SEVERIDAD[y.severidad];
    return d !== 0 ? d : x.nombre.localeCompare(y.nombre, "es");
  });
  return out;
}
