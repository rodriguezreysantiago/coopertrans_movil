// =============================================================================
// IcmCalculator — cálculo on-the-fly del ICM CESVI
// =============================================================================
//
// Refactor mayor 2026-05-19 (Santiago): implementación EXACTA CESVI
// homologada (presentación Carsync YPF). Ver `icm_cesvi.dart` para las
// funciones puras y los pesos por tipo.
//
// **Rediseño 2026-05-22 (Santiago, "todo marca 100"): unidad = (chofer,
// día ART), NO las jornadas del vigilador.** Diagnóstico contra datos
// reales: las jornadas estaban rotas (ventanas 10-22h con 1.3h de manejo)
// y dejaban el 41% de las infracciones FUERA de toda ventana → además el
// km salía de odómetro POR EVENTO (los eventos bruscos no traen
// odómetro) y el filtro km>=10 descartaba casi todo → ICM espurio ~100.
// Ahora: bucket por día (no pierde eventos), km POR PATENTE (eventos de
// movimiento traen odómetro 98%) prorrateado al chofer, sin fatiga (no
// hay señal real en el feed). Es una ESTIMACIÓN INTERNA, no el número
// oficial homologado de YPF/Carsync (que pondera por segmento vial, dato
// que no tenemos).
//
// Uso: lo invoca el ranking ICM en vivo (cuando aún no existe el doc
// pre-calculado en `ICM_SEMANAL/{YYYY-WW}` — típicamente la semana
// actual que el cron `recomputeIcmSemanalScheduled` todavía no cerró
// porque corre lunes 6 AM ART). Mismo cálculo que el servidor para
// garantizar paridad: si la última semana cerrada salió ICM 75 desde
// el cron, esta función también da 75 si la querés recomputar.
//
// **Antes** (factor lineal `100 − ratio×5`): daba "todos en 100" para
// la operación real de Vecchi porque la calibración era muy permisiva
// e incluía eventos no-CESVI (1006, 1007, 444). Reemplazado por la
// fórmula CESVI exacta.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'icm_cesvi.dart';

/// Tipos de evento Sitrack que CESVI/YPF cuenta para el ICM (Índice
/// de Conducta de Manejo, homologado por CESVI Argentina). Set
/// estricto — refactorizado Santiago 2026-05-19 al alinear con la
/// fórmula CESVI exacta del PDF de YPF:
///   - 66  Aceleración Brusca (peso −2.8 por evento)
///   - 67  Frenada Brusca     (peso −5.8 por evento)
///   - 383 Giro Brusco        (peso −2.8 por evento)
///   - 8   Inicio sobrevelocidad ┐ pareados como UN evento de
///   - 9   Fin sobrevelocidad    ┘ sobrevelocidad con duración
///
/// **Antes** (2026-05-16 → 2026-05-19): incluía 267/326/444/1006/1007
/// que son alertas Volvo/Mobileye de seguridad (salida de carril,
/// colisión, distancia frenado insuficiente) — esos NO son parte del
/// ICM CESVI. Hoy viven solo en `TIPOS_PELIGROSOS_SITRACK` para el
/// resumen Molina, no acá.
///
/// ⚠ ESPEJO SERVER-SIDE en `functions/src/index.ts:TIPOS_CESVI_PUROS`.
/// Si tocás uno, tocá el otro.
const Set<int> kTiposInfraccionIcm = {
  8, 9, 66, 67, 383,
};

/// Categoría de riesgo según el rango de ICM. Umbrales EXACTOS de YPF
/// (Minuta Revisión ICM VECCHI): Bajo (verde) 100-91, Medio (amarillo)
/// 90-71, Alto (rojo) 70-0.
///
/// IMPORTANTE: los umbrales 91/71 estan REPETIDOS en:
///   - functions/src/icm_cesvi.ts:categorizar
///   - lib/features/icm/services/icm_cesvi.dart:categorizarCesvi
///   - lib/features/vista_ejecutiva/services/vista_ejecutiva_service.dart
///   - lib/features/icm/services/icm_historico_service.dart (delega acá)
/// Si cambias los umbrales aca, CAMBIALOS EN LOS 4 LUGARES (auditoria
/// pendiente: unificar en helper compartido).
enum CategoriaIcm { bajo, medio, alto, sinDatos }

