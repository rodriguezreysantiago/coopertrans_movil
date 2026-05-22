// Histórico semanal del ICM — por chofer (comparativa individual).
//
// El AGREGADO de toda la flota (ranking + top5/peores semanal) lo
// precalcula la Cloud Function `recomputeIcmSemanalScheduled` (lunes
// 06:00 ART) y persiste en `ICM_SEMANAL/{YYYY-WW}`. La pantalla
// `icm_reporte_semanal_screen.dart` lee ese doc directo en lugar de
// recalcular.
//
// Este service queryea SITRACK_EVENTOS on-the-fly SOLO para el caso
// "comparativa de UN chofer en las últimas N semanas" (drill-down
// individual). Para el agregado semanal de flota, usar el doc de
// ICM_SEMANAL que ya está precalculado.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'icm_calculator.dart';

/// ICM agregado de UN chofer en UNA semana.
class IcmSemanaChofer {
  /// Lunes 00:00 ART de la semana (inicio).
  final DateTime semanaInicio;
  /// Label legible: "S 12-18 May" (lun-dom).
  final String labelSemana;
  final int totalEventos;
  final double kmRecorridos;
  final double infraccionesPor100Km;
  final double icm; // 0..100
  final CategoriaIcm categoria;

  const IcmSemanaChofer({
    required this.semanaInicio,
    required this.labelSemana,
    required this.totalEventos,
    required this.kmRecorridos,
    required this.infraccionesPor100Km,
    required this.icm,
    required this.categoria,
  });
}

/// ICM agregado de TODA la flota en UNA semana — base del reporte semanal.
class IcmSemanaFlota {
  final DateTime semanaInicio;
  final String labelSemana;
  final int totalEventos;
  final int choferesActivos;
  final double icmPromedio;
  final int choferesVerdes;
  final int choferesAmarillos;
  final int choferesRojos;
  final List<IcmChofer> top5Mejores;
  final List<IcmChofer> top5Peores;

  const IcmSemanaFlota({
    required this.semanaInicio,
    required this.labelSemana,
    required this.totalEventos,
    required this.choferesActivos,
    required this.icmPromedio,
    required this.choferesVerdes,
    required this.choferesAmarillos,
    required this.choferesRojos,
    required this.top5Mejores,
    required this.top5Peores,
  });
}

class IcmHistoricoService {
  IcmHistoricoService._();

