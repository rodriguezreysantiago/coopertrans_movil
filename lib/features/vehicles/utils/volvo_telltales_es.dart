// Diccionario de tell-tales (testigos del tablero) rFMS Volvo → español, con
// clasificación de severidad. Espejo Dart de `functions/src/volvo_telltales.ts`
// (el del parte de mantenimiento de Emmanuel) para la pantalla de mantenimiento.
//
// El equipo manda por unidad ~44 testigos con un `estado`:
//   RED → falla seria · YELLOW → advertencia · INFO/OFF/NOT_AVAILABLE → normal.
// Para que la pantalla no sea ruidosa, sólo mostramos advertencias reales
// (RED + YELLOW) priorizadas por sistema.

enum SeveridadAdvertencia { critico, alto, medio, bajo }

class _DefTellTale {
  final String es;
  final String categoria;
  const _DefTellTale(this.es, this.categoria);
}

/// ISO tellTale (rFMS) → nombre en español + sistema.
const Map<String, _DefTellTale> _telltales = {
  // Frenos
  'ABS_TRAILER': _DefTellTale('ABS del acoplado', 'frenos'),
  'EBS_TRAILER_1_2': _DefTellTale('EBS del acoplado', 'frenos'),
  'ANTI_LOCK_BRAKE_FAILURE': _DefTellTale('Falla de ABS', 'frenos'),
  'BRAKE_MALFUNCTION': _DefTellTale('Falla de frenos', 'frenos'),
  'EBS': _DefTellTale('Frenos electrónicos (EBS)', 'frenos'),
  'WORN_BRAKE_LININGS': _DefTellTale('Pastillas de freno gastadas', 'frenos'),
  'RETARDER': _DefTellTale('Retardador / freno motor', 'frenos'),
  'PARKING_BRAKE': _DefTellTale('Freno de mano', 'frenos'),
  // Motor
  'ENGINE_OIL': _DefTellTale('Aceite de motor', 'motor'),
  'ENGINE_OIL_LEVEL': _DefTellTale('Nivel de aceite de motor', 'motor'),
  'ENGINE_OIL_TEMPERATURE': _DefTellTale('Temperatura de aceite', 'motor'),
  'ENGINE_COOLANT_LEVEL': _DefTellTale('Nivel de refrigerante', 'motor'),
  'ENGINE_COOLANT_TEMPERATURE':
      _DefTellTale('Temperatura de refrigerante', 'motor'),
  'ENGINE_EMISSION_FAILURE': _DefTellTale('Falla de emisiones', 'motor'),
  'ENGINE_MIL_INDICATOR': _DefTellTale('Check engine (MIL)', 'motor'),
  'AIR_FILTER_CLOGGED': _DefTellTale('Filtro de aire tapado', 'motor'),
  'FUEL_FILTER_DIFF_PRESSURE': _DefTellTale('Filtro de combustible', 'motor'),
  'WATER_IN_FUEL': _DefTellTale('Agua en el combustible', 'motor'),
  // Dirección
  'STEERING_FAILURE': _DefTellTale('Falla de dirección', 'direccion'),
  // Seguridad activa
  'ADVANCED_EMERGENCY_BREAKING':
      _DefTellTale('Frenado de emergencia (AEBS)', 'seguridad_activa'),
  'ESC_INDICATOR':
      _DefTellTale('Control de estabilidad (ESC)', 'seguridad_activa'),
  'LANE_DEPARTURE_INDICATOR':
      _DefTellTale('Aviso de cambio de carril', 'seguridad_activa'),
  'ACC': _DefTellTale('Control crucero adaptativo (ACC)', 'seguridad_activa'),
  // Seguridad pasiva
  'AIRBAG': _DefTellTale('Airbag', 'seguridad_pasiva'),
  'SEAT_BELT': _DefTellTale('Cinturón de seguridad', 'seguridad_pasiva'),
  // Neumáticos
  'TIRE_MALFUNCTION': _DefTellTale('Presión / falla de neumáticos', 'neumaticos'),
  // Transmisión
  'TRANSMISSION_MALFUNCTION':
      _DefTellTale('Falla de transmisión', 'transmision'),
  'TRANSMISSION_FLUID_TEMPERATURE':
      _DefTellTale('Temperatura de aceite de caja', 'transmision'),
  // Suspensión
  'HEIGHT_CONTROL':
      _DefTellTale('Control de altura (suspensión)', 'suspension'),
  // Fluidos
  'FUEL_LEVEL': _DefTellTale('Nivel de combustible', 'fluidos'),
  'ADBLUE_LEVEL': _DefTellTale('Nivel de AdBlue', 'fluidos'),
  'WINDSCREEN_WASHER_FLUID':
      _DefTellTale('Líquido limpiaparabrisas', 'fluidos'),
  // Eléctrico
  'BATTERY_CHARGING_CONDITION': _DefTellTale('Carga de batería', 'electrico'),
  // Luces
  'LOW_BEAM_DIPPED_BEAM': _DefTellTale('Luz baja', 'luces'),
  'HIGH_BEAM_MAIN_BEAM': _DefTellTale('Luz alta', 'luces'),
  'FRONT_FOG_LIGHT': _DefTellTale('Antiniebla delantero', 'luces'),
  'REAR_FOG_LIGHT': _DefTellTale('Antiniebla trasero', 'luces'),
  'POSITION_LIGHTS': _DefTellTale('Luces de posición', 'luces'),
  'BRAKE_LIGHTS': _DefTellTale('Luces de freno', 'luces'),
  'TURN_SIGNALS': _DefTellTale('Giros / intermitentes', 'luces'),
  'HAZARD_WARNING': _DefTellTale('Balizas', 'luces'),
  // Confort
  'PARKING_HEATER': _DefTellTale('Calefactor estacionario', 'confort'),
  // Mantenimiento
  'SERVICE_CALL_FOR_MAINTENANCE':
      _DefTellTale('Service requerido', 'mantenimiento'),
  // Otros
  'TACHOGRAPH_INDICATOR': _DefTellTale('Tacógrafo', 'otros'),
  'TRAILER_CONNECTED': _DefTellTale('Acoplado conectado', 'otros'),
  'GENERAL_FAILURE': _DefTellTale('Falla general', 'otros'),
};

