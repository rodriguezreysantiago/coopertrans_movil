// =============================================================================
// IcmOficialService — lee el ICM OFICIAL de Sitrack (lo que audita YPF)
// =============================================================================
//
// Fuente: doc `ICM_OFICIAL/{YYYY-MM}` que escribe el scraper `sitrack_sync/
// sync_icm.py` (corre 1 vez al día en la PC dedicada e ingiere el ranking
// del portal site5 de Sitrack). Ese es EL número que YPF mira en su tablero
// ICM — lo calcula Sitrack con su cartografía de segmento vial (urbano /
// no-urbano), dato que nosotros NO tenemos.
//
// ⚠ ESCALA AL REVÉS del CESVI 0-100 que teníamos: acá **MÁS BAJO = MEJOR**
// (0 = sin infracciones; la flota Vecchi ronda ~20; un chofer malo supera
// 50). La severidad la da Sitrack directamente (NO / LOW / MEDIUM / HIGH /
// UNAVAILABLE_NO_ACTIVITY) — la usamos tal cual para colorear, sin inventar
// umbrales propios.
//
// Por eso este módulo REEMPLAZA, en lo que ve el humano (ranking, detalle,
// reporte, card de inicio), al cálculo CESVI interno (`icm_calculator.dart`).
// El CESVI sigue vivo SOLO para el resumen semanal a Molina (cron
// `recomputeIcmSemanalScheduled` → `ICM_SEMANAL`) y el Excel — son otro
// canal. Acá mostramos el oficial.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Severidad oficial de Sitrack, normalizada a un enum. Orden semántico
/// peor→mejor: alto, medio, bajo, sinInfracciones; sinActividad/desconocida
/// quedan aparte (no entran al ranking de performance).
enum SeveridadIcm { alto, medio, bajo, sinInfracciones, sinActividad, desconocida }

/// Mapea el string crudo de Sitrack (`severidad`) al enum.
SeveridadIcm severidadIcmDesde(String raw) {
  switch (raw.trim().toUpperCase()) {
    case 'HIGH':
      return SeveridadIcm.alto;
    case 'MEDIUM':
      return SeveridadIcm.medio;
    case 'LOW':
      return SeveridadIcm.bajo;
    case 'NO':
      return SeveridadIcm.sinInfracciones;
    case 'UNAVAILABLE_NO_ACTIVITY':
      return SeveridadIcm.sinActividad;
    default:
      return SeveridadIcm.desconocida;
  }
}

/// Color de un row según la severidad oficial de Sitrack. Mapeo de 3
/// colores + gris: sin/bajas infracciones → verde, medio → ámbar, alto →
/// rojo, sin actividad / desconocida → gris azulado.
Color colorSeveridadIcm(String severidadRaw) {
  switch (severidadIcmDesde(severidadRaw)) {
    case SeveridadIcm.sinInfracciones:
    case SeveridadIcm.bajo:
      return Colors.green.shade600;
    case SeveridadIcm.medio:
      return Colors.amber.shade700;
    case SeveridadIcm.alto:
      return Colors.red.shade600;
    case SeveridadIcm.sinActividad:
    case SeveridadIcm.desconocida:
      return Colors.blueGrey.shade600;
  }
}

double _d(dynamic v) => (v is num) ? v.toDouble() : 0.0;
int _i(dynamic v) => (v is num) ? v.toInt() : 0;
String _s(dynamic v) => (v ?? '').toString().trim();

/// Una infracción individual del chofer en el período (1 fila del modal
/// "Detalle de infracciones" de Sitrack). Las trae el scraper Python con
/// `get_infractions(scopeId)` y se persisten embebidas en cada chofer del
/// doc `ICM_OFICIAL/{periodo}` (campo `infracciones[]`).
class InfraccionIndividual {
  /// Patente del tractor al momento de la infracción (útil si hubo
  /// reasignación durante el período).
  final String patente;