  /// Devuelve las últimas N semanas del chofer indicado, en orden
  /// cronológico ascendente (la más vieja primero, la más reciente
  /// al final — útil para gráfico de línea).
  ///
  /// `cantidadSemanas` default 12 (~3 meses) — balance entre suficiente
  /// data para tendencia y cantidad de queries. Las N queries corren en
  /// paralelo con Future.wait (antes eran secuenciales, ~12 round-trips
  /// serializados por carga del detalle).
  static Future<List<IcmSemanaChofer>> historicoChofer({
    required FirebaseFirestore db,
    required String choferDni,
    int cantidadSemanas = 12,
  }) async {
    final semanas = _generarSemanas(cantidadSemanas);
    // Disparar las N queries en paralelo (1 round-trip a Firestore en
    // vez de N serializados — performance crítica al abrir el detalle).
    final snaps = await Future.wait(
      semanas.map((s) => db
          .collection('SITRACK_EVENTOS')
          .where('driver_dni', isEqualTo: choferDni)
          .where('report_date',
              isGreaterThanOrEqualTo:
                  Timestamp.fromMillisecondsSinceEpoch(s.inicioMs))
          .where('report_date',
              isLessThan: Timestamp.fromMillisecondsSinceEpoch(s.finMs))
          .get()),
    );

    final result = <IcmSemanaChofer>[];
    for (var i = 0; i < semanas.length; i++) {
      final s = semanas[i];
      var total = 0;
      // Tracking del odómetro Sitrack por patente para km reales
      // (idéntico patrón a icm_calculator.dart — los km del chofer en
      // la semana son sum(max-min) sobre cada patente que manejó).
      final odometroPorPatente = <String, _OdometroTracking>{};
      for (final doc in snaps[i].docs) {
        final d = doc.data();
        final eventId = d['event_id'];
        final patente = (d['asset_id'] ?? '').toString().trim().toUpperCase();
        final odometer = (d['odometer'] as num?)?.toDouble();
        if (patente.isNotEmpty && odometer != null && odometer > 0) {
          final t = odometroPorPatente.putIfAbsent(
            patente,
            () => _OdometroTracking(),
          );
          if (odometer < t.min) t.min = odometer;
          if (odometer > t.max) t.max = odometer;
        }
        if (eventId is int && kTiposInfraccionIcm.contains(eventId)) {
          total++;
        }
      }
      // Km reales = sum(max - min) por patente. Cap 10000 km/patente
      // por semana defensivo contra reset de odometro Sitrack (mismo
      // patron que icm_calculator). Cap subido de 5000 a 10000 para
      // no descartar choferes de larga distancia (auditoria 2026-05-18).
      double kmReales = 0;
      var capsAplicados = 0;
      for (final ePat in odometroPorPatente.entries) {
        final t = ePat.value;
        if (t.max > t.min) {
          final delta = t.max - t.min;
          if (delta <= 10000) {
            kmReales += delta;
          } else {
            // Cap aplicado (probable reset de odometro). Loguear para
            // diagnostico — sin esto un chofer SIN_DATOS en una semana
            // donde manejo solo en una patente con reset quedaba
            // inexplicado en el reporte historico (auditoria 2026-05-18).
            capsAplicados++;
            debugPrint(
              '[ICM-hist] cap aplicado dni=$choferDni patente=${ePat.key} '
              'semana=${s.label} delta=${delta.toStringAsFixed(0)}km '
              '— probable reset de odometro',
            );
          }
        }
      }
      if (capsAplicados > 0 && kmReales == 0) {
        debugPrint(
          '[ICM-hist] dni=$choferDni semana=${s.label} queda SIN_DATOS por '
          'todos los caps aplicados ($capsAplicados patente(s))',
        );
      }
      // Mismo umbral que icm_calculator: si no hay km suficientes,
      // categorizamos como sinDatos en lugar de inventar ICM falso.
      final tieneKmReales = kmReales >= 50.0;
      final km = tieneKmReales ? kmReales : 0.0;
      final ratio = km > 0 ? total / (km / 100.0) : 0.0;
      final icm =
          tieneKmReales ? (100 - ratio * 5).clamp(0.0, 100.0) : 0.0;
      result.add(IcmSemanaChofer(
        semanaInicio: s.inicio,
        labelSemana: s.label,
        totalEventos: total,
        kmRecorridos: km,
        infraccionesPor100Km: ratio,
        icm: icm,
        categoria: _categorizar(icm, total, tieneKmReales),
      ));
    }
    return result;
  }

  /// Devuelve las últimas N semanas con agregados de TODA la flota.
  ///
  /// Usa `ICM_SEMANAL/{YYYY-WW}` cuando la semana ya cerró y el cron
  /// `recomputeIcmSemanalScheduled` la persistió. Solo recurre al
  /// cálculo on-the-fly para la semana ACTUAL (que aún no cerró). Esto
  /// evita procesar miles de eventos al abrir el reporte semanal.
  static Future<List<IcmSemanaFlota>> historicoFlota({
    required FirebaseFirestore db,
    required Map<String, String> nombrePorDni,
    int cantidadSemanas = 12,
  }) async {
    final semanas = _generarSemanas(cantidadSemanas);
    final ahoraMs = DateTime.now().millisecondsSinceEpoch;
    final result = <IcmSemanaFlota>[];
    for (final s in semanas) {
      final esSemanaActual = s.finMs > ahoraMs;
      IcmSemanaFlota? cargada;
      if (!esSemanaActual) {
        cargada = await _leerIcmSemanalDoc(db, s);
      }
      cargada ??= await _calcularSemanaOnTheFly(
        db: db,
        nombrePorDni: nombrePorDni,
        semana: s,
      );
      result.add(cargada);
    }
    return result;
  }

