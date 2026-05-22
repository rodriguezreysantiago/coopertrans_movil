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
  });

  factory IcmOficialChofer.fromMap(Map<String, dynamic> m) {
    return IcmOficialChofer(
      dni: _s(m['dni']),
      nombre: _s(m['nombre']),
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
    );
  }

  /// Choferes con actividad en el período (excluye "sin actividad").
  List<IcmOficialChofer> get choferesConActividad =>
      choferes.where((c) => !c.sinActividad).toList();

  /// Ranking para mostrar: PEOR primero (ICM más alto), luego los "sin
  /// actividad" al final (greyed, no rankeables).
  List<IcmOficialChofer> get choferesParaRanking {
    final activos = choferesConActividad
      ..sort((a, b) => b.icm.compareTo(a.icm)); // desc: peor arriba
    final sinAct = choferes.where((c) => c.sinActividad).toList();
    return [...activos, ...sinAct];
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

  /// Día calendario ART (UTC-3, sin DST) de ahora.
  static DateTime _hoyArt() =>
      DateTime.now().toUtc().subtract(const Duration(hours: 3));

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
    bool Function(String dni)? excluirDni,
    bool Function(String patente)? excluirPatente,
  }) async {
    final snap = await db.collection(coleccion).doc(periodo).get();
    if (!snap.exists) return null;
    final data = snap.data();
    if (data == null) return null;
    return IcmOficialPeriodo.fromMap(
      data,
      excluirDni: excluirDni,
      excluirPatente: excluirPatente,
    );
  }
}