  /// Tipo legible: "Frenada Brusca Grave", "Giro Brusco Leve",
  /// "Conducción Continua...".
  final String infraccion;

  /// Código corto Sitrack: 'sbg' = stop bruto grave, 'htl' = harsh turn
  /// light, etc. Sirve para agrupar/filtrar.
  final String tipo;

  /// Timestamp con hora "2026-05-18 17:01:38" (string crudo de Sitrack).
  final String fecha;

  /// Texto legible de ubicación (calle + referencia + localidad).
  final String ubicacion;

  final double? latitud;
  final double? longitud;

  /// Velocidad permitida según cartografía Sitrack (km/h, opcional).
  final double? velLimite;

  /// Pico de velocidad del momento (km/h, opcional).
  final double? velMaxima;

  /// Duración legible "04:23:27" — sólo para "Conducción Continua" o
  /// similar, null en eventos puntuales.
  final String? tiempo;

  /// Puntaje individual con el que sumó al ICM (10.00 para grave,
  /// 5.00 para media, 2.35 para conducción continua, etc.).
  final double puntaje;

  const InfraccionIndividual({
    required this.patente,
    required this.infraccion,
    required this.tipo,
    required this.fecha,
    required this.ubicacion,
    this.latitud,
    this.longitud,
    this.velLimite,
    this.velMaxima,
    this.tiempo,
    required this.puntaje,
  });

  factory InfraccionIndividual.fromMap(Map<String, dynamic> m) {
    double? nz(dynamic v) {
      if (v is! num) return null;
      final d = v.toDouble();
      return d == 0.0 ? null : d;
    }
    return InfraccionIndividual(
      patente: _s(m['patente']),
      infraccion: _s(m['infraccion']),
      tipo: _s(m['tipo']),
      fecha: _s(m['fecha']),
      ubicacion: _s(m['ubicacion']),
      latitud: nz(m['latitud']),
      longitud: nz(m['longitud']),
      velLimite: nz(m['vel_limite']),
      velMaxima: nz(m['vel_maxima']),
      tiempo: (m['tiempo'] is String && (m['tiempo'] as String).isNotEmpty)
          ? m['tiempo']
          : null,
      puntaje: _d(m['puntaje']),
    );
  }

  /// `true` si tenemos vel_limite + vel_maxima y hay exceso real.
  bool get esExcesoVelocidad =>
      velLimite != null && velMaxima != null && velMaxima! > velLimite! + 1.0;
}

/// Un hotspot del mapa de calor (1 ubicación cartográfica única con N
/// infracciones acumuladas). Lo trae get_top_infractions agregado por
/// Sitrack. Para el mapa de calor + lista lateral.
class HotspotInfraccion {
  final String infraccion;
  final String tipo;
  final String ubicacion;
  final double latitud;
  final double longitud;
  /// Cantidad de infracciones acumuladas en esa ubicación cartográfica.
  final int cantidad;
  /// Porcentaje del total de infracciones de la flota.
  final double porcentaje;
  /// Cuánto suma al ICM cada ocurrencia.
  final double puntaje;

  const HotspotInfraccion({
    required this.infraccion,
    required this.tipo,
    required this.ubicacion,
    required this.latitud,
    required this.longitud,
    required this.cantidad,
    required this.porcentaje,
    required this.puntaje,
  });

  factory HotspotInfraccion.fromMap(Map<String, dynamic> m) {
    return HotspotInfraccion(
      infraccion: _s(m['infraccion']),
      tipo: _s(m['tipo']),
      ubicacion: _s(m['ubicacion']),
      latitud: _d(m['latitud']),
      longitud: _d(m['longitud']),
      cantidad: _i(m['cantidad']),
      porcentaje: _d(m['porcentaje']),
      puntaje: _d(m['puntaje']),
    );
  }
}