/// Severidad base de un YELLOW según el sistema afectado.
const Map<String, SeveridadAdvertencia> _yellowPorCategoria = {
  'frenos': SeveridadAdvertencia.alto,
  'motor': SeveridadAdvertencia.alto,
  'direccion': SeveridadAdvertencia.alto,
  'seguridad_activa': SeveridadAdvertencia.alto,
  'seguridad_pasiva': SeveridadAdvertencia.alto,
  'neumaticos': SeveridadAdvertencia.alto,
  'transmision': SeveridadAdvertencia.alto,
  'suspension': SeveridadAdvertencia.medio,
  'fluidos': SeveridadAdvertencia.medio,
  'electrico': SeveridadAdvertencia.medio,
  'mantenimiento': SeveridadAdvertencia.medio,
  'luces': SeveridadAdvertencia.bajo,
  'confort': SeveridadAdvertencia.bajo,
  'otros': SeveridadAdvertencia.bajo,
};

const Map<SeveridadAdvertencia, int> _ordenSeveridad = {
  SeveridadAdvertencia.critico: 0,
  SeveridadAdvertencia.alto: 1,
  SeveridadAdvertencia.medio: 2,
  SeveridadAdvertencia.bajo: 3,
};

class Advertencia {
  final String id;
  final String nombre;
  final String categoria;
  final String estado; // RED | YELLOW
  final SeveridadAdvertencia severidad;
  const Advertencia({
    required this.id,
    required this.nombre,
    required this.categoria,
    required this.estado,
    required this.severidad,
  });
}

/// Nombre español del testigo; si es desconocido, humaniza el ID rFMS.
String nombreTellTale(String id) {
  final def = _telltales[id];
  if (def != null) return def.es;
  final txt = id.replaceAll('_', ' ').toLowerCase().trim();
  if (txt.isEmpty) return id;
  return txt[0].toUpperCase() + txt.substring(1);
}

/// Clasifica UN testigo. null si no es advertencia accionable (INFO/OFF/etc).
Advertencia? clasificarAdvertencia(String id, String estado) {
  final e = estado.trim().toUpperCase();
  if (e != 'RED' && e != 'YELLOW') return null;
  final def = _telltales[id];
  final categoria = def?.categoria ?? 'otros';
  final severidad = e == 'RED'
      ? SeveridadAdvertencia.critico
      : (_yellowPorCategoria[categoria] ?? SeveridadAdvertencia.bajo);
  return Advertencia(
    id: id,
    nombre: nombreTellTale(id),
    categoria: categoria,
    estado: e,
    severidad: severidad,
  );
}

/// De la lista cruda de tell_tales (de VOLVO_ESTADO) → advertencias accionables,
/// ordenadas crítico → alto → medio → bajo.
List<Advertencia> clasificarAdvertencias(List<dynamic>? tellTales) {
  final out = <Advertencia>[];
  for (final t in tellTales ?? const []) {
    if (t is! Map) continue;
    final id = (t['id'] ?? '').toString();
    if (id.isEmpty) continue;
    final a = clasificarAdvertencia(id, (t['estado'] ?? '').toString());
    if (a != null) out.add(a);
  }
  out.sort((x, y) {
    final d = (_ordenSeveridad[x.severidad] ?? 9) -
        (_ordenSeveridad[y.severidad] ?? 9);
    return d != 0 ? d : x.nombre.compareTo(y.nombre);
  });
  return out;
}

/// Color para la severidad (lo usa la UI). Se mantiene fuera del enum para no
/// acoplar este util a Material; la pantalla mapea con su paleta.
int severidadOrden(SeveridadAdvertencia s) => _ordenSeveridad[s] ?? 9;