  /// Lee `ICM_SEMANAL/{YYYY-WW}` si existe y mapea a `IcmSemanaFlota`.
  /// Devuelve null si el doc no existe (cron no corrió todavía o falla).
  static Future<IcmSemanaFlota?> _leerIcmSemanalDoc(
    FirebaseFirestore db,
    _Semana s,
  ) async {
    try {
      final id = _isoWeekId(s.inicio);
      final snap = await db.collection('ICM_SEMANAL').doc(id).get();
      if (!snap.exists) return null;
      final d = snap.data()!;
      final mejores = ((d['top_5_mejores'] as List?) ?? const [])
          .map((e) => _topItemAIcmChofer(e as Map<String, dynamic>))
          .toList();
      final peores = ((d['top_5_peores'] as List?) ?? const [])
          .map((e) => _topItemAIcmChofer(e as Map<String, dynamic>))
          .toList();
      return IcmSemanaFlota(
        semanaInicio: s.inicio,
        labelSemana: s.label,
        totalEventos: (d['total_eventos'] as num?)?.toInt() ?? 0,
        choferesActivos: (d['choferes_activos'] as num?)?.toInt() ?? 0,
        icmPromedio: (d['icm_promedio'] as num?)?.toDouble() ?? 0.0,
        choferesVerdes: (d['choferes_verdes'] as num?)?.toInt() ?? 0,
        choferesAmarillos: (d['choferes_amarillos'] as num?)?.toInt() ?? 0,
        choferesRojos: (d['choferes_rojos'] as num?)?.toInt() ?? 0,
        top5Mejores: mejores,
        top5Peores: peores,
      );
    } catch (_) {
      return null;
    }
  }

  static IcmChofer _topItemAIcmChofer(Map<String, dynamic> e) {
    final dni = (e['dni'] ?? '').toString();
    final nombre = (e['nombre'] ?? 'DNI $dni').toString();
    final icm = (e['icm'] as num?)?.toDouble() ?? 0.0;
    return IcmChofer(
      choferDni: dni,
      choferNombre: nombre,
      totalEventos: 0, // top items no cargan total — drill-down desde ranking
      kmRecorridos: 0,
      infraccionesPor100Km: 0,
      icm: icm,
      // Delega a categorizarIcm (umbrales YPF 91/71) — no duplicar.
      categoria: categorizarIcm(icm),
      eventosPorTipo: const {},
      patentes: const [],
    );
  }

  /// Cálculo on-the-fly desde SITRACK_EVENTOS — fallback cuando el
  /// agregado pre-calculado de ICM_SEMANAL no está disponible (semana
  /// actual o cron no corrió).
  static Future<IcmSemanaFlota> _calcularSemanaOnTheFly({
    required FirebaseFirestore db,
    required Map<String, String> nombrePorDni,
    required _Semana semana,
  }) async {
    final ranking = await IcmCalculator.calcularRanking(
      db: db,
      desdeMs: semana.inicioMs,
      hastaMs: semana.finMs,
      nombrePorDni: nombrePorDni,
    );
    // CRITICO (auditoria 2026-05-17): excluir SIN_DATOS de promedio y
    // top5. Antes pisaba el KPI promedio (mostraba 60 cuando real 90)
    // y aparecian SIN_DATOS en top5 peores (todos en posicion 1 — ranking
    // sin valor).
    final conDatos =
        ranking.where((c) => c.categoria != CategoriaIcm.sinDatos).toList();
    var totalEventos = 0;
    var verdes = 0;
    var amarillos = 0;
    var rojos = 0;
    var sumIcm = 0.0;
    // Total eventos cuenta TODOS (incluyendo SIN_DATOS) — son infracciones
    // reales aunque no haya km suficientes para calcular ICM.
    for (final c in ranking) {
      totalEventos += c.totalEventos;
    }
    for (final c in conDatos) {
      sumIcm += c.icm;
      switch (c.categoria) {
        case CategoriaIcm.bajo:
          verdes++;
          break;
        case CategoriaIcm.medio:
          amarillos++;
          break;
        case CategoriaIcm.alto:
          rojos++;
          break;
        case CategoriaIcm.sinDatos:
          break;
      }
    }
    final icmProm = conDatos.isNotEmpty ? sumIcm / conDatos.length : 0.0;
    // Ranking del IcmCalculator ya viene ordenado peor->mejor (con SIN_DATOS
    // al final tras el fix abajo). Top peores = primeros con datos, top
    // mejores = ultimos.
    final peores = conDatos.take(5).toList();
    final mejores = conDatos.reversed.take(5).toList();
    return IcmSemanaFlota(
      semanaInicio: semana.inicio,
      labelSemana: semana.label,
      totalEventos: totalEventos,
      choferesActivos: conDatos.length,
      icmPromedio: icmProm,
      choferesVerdes: verdes,
      choferesAmarillos: amarillos,
      choferesRojos: rojos,
      top5Mejores: mejores,
      top5Peores: peores,
    );
  }