/// Helper publico para categorizar un ICM. Reusado por
/// icm_historico_service. Mantiene la API legacy aunque internamente
/// delegue al módulo CESVI.
CategoriaIcm categorizarIcm(double icm, {bool tieneKmReales = true}) {
  if (!tieneKmReales) return CategoriaIcm.sinDatos;
  final cat = categorizarCesvi(icm);
  switch (cat) {
    case CategoriaCesvi.bajo:
      return CategoriaIcm.bajo;
    case CategoriaCesvi.medio:
      return CategoriaIcm.medio;
    case CategoriaCesvi.alto:
      return CategoriaIcm.alto;
    case CategoriaCesvi.sinDatos:
      return CategoriaIcm.sinDatos;
  }
}

/// Resumen del ICM de un chofer en un rango.
class IcmChofer {
  final String choferDni;
  final String choferNombre;
  final int totalEventos;
  final double kmRecorridos;
  final double infraccionesPor100Km;
  final double icm; // 0..100
  final CategoriaIcm categoria;
  /// Distribución por tipo de evento (key = nombre del evento, value = count).
  final Map<String, int> eventosPorTipo;
  /// Patentes que manejó el chofer en el rango (más frecuente primero).
  final List<String> patentes;

  const IcmChofer({
    required this.choferDni,
    required this.choferNombre,
    required this.totalEventos,
    required this.kmRecorridos,
    required this.infraccionesPor100Km,
    required this.icm,
    required this.categoria,
    required this.eventosPorTipo,
    required this.patentes,
  });
}

class IcmCalculator {
  IcmCalculator._();

  /// Cap defensivo: una patente no recorre > 2000 km en un día. Si el
  /// delta de odómetro de la patente en el día lo supera, es casi seguro
  /// un reset de odómetro Sitrack — ese día de esa patente no aporta km.
  static const double _kmMaxPatenteDia = 2000;