/// Un chofer en el ICM oficial de un período.
class IcmOficialChofer {
  final String dni;
  final String nombre;
  final double icm; // MÁS BAJO = MEJOR
  final double icmUrbano;
  final double icmNoUrbano;
  final double distanciaKm;
  final double tiempoH;
  final int infLeves;
  final int infMedias;
  final int infAltas;
  final int excesosVelocidad;
  final int conduccionAgresiva;
  final String severidad; // crudo Sitrack
  final String severidadLabel; // ES (viene del doc)
  /// scopeId de Sitrack — clave estable del chofer (el `dni` a veces viene
  /// vacío). Es el id del doc en la subcolección `infracciones_chofer/{scopeId}`.
  final int scopeId;
  /// Infracciones individuales del chofer en el período (capeado a 100 por
  /// el scraper). Desde 2026-06-13 viven en la subcolección
  /// `infracciones_chofer/{scopeId}` (hardening 1 MiB) y este campo viene VACÍO
  /// en docs nuevos → usar `IcmOficialService.cargarInfraccionesChofer`. Los
  /// docs viejos (pre-2026-06-13) las traen acá embebidas (fallback).
  final List<InfraccionIndividual> infracciones;

  const IcmOficialChofer({
    required this.dni,
    required this.nombre,
    required this.icm,
    required this.icmUrbano,
    required this.icmNoUrbano,
    required this.distanciaKm,
    required this.tiempoH,
    required this.infLeves,
    required this.infMedias,
    required this.infAltas,
    required this.excesosVelocidad,
    required this.conduccionAgresiva,
    required this.severidad,
    required this.severidadLabel,
    this.scopeId = 0,
    this.infracciones = const [],
  });

