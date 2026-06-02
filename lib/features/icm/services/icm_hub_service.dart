// Service del Hub ICM: los 4 widgets ricos del módulo (KPI ICM flota grande,
// tendencia diaria del mes en curso, top 5 mejores y top 5 a mejorar). Todos
// vienen del MISMO doc `ICM_OFICIAL/{YYYY-MM}` (mes en curso) + el del mes
// anterior para la comparativa.
//
// Filosofía: usar SIEMPRE la escala oficial Sitrack (más bajo = mejor, ronda
// ~20). Lo que YPF audita.
//
// Antes esta lógica vivía dentro de `VistaEjecutivaService.cargar()` (el
// panel de inicio del admin). Santiago decidió 2026-05-23 que esos 4
// widgets pertenecen al módulo ICM, no al panel general — el panel se
// queda con los KPIs operativos rápidos (viajes/alertas/eficiencia) y el
// hub ICM concentra todo lo de conducta de manejo.

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/choferes_service.dart';
import '../../../core/services/excluidos_service.dart';
import '../../vista_ejecutiva/services/vista_ejecutiva_service.dart'
    show ChoferRankingItem, KpiIcm, PuntoTendencia;
import 'icm_oficial_service.dart';

/// Snapshot completo de los KPIs ricos del Hub ICM. Se carga 1 vez al
/// entrar al hub (FutureBuilder); refresh manual con pull-to-refresh.
class KpisIcmHub {
  /// ICM oficial de la flota: actual + variación vs mes anterior +
  /// cantidad de choferes en el promedio.
  final KpiIcm icmFlota;

  /// Línea ICM oficial DÍA POR DÍA del mes en curso (cae al mes anterior si
  /// el mes recién arranca y todavía no hay ≥2 días).
  final List<PuntoTendencia> tendenciaIcm;

  /// Top 5 mejores choferes del mes (los de ICM más bajo).
  final List<ChoferRankingItem> top5Mejores;

  /// Top 5 a mejorar (los de ICM más alto).
  final List<ChoferRankingItem> top5Peores;

  /// Mes que efectivamente se está mostrando, ej. "Mayo 2026". Puede NO ser el
  /// mes en curso: si éste recién arranca y Sitrack todavía no calculó su ICM
  /// (días 1-2), se cae al último mes con actividad. Vacío si ningún mes tiene
  /// datos.
  final String periodoLabel;

  const KpisIcmHub({
    required this.icmFlota,
    required this.tendenciaIcm,
    required this.top5Mejores,
    required this.top5Peores,
    this.periodoLabel = '',
  });

  static const KpisIcmHub vacio = KpisIcmHub(
    icmFlota: KpiIcm(
      actual: 0,
      anterior: 0,
      variacionAbs: null,
      choferesEnPromedio: 0,
    ),
    tendenciaIcm: [],
    top5Mejores: [],
    top5Peores: [],
  );
}

class IcmHubService {
  IcmHubService._();

  /// Carga los 4 KPIs en paralelo (lectura del doc ICM_OFICIAL del mes
  /// actual + el del mes anterior + tendencia diaria del mismo doc).
  static Future<KpisIcmHub> cargarKpis({
    required FirebaseFirestore db,
  }) async {
    final results = await Future.wait([
      _icmFlotaConTops(db),
      _tendenciaIcmDiaria(db),
    ]);
    final flotaYTops = results[0] as _IcmFlotaYTops;
    final tendencia = results[1] as List<PuntoTendencia>;
    return KpisIcmHub(
      icmFlota: KpiIcm.fromActualYAnterior(
        flotaYTops.actual,
        flotaYTops.anterior,
        flotaYTops.choferesEnPromedio,
      ),
      tendenciaIcm: tendencia,
      top5Mejores: flotaYTops.top5Mejores,
      top5Peores: flotaYTops.top5Peores,
      periodoLabel: flotaYTops.periodo.isEmpty
          ? ''
          : IcmOficialService.labelPeriodo(flotaYTops.periodo),
    );
  }