  /// Día calendario ART (UTC-3, sin DST) de un timestamp en ms →
  /// 'YYYY-MM-DD'. Mismo criterio que el cron server-side (icm.ts).
  static String _diaArt(int ms) {
    final art = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
        .subtract(const Duration(hours: 3));
    final y = art.year.toString().padLeft(4, '0');
    final m = art.month.toString().padLeft(2, '0');
    final d = art.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Calcula el ICM de TODOS los choferes con actividad en el rango.
  /// Devuelve la lista ordenada del peor (ICM más bajo) al mejor.
  ///
  /// **Rediseño 2026-05-22** — unidad = (chofer, día ART), NO jornadas:
  ///   1. Cargar SITRACK_EVENTOS del rango (paginado por cursor).
  ///   2. Indexar: eventos CESVI por (dni,día); odómetro por (patente,
  ///      día); patentes que tocó cada (dni,día); conteo de eventos por
  ///      (patente,día,dni) para prorratear km en cambios de turno.
  ///   3. km(dni,día) = Σ por patente del delta de odómetro de esa
  ///      patente ese día, prorrateado por la porción de eventos del
  ///      chofer. SIN fatiga (no hay señal real → bloque vacío).
  ///   4. Por (dni,día) con eventos CESVI o km>0 → `calcularIcmJornada`.
  ///   5. Combinar por chofer con `combinarJornadas` (km-weighted).
  ///
  /// `nombrePorDni` es el lookup de EMPLEADOS para resolver nombres.
  static Future<List<IcmChofer>> calcularRanking({
    required FirebaseFirestore db,
    required int desdeMs,
    required int hastaMs,
    required Map<String, String> nombrePorDni,
  }) async {
    // ─── 1. SITRACK_EVENTOS del rango — paginado por cursor ────────
    // Firestore client SDK limita .limit() a 10000 por query. Para
    // rangos de mes completo (~25-35K eventos) paginamos con cursor
    // sobre `report_date` ordenado. Cap total 100K defensivo.
    const int pageSize = 10000;
    const int capTotal = 100000;
    final idx = _IndiceEventos();
    DocumentSnapshot<Map<String, dynamic>>? cursor;
    var totalLeidos = 0;
    while (totalLeidos < capTotal) {
      Query<Map<String, dynamic>> q = db
          .collection('SITRACK_EVENTOS')
          .where('report_date',
              isGreaterThanOrEqualTo:
                  Timestamp.fromMillisecondsSinceEpoch(desdeMs))
          .where('report_date',
              isLessThan: Timestamp.fromMillisecondsSinceEpoch(hastaMs))
          .orderBy('report_date')
          .limit(pageSize);
      if (cursor != null) {
        q = q.startAfterDocument(cursor);
      }
      final pageSnap = await q.get();
      if (pageSnap.docs.isEmpty) break;
      _indexar(pageSnap.docs, idx);
      totalLeidos += pageSnap.docs.length;
      if (pageSnap.docs.length < pageSize) break; // última página
      cursor = pageSnap.docs.last;
    }
    if (totalLeidos >= capTotal) {
      debugPrint(
        '[ICM] cap defensivo de $capTotal eventos alcanzado — el '
        'ranking puede estar incompleto. Considerar reducir el rango.',
      );
    }

    // ─── 2-4. Buckets (dni, día) ───────────────────────────────────
    // El set de buckets es la unión de los que tienen eventos CESVI y
    // los que tienen patente con km — así un chofer que manejó limpio
    // (solo eventos de movimiento) entra en ICM 100, y uno con
    // infracciones pero sin odómetro no se pierde.
    final porChofer = <String, List<JornadaConIcm>>{};
    final claves = <String>{
      ...idx.cesviPorDniDia.keys,
      ...idx.patentesPorDniDia.keys,
    };
    for (final clave in claves) {
      final sep = clave.indexOf('|');
      final dni = clave.substring(0, sep);
      final eventos =
          idx.cesviPorDniDia[clave] ?? const <EventoSitrackICM>[];
      final km = idx.kmDniDia(clave);
      if (eventos.isEmpty && km <= 0) continue;
      // Sin fatiga: bloque vacío (no hay señal real de tiempo recorrido).
      final res = calcularIcmJornada(eventos, const <double>[]);
      porChofer.putIfAbsent(dni, () => []).add(JornadaConIcm(
            icm: res.icm,
            km: km,
            desglose: res,
          ));
    }

    // ─── 5. Combinar por chofer y armar IcmChofer ──────────────────
    final result = <IcmChofer>[];
    for (final entry in porChofer.entries) {
      final dni = entry.key;
      final agregado = combinarJornadas(entry.value);
      final totalEventosCesvi = agregado.totalAceleraciones +
          agregado.totalFrenadas +
          agregado.totalGiros +
          agregado.totalSobrevelocidades;
      final ratio = agregado.kmTotales > 0
          ? totalEventosCesvi / (agregado.kmTotales / 100.0)
          : 0.0;
      final patMap = idx.patentesPorChofer[dni] ?? const <String, int>{};
      final patOrd = patMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      result.add(IcmChofer(
        choferDni: dni,
        choferNombre: nombrePorDni[dni] ?? 'DNI $dni',
        totalEventos: totalEventosCesvi,
        kmRecorridos: agregado.kmTotales,
        infraccionesPor100Km: ratio,
        icm: agregado.icm,
        categoria: _cesviToLegacy(agregado.categoria),
        eventosPorTipo:
            Map<String, int>.from(idx.eventosNombrePorChofer[dni] ?? {}),
        patentes: patOrd.map((e) => e.key).toList(),
      ));
    }

    // ─── 6. Ordenar: peor ICM primero, SIN_DATOS al final ──────────
    result.sort((a, b) {
      final aSinDatos = a.categoria == CategoriaIcm.sinDatos;
      final bSinDatos = b.categoria == CategoriaIcm.sinDatos;
      if (aSinDatos && !bSinDatos) return 1;
      if (!aSinDatos && bSinDatos) return -1;
      return a.icm.compareTo(b.icm);
    });
    return result;
  }

  /// Categoría helper para tests y consumidores externos (alineada con
  /// el módulo CESVI puro).
  static CategoriaIcm categorizar(double icm) => categorizarIcm(icm);

  /// Indexa una página de docs SITRACK_EVENTOS en `idx`. Mutador in-place.
  /// Cada evento aporta a varias estructuras:
  ///   - odómetro por (patente,día): cada evento con patente + odómetro.
  ///   - patentes por (dni,día) + conteo por (patente,día,dni): cada
  ///     evento con dni + patente (incluye eventos de movimiento, que
  ///     son los que traen odómetro denso).
  ///   - eventos CESVI por (dni,día) + nombre/patente por chofer: solo
  ///     los tipos de infracción.
  static void _indexar(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    _IndiceEventos idx,
  ) {
    for (final doc in docs) {
      final d = doc.data();
      final tsMs = (d['report_date'] as Timestamp?)?.millisecondsSinceEpoch;
      if (tsMs == null) continue;
      final dia = _diaArt(tsMs);
      final dni = (d['driver_dni'] ?? '').toString().trim();
      final pat = (d['asset_id'] ?? '').toString().trim().toUpperCase();
      final odo = (d['odometer'] as num?)?.toDouble() ??
          (d['gps_odometer'] as num?)?.toDouble();
      // Odómetro por patente-día (cualquier evento, identifique o no chofer).
      if (pat.isNotEmpty && odo != null && odo > 0) {
        (idx.odoPatDia['$pat|$dia'] ??= _MinMax()).add(odo);
      }
      if (dni.isEmpty) continue;
      final claveDniDia = '$dni|$dia';
      // Patente que tocó el chofer ese día + conteo para prorrateo de km.
      if (pat.isNotEmpty) {
        (idx.patentesPorDniDia[claveDniDia] ??= <String>{}).add(pat);
        final m = idx.eventosPatDiaDni['$pat|$dia'] ??= <String, int>{};
        m[dni] = (m[dni] ?? 0) + 1;
      }
      final eId = d['event_id'];
      if (eId is! int || !kTiposInfraccionIcm.contains(eId)) continue;
      idx.cesviPorDniDia.putIfAbsent(claveDniDia, () => []).add(
            EventoSitrackICM(
              eventId: eId,
              reportDateMs: tsMs,
              assetId: pat,
              driverDni: dni,
              speed: (d['speed'] as num?)?.toDouble() ??
                  (d['gps_speed'] as num?)?.toDouble(),
              cartographyLimitSpeed:
                  (d['cartography_limit_speed'] as num?)?.toDouble(),
              areaType: (d['area_type'] ?? 'unknown').toString(),
              odometer: odo,
            ),
          );
      final nombre = (d['event_name'] ?? 'Evento $eId').toString();
      final mNom =
          idx.eventosNombrePorChofer.putIfAbsent(dni, () => <String, int>{});
      mNom[nombre] = (mNom[nombre] ?? 0) + 1;
      if (pat.isNotEmpty) {
        final mPat =
            idx.patentesPorChofer.putIfAbsent(dni, () => <String, int>{});
        mPat[pat] = (mPat[pat] ?? 0) + 1;
      }
    }
  }

  static CategoriaIcm _cesviToLegacy(CategoriaCesvi c) {
    switch (c) {
      case CategoriaCesvi.bajo:
        return CategoriaIcm.bajo;
      case CategoriaCesvi.medio:
        return CategoriaIcm.medio;
      case CategoriaCesvi.alto:
        return CategoriaIcm.alto;
      case CategoriaCesvi.sinDatos:
        return CategoriaIcm.sinDatos;
    }
  }
}

/// Min/max de odómetro de una patente en un día (interno al calculator).
class _MinMax {
  double min = double.infinity;
  double max = double.negativeInfinity;
  bool get valido => max > min && min != double.infinity;
  void add(double v) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
}

/// Índices construidos al recorrer SITRACK_EVENTOS una sola vez.
/// Claves compuestas con `|`: 'dni|dia' y 'patente|dia'.
class _IndiceEventos {
  /// Eventos CESVI (66/67/383/8/9) agrupados por (dni, día).
  final Map<String, List<EventoSitrackICM>> cesviPorDniDia = {};