  factory IcmOficialChofer.fromMap(Map<String, dynamic> m) {
    final rawInfrac = (m['infracciones'] as List?) ?? const [];
    return IcmOficialChofer(
      dni: _s(m['dni']),
      nombre: _s(m['nombre']),
      scopeId: _i(m['scope_id']),
      icm: _d(m['icm']),
      icmUrbano: _d(m['icm_urbano']),
      icmNoUrbano: _d(m['icm_no_urbano']),
      distanciaKm: _d(m['distancia_km']),
      tiempoH: _d(m['tiempo_h']),
      infLeves: _i(m['inf_leves']),
      infMedias: _i(m['inf_medias']),
      infAltas: _i(m['inf_altas']),
      excesosVelocidad: _i(m['excesos_velocidad']),
      conduccionAgresiva: _i(m['conduccion_agresiva']),
      severidad: _s(m['severidad']),
      severidadLabel: _s(m['severidad_label']),
      infracciones: rawInfrac
          .whereType<Map>()
          .map((e) => InfraccionIndividual.fromMap(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  SeveridadIcm get severidadEnum => severidadIcmDesde(severidad);

  /// Sin actividad en el período (Sitrack no tiene recorrido para evaluar).
  bool get sinActividad => severidadEnum == SeveridadIcm.sinActividad;

  /// Drill-down posible solo si hay DNI real (las unidades-sin-chofer de
  /// Sitrack vienen con dni vacío).
  bool get tieneDni => dni.isNotEmpty;

  int get totalInfracciones => infLeves + infMedias + infAltas;
}

/// Un vehículo en el ICM oficial de un período (scopeHolder). Mismo número
/// que el chofer que la manejó, pero atribuido a la patente.
class IcmOficialVehiculo {
  final String patente;
  final double icm;
  final double icmUrbano;
  final double icmNoUrbano;
  final double distanciaKm;
  final double tiempoH;
  final int infLeves;
  final int infMedias;
  final int infAltas;
  final String severidad;
  final String severidadLabel;

  const IcmOficialVehiculo({
    required this.patente,
    required this.icm,
    required this.icmUrbano,
    required this.icmNoUrbano,
    required this.distanciaKm,
    required this.tiempoH,
    required this.infLeves,
    required this.infMedias,
    required this.infAltas,
    required this.severidad,
    required this.severidadLabel,
  });

  factory IcmOficialVehiculo.fromMap(Map<String, dynamic> m) {
    return IcmOficialVehiculo(
      patente: _s(m['patente']),
      icm: _d(m['icm']),
      icmUrbano: _d(m['icm_urbano']),
      icmNoUrbano: _d(m['icm_no_urbano']),
      distanciaKm: _d(m['distancia_km']),
      tiempoH: _d(m['tiempo_h']),
      infLeves: _i(m['inf_leves']),
      infMedias: _i(m['inf_medias']),
      infAltas: _i(m['inf_altas']),
      severidad: _s(m['severidad']),
      severidadLabel: _s(m['severidad_label']),
    );
  }

  SeveridadIcm get severidadEnum => severidadIcmDesde(severidad);
  bool get sinActividad => severidadEnum == SeveridadIcm.sinActividad;
  int get totalInfracciones => infLeves + infMedias + infAltas;
}

/// Snapshot del ICM oficial de un período (mes). Mapea 1:1 el doc
/// `ICM_OFICIAL/{YYYY-MM}`.
class IcmOficialPeriodo {
  final String periodo; // 'YYYY-MM'
  final String alcance;
  final String fechaDesde;
  final String fechaHasta;
  final double icmGeneral; // flota — MÁS BAJO = MEJOR
  final double distanciaTotalKm;
  final double tiempoTotalH;
  final int infraccionesLeves;
  final int infraccionesMedias;
  final int infraccionesAltas;
  final int choferesTotal;
  final int choferesActivos;

  /// Todos los choferes, en el orden que vienen del doc (peor→mejor por
  /// severidad). Incluye los "sin actividad" al final.
  final List<IcmOficialChofer> choferes;
  final List<IcmOficialVehiculo> vehiculos;
  final DateTime? sincronizadoEn;

  /// Hotspots del mapa de calor (agrupados por ubicación cartográfica
  /// única). Vacío en docs cargados antes del cambio 2026-05-23.
  final List<HotspotInfraccion> infraccionesHeatmap;

  const IcmOficialPeriodo({
    required this.periodo,
    required this.alcance,
    required this.fechaDesde,
    required this.fechaHasta,
    required this.icmGeneral,
    required this.distanciaTotalKm,
    required this.tiempoTotalH,
    required this.infraccionesLeves,
    required this.infraccionesMedias,
    required this.infraccionesAltas,
    required this.choferesTotal,
    required this.choferesActivos,
    required this.choferes,
    required this.vehiculos,
    required this.sincronizadoEn,
    this.infraccionesHeatmap = const [],
  });

  /// Construye desde el map de Firestore. `excluir` filtra choferes/vehículos
  /// por DNI/patente (tanqueros + testers) — los conteos de cabecera
  /// (icm_general, activos, etc.) se dejan TAL CUAL los reporta Sitrack
  /// porque ESE es el número auditado por YPF.
  factory IcmOficialPeriodo.fromMap(
    Map<String, dynamic> m, {
    bool Function(String dni)? excluirDni,
    bool Function(String patente)? excluirPatente,
  }) {
    final choferesRaw = (m['choferes'] as List?) ?? const [];
    final vehiculosRaw = (m['vehiculos'] as List?) ?? const [];
    var choferes = choferesRaw
        .whereType<Map>()
        .map((e) => IcmOficialChofer.fromMap(e.cast<String, dynamic>()))
        .toList();
    var vehiculos = vehiculosRaw
        .whereType<Map>()
        .map((e) => IcmOficialVehiculo.fromMap(e.cast<String, dynamic>()))
        .toList();
    if (excluirDni != null) {
      choferes = choferes
          .where((c) => c.dni.isEmpty || !excluirDni(c.dni))
          .toList();
    }
    if (excluirPatente != null) {
      vehiculos =
          vehiculos.where((v) => !excluirPatente(v.patente)).toList();
    }
    DateTime? sinc;
    final ts = m['sincronizado_en'];
    if (ts is Timestamp) sinc = ts.toDate();
    final hotspots = ((m['infracciones_heatmap'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => HotspotInfraccion.fromMap(e.cast<String, dynamic>()))
        .toList();
    return IcmOficialPeriodo(
      periodo: _s(m['periodo']),
      alcance: _s(m['alcance']),
      fechaDesde: _s(m['fecha_desde']),
      fechaHasta: _s(m['fecha_hasta']),
      icmGeneral: _d(m['icm_general']),
      distanciaTotalKm: _d(m['distancia_total_km']),
      tiempoTotalH: _d(m['tiempo_total_h']),
      infraccionesLeves: _i(m['infracciones_leves']),
      infraccionesMedias: _i(m['infracciones_medias']),
      infraccionesAltas: _i(m['infracciones_altas']),
      choferesTotal: _i(m['choferes_total']),
      choferesActivos: _i(m['choferes_activos']),
      choferes: choferes,
      vehiculos: vehiculos,
      sincronizadoEn: sinc,
      infraccionesHeatmap: hotspots,
    );
  }

  /// Choferes RANKEABLES / premiables: con actividad **y** DNI real. Un
  /// item sin DNI (unidad sin chofer identificado, o un chofer real cuyo
  /// DNI no está cargado en Sitrack — confirmado en vivo: BUSCIO, BASTIAS)
  /// NO puede competir por un premio ni atribuírsele un castigo, así que
  /// queda fuera del universo de ranking, top5 y conteos. Esto cierra de
  /// una sola vez el agujero del "fantasma sin chofer" en todos los
  /// consumidores (ranking, reporte, Excel, tablero ejecutivo).
  List<IcmOficialChofer> get choferesConActividad =>
      choferes.where((c) => !c.sinActividad && c.tieneDni).toList();

  /// Ranking para mostrar MEJOR primero (ICM más bajo = posición #1),
  /// luego el resto (sin actividad o sin DNI) al final, greyed y sin
  /// puesto numérico. Lectura tipo podio (gamification) — pedido por
  /// Santiago 2026-05-23 para la pantalla y el Excel.
  ///
  /// Antes ordenaba PEOR arriba (el operador "atendía primero" a los de
  /// mayor riesgo). El cambio simplifica el modelo: un solo orden en
  /// toda la app + el reporte. Si en algún momento se necesita el listado
  /// peor-arriba para foco operativo, conviene crear un getter aparte o
  /// invertir esta lista en el caller.
  List<IcmOficialChofer> get choferesParaRanking {
    final rankeables = [...choferesConActividad]
      ..sort((a, b) => a.icm.compareTo(b.icm)); // asc: mejor arriba
    final resto =
        choferes.where((c) => c.sinActividad || !c.tieneDni).toList();
    return [...rankeables, ...resto];
  }

  /// Los N mejores (ICM más bajo) entre los choferes con actividad.
  List<IcmOficialChofer> mejores(int n) {
    final l = [...choferesConActividad]
      ..sort((a, b) => a.icm.compareTo(b.icm));
    return l.take(n).toList();
  }

  /// Los N peores (ICM más alto) entre los choferes con actividad.
  List<IcmOficialChofer> peores(int n) {
    final l = [...choferesConActividad]
      ..sort((a, b) => b.icm.compareTo(a.icm));
    return l.take(n).toList();
  }

  /// Conteo de choferes con actividad por severidad (para distribución).
  Map<SeveridadIcm, int> get conteoPorSeveridad {
    final m = <SeveridadIcm, int>{};
    for (final c in choferesConActividad) {
      m[c.severidadEnum] = (m[c.severidadEnum] ?? 0) + 1;
    }
    return m;
  }

  bool get vacio => choferes.isEmpty;
}

class IcmOficialService {
  IcmOficialService._();

  static const String coleccion = 'ICM_OFICIAL';
  static const String coleccionSemanal = 'ICM_OFICIAL_SEMANAL';

  /// Día calendario ART (UTC-3, sin DST) de ahora.
  static DateTime _hoyArt() =>
      DateTime.now().toUtc().subtract(const Duration(hours: 3));

  /// Id del doc semanal = fecha del LUNES (ART) de la semana de [d], en
  /// 'YYYY-MM-DD'. Coincide con `_rango_semana_actual` del scraper
  /// (lunes = hoy − (weekday−1)). Default: semana en curso.
  static String semanaId([DateTime? d]) {
    final base = d ?? _hoyArt();
    final lunes =
        base.subtract(Duration(days: base.weekday - DateTime.monday));
    final y = lunes.year.toString().padLeft(4, '0');
    final m = lunes.month.toString().padLeft(2, '0');
    final dd = lunes.day.toString().padLeft(2, '0');
    return '$y-$m-$dd';
  }

  /// Label de una semana (id = lunes 'YYYY-MM-DD') → "Semana del 18/05".
  static String labelSemana(String semanaId) {
    final p = semanaId.split('-');
    if (p.length != 3) return semanaId;
    return 'Semana del ${p[2]}/${p[1]}';
  }

  /// ID del período (mes) en formato 'YYYY-MM' ART. `offsetMeses` = 0 mes
  /// actual, -1 mes anterior, etc.
  static String periodoId({int offsetMeses = 0}) {
    final base = _hoyArt();
    final d = DateTime(base.year, base.month + offsetMeses, 1);
    final mm = d.month.toString().padLeft(2, '0');
    return '${d.year}-$mm';
  }

  /// Label legible de un período 'YYYY-MM' → "Mayo 2026".
  static String labelPeriodo(String periodo) {
    const meses = [
      'Enero', 'Febrero', 'Marzo', 'Abril', 'Mayo', 'Junio',
      'Julio', 'Agosto', 'Septiembre', 'Octubre', 'Noviembre', 'Diciembre',
    ];
    final partes = periodo.split('-');
    if (partes.length != 2) return periodo;
    final anio = partes[0];
    final mes = int.tryParse(partes[1]) ?? 0;
    if (mes < 1 || mes > 12) return periodo;
    return '${meses[mes - 1]} $anio';
  }

  /// Carga un período. Devuelve null si el doc no existe (el scraper aún no
  /// corrió para ese mes). `excluirDni`/`excluirPatente` filtran la lista
  /// visible (tanqueros + testers) sin tocar los totales auditados.
  static Future<IcmOficialPeriodo?> cargarPeriodo(
    FirebaseFirestore db,
    String periodo, {
    String coleccionFirestore = coleccion,
    bool Function(String dni)? excluirDni,
    bool Function(String patente)? excluirPatente,
  }) async {
    final snap = await db.collection(coleccionFirestore).doc(periodo).get();
    if (!snap.exists) return null;
    final data = snap.data();
    if (data == null) return null;
    return IcmOficialPeriodo.fromMap(
      data,
      excluirDni: excluirDni,
      excluirPatente: excluirPatente,
    );
  }

  /// Carga las infracciones individuales de un chofer desde la subcolección
  /// `{coleccion}/{periodo}/infracciones_chofer/{scopeId}` (hardening 1 MiB
  /// 2026-06-13). Devuelve `[]` si el doc no existe — caso de un período viejo
  /// que trae las infracciones embebidas en el doc principal (ahí se usa
  /// `chofer.infracciones` directo). El caller hace el dual-read: embebido
  /// primero, esta subcolección como fuente para los docs nuevos.
  static Future<List<InfraccionIndividual>> cargarInfraccionesChofer(
    FirebaseFirestore db,
    String periodo,
    int scopeId, {
    String coleccionFirestore = coleccion,
  }) async {
    if (scopeId <= 0) return const [];
    final snap = await db
        .collection(coleccionFirestore)
        .doc(periodo)
        .collection('infracciones_chofer')
        .doc(scopeId.toString())
        .get();
    if (!snap.exists) return const [];
    final raw = (snap.data()?['infracciones'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => InfraccionIndividual.fromMap(e.cast<String, dynamic>()))
        .toList();
  }
}