  /// ICM OFICIAL de la flota del mes en curso vs el mes anterior + top 5
  /// mejores/peores. Filtra los DNIs excluidos (testers/tanques) con
  /// `ExcluidosService` + DNIs cuyo rol en EMPLEADOS no sea CHOFER
  /// (PLANTA / ADMIN / etc. quedan fuera del ranking ICM). Si el mes en
  /// curso no tiene doc aún, cae a 0 (la UI lo refleja con "—").
  static Future<_IcmFlotaYTops> _icmFlotaConTops(FirebaseFirestore db) async {
    final excluidos = await ExcluidosService.cargar(db: db);
    final dnisChofer = await ChoferesService.cargarDnisChofer(db: db);
    excluir(String dni) =>
        ExcluidosService.esExcluido(excluidos, dni: dni) ||
        (dnisChofer != null && !dnisChofer.contains(dni));
    final cargados = await Future.wait([
      IcmOficialService.cargarPeriodo(
        db,
        IcmOficialService.periodoId(),
        excluirDni: excluir,
      ),
      IcmOficialService.cargarPeriodo(
        db,
        IcmOficialService.periodoId(offsetMeses: -1),
        excluirDni: excluir,
      ),
    ]);
    final actual = cargados[0];
    final anterior = cargados[1];
    // El mes en curso recién arranca (días 1-2) → Sitrack todavía no calculó
    // su ICM mensual y el doc viene con actividad 0 (todos los choferes en
    // UNAVAILABLE_NO_ACTIVITY). En ese caso caemos al último mes CON actividad
    // (igual que la tendencia) para no mostrar el hub vacío al comienzo de cada
    // mes. Si tiene actividad real, usamos el mes en curso.
    final actualSirve =
        actual != null && actual.choferesConActividad.isNotEmpty;
    final fuente = actualSirve ? actual : anterior;
    if (fuente == null || fuente.choferesConActividad.isEmpty) {
      return const _IcmFlotaYTops(
        actual: 0,
        anterior: 0,
        choferesEnPromedio: 0,
        top5Mejores: [],
        top5Peores: [],
      );
    }
    // La comparativa "vs mes anterior" solo tiene sentido si la fuente es el
    // mes en curso; si caímos al anterior, no comparamos (0 → la UI pone "—").
    final comparativa = actualSirve ? (anterior?.icmGeneral ?? 0) : 0.0;
    return _IcmFlotaYTops(
      actual: fuente.icmGeneral,
      anterior: comparativa,
      choferesEnPromedio: fuente.choferesActivos,
      top5Mejores: fuente.mejores(5).map(_choferAItem).toList(),
      top5Peores: fuente.peores(5).map(_choferAItem).toList(),
      periodo: fuente.periodo,
    );
  }

  static ChoferRankingItem _choferAItem(IcmOficialChofer c) {
    return ChoferRankingItem(
      dni: c.dni,
      nombre: c.nombre.isEmpty ? 'DNI ${c.dni}' : c.nombre,
      icm: c.icm,
      categoria: _categoriaDeSeveridad(c.severidad),
    );
  }

  /// Severidad oficial Sitrack → etiqueta de color de la UI ('verde'/
  /// 'amarillo'/'rojo'/'gris'). Sin umbrales inventados: usamos la
  /// severidad ya calculada por Sitrack.
  static String _categoriaDeSeveridad(String severidad) {
    switch (severidadIcmDesde(severidad)) {
      case SeveridadIcm.alto:
        return 'rojo';
      case SeveridadIcm.medio:
        return 'amarillo';
      case SeveridadIcm.bajo:
      case SeveridadIcm.sinInfracciones:
        return 'verde';
      case SeveridadIcm.sinActividad:
      case SeveridadIcm.desconocida:
        return 'gris';
    }
  }

  /// Serie de tendencia diaria: ICM OFICIAL de la flota DÍA por DÍA del mes
  /// en curso (campo `tendencia_diaria` del doc `ICM_OFICIAL/{YYYY-MM}`).
  /// Si el mes recién arranca y aún no hay ≥2 días, cae al mes anterior
  /// para no mostrar un gráfico vacío.
  static Future<List<PuntoTendencia>> _tendenciaIcmDiaria(
      FirebaseFirestore db) async {
    Future<List<PuntoTendencia>> leer(String periodoId) async {
      final snap = await db
          .collection(IcmOficialService.coleccion)
          .doc(periodoId)
          .get();
      final raw = (snap.data()?['tendencia_diaria'] as List?) ?? const [];
      final pts = <PuntoTendencia>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final fecha = (e['fecha'] ?? '').toString(); // "YYYY-MM-DD"
        final icm = (e['icm'] as num?)?.toDouble();
        if (icm == null) continue;
        // Label = día del mes ("1".."31"), compacto para el eje X.
        final dia = fecha.length >= 10
            ? int.tryParse(fecha.substring(8, 10))?.toString() ?? fecha
            : fecha;
        pts.add(PuntoTendencia(label: dia, valor: icm));
      }
      return pts;
    }

    var pts = await leer(IcmOficialService.periodoId());
    if (pts.length < 2) {
      pts = await leer(IcmOficialService.periodoId(offsetMeses: -1));
    }
    return pts;
  }
}

/// Estructura interna del cálculo de ICM de la flota — agrupa actual,
/// anterior y los 2 top 5 para que `_icmFlotaConTops` no relea el doc.
class _IcmFlotaYTops {
  final double actual;
  final double anterior;
  final int choferesEnPromedio;
  final List<ChoferRankingItem> top5Mejores;
  final List<ChoferRankingItem> top5Peores;
  final String periodo;

  const _IcmFlotaYTops({
    required this.actual,
    required this.anterior,
    required this.choferesEnPromedio,
    required this.top5Mejores,
    required this.top5Peores,
    this.periodo = '',
  });
}