  /// ID semana ISO 8601 ("YYYY-WNN"). Mismo algoritmo que el cron
  /// server-side (`recomputeIcmSemanalScheduled._isoWeekId`).
  static String _isoWeekId(DateTime d) {
    final target = DateTime.utc(d.year, d.month, d.day);
    final dayNum = (target.weekday + 6) % 7; // lunes=0 ... domingo=6
    final thursday = target.add(Duration(days: 3 - dayNum));
    final firstThursday = DateTime.utc(thursday.year, 1, 4);
    final firstThursdayDayNum = (firstThursday.weekday + 6) % 7;
    final week = 1 +
        ((thursday.difference(firstThursday).inDays - 3 + firstThursdayDayNum) /
                7)
            .round();
    return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
  }

  /// Genera la lista de semanas (lunes 00:00 ART → siguiente lunes
  /// 00:00 ART) hacia atrás desde la semana actual. Devuelve en
  /// orden cronológico ascendente.
  static List<_Semana> _generarSemanas(int cantidad) {
    final ahora = DateTime.now();
    // Lunes de la semana actual.
    final diasDesdeLunes = (ahora.weekday - DateTime.monday) % 7;
    final lunesActual = DateTime(ahora.year, ahora.month, ahora.day)
        .subtract(Duration(days: diasDesdeLunes));
    final result = <_Semana>[];
    for (int i = cantidad - 1; i >= 0; i--) {
      final inicio = lunesActual.subtract(Duration(days: 7 * i));
      final fin = inicio.add(const Duration(days: 7));
      final label = _labelSemana(inicio, fin);
      result.add(_Semana(
        inicio: inicio,
        fin: fin,
        inicioMs: inicio.millisecondsSinceEpoch,
        finMs: fin.millisecondsSinceEpoch,
        label: label,
      ));
    }
    return result;
  }

  static String _labelSemana(DateTime inicio, DateTime fin) {
    const meses = [
      'Ene', 'Feb', 'Mar', 'Abr', 'May', 'Jun',
      'Jul', 'Ago', 'Sep', 'Oct', 'Nov', 'Dic',
    ];
    final finDom = fin.subtract(const Duration(days: 1));
    if (inicio.month == finDom.month) {
      return '${inicio.day}-${finDom.day} ${meses[inicio.month - 1]}';
    }
    return '${inicio.day} ${meses[inicio.month - 1]} - '
        '${finDom.day} ${meses[finDom.month - 1]}';
  }

  /// Categoriza el ICM 0-100. Si no hay km reales medidos, devolvemos
  /// `sinDatos` en lugar de mentir con un ICM falso (antes con
  /// `totalEventos==0` devolvíamos `bajo` lo que pintaba verde la
  /// pantalla de detalle aún cuando no había actividad histórica).
  /// Delega al helper publico `categorizarIcm` (icm_calculator) para
  /// no duplicar los umbrales 80/60 (auditoria 2026-05-17).
  static CategoriaIcm _categorizar(
    double icm,
    int totalEventos,
    bool tieneKmReales,
  ) {
    return categorizarIcm(icm, tieneKmReales: tieneKmReales);
  }
}

class _OdometroTracking {
  double min = double.infinity;
  double max = double.negativeInfinity;
}

class _Semana {
  final DateTime inicio;
  // ignore: unused_element_parameter
  final DateTime fin;
  final int inicioMs;
  final int finMs;
  final String label;

  const _Semana({
    required this.inicio,
    required this.fin,
    required this.inicioMs,
    required this.finMs,
    required this.label,
  });
}