  /// Odómetro min/max por (patente, día) — de cada evento con odómetro.
  final Map<String, _MinMax> odoPatDia = {};

  /// Patentes que tocó cada (dni, día).
  final Map<String, Set<String>> patentesPorDniDia = {};

  /// Conteo de eventos por (patente, día) → {dni: count}, para prorratear
  /// el km de la patente cuando varios choferes la usaron el mismo día
  /// (cambio de turno).
  final Map<String, Map<String, int>> eventosPatDiaDni = {};

  /// Patentes por chofer (para el detalle) → {patente: count}.
  final Map<String, Map<String, int>> patentesPorChofer = {};

  /// Nombres de evento por chofer (para el detalle) → {nombre: count}.
  final Map<String, Map<String, int>> eventosNombrePorChofer = {};

  /// km de un (dni, día) = Σ por patente que tocó del delta de odómetro
  /// de esa patente ese día, prorrateado por la porción de eventos del
  /// chofer (cambio de turno). Cap [_kmMaxPatenteDia] por reset.
  double kmDniDia(String claveDniDia) {
    final pats = patentesPorDniDia[claveDniDia];
    if (pats == null || pats.isEmpty) return 0;
    final sep = claveDniDia.indexOf('|');
    final dni = claveDniDia.substring(0, sep);
    final dia = claveDniDia.substring(sep + 1);
    var km = 0.0;
    for (final pat in pats) {
      final claveP = '$pat|$dia';
      final mm = odoPatDia[claveP];
      if (mm == null || !mm.valido) continue;
      final delta = mm.max - mm.min;
      if (delta <= 0 || delta > IcmCalculator._kmMaxPatenteDia) continue;
      final conteo = eventosPatDiaDni[claveP];
      if (conteo == null || conteo.isEmpty) continue;
      final total = conteo.values.fold<int>(0, (a, b) => a + b);
      final mio = conteo[dni] ?? 0;
      if (total <= 0 || mio <= 0) continue;
      km += delta * (mio / total);
    }
    return km;
  }
}
