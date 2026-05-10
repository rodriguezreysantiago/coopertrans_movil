import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/posiciones.dart';

/// Registro temporal inmutable de una instalación de cubierta en una
/// posición. Espejo conceptual de `AsignacionVehiculo` (chofer↔tractor)
/// pero para cubierta↔posición.
///
/// La instalación activa (la cubierta está actualmente en esa posición)
/// tiene `hasta == null`. Cuando se retira, se cierra (`hasta = now`,
/// `kmUnidadAlRetirar` y `kmRecorridos` calculados).
///
/// **Cálculo de km recorridos** (al cerrar):
/// - Tractor: `kmUnidadAlRetirar - kmUnidadAlInstalar` directo (los
///   km del tractor salen de Volvo via `VEHICULOS.KM_ACTUAL`).
/// - Enganche: cruzar con `ASIGNACIONES_ENGANCHE` (qué tractores
///   tuvieron el enganche en este período) y sumar los km de cada
///   tractor durante su sub-período. La lógica vive en `GomeriaService`.
class CubiertaInstalada {
  final String id;

  /// FK al doc en CUBIERTAS.
  final String cubiertaId;

  /// Snapshot del código legible de la cubierta (ej. "CUB-0042").
  /// Para listados sin join.
  final String cubiertaCodigo;

  /// Patente del tractor o enganche donde se instaló.
  final String unidadId;

  final TipoUnidadCubierta unidadTipo;

  /// Código de posición (ej. "DIR_IZQ", "ENG2_DER_INT"). Se mapea a
  /// `PosicionCubierta` con `posicionPorCodigo[posicion]`.
  final String posicion;

  /// Cantidad de vidas que tenía la cubierta AL INSTALAR. Útil para
  /// reportes ("cuánto duraron las cubiertas en su 1ra vida vs 2da").
  final int vidaAlInstalar;

  /// Snapshot de la etiqueta del modelo al instalar
  /// (ej. "Bridgestone R268 295/80R22.5 — Tracción"). Permite mostrar
  /// la cubierta en la grilla sin joinear contra CUBIERTAS y
  /// CUBIERTAS_MODELOS.
  final String? modeloEtiqueta;

  /// Snapshot de los km esperados para esta vida específica al
  /// instalar. Calculado del modelo en el momento del registro:
  /// `kmVidaEstimadaNueva` si era nueva (vidas=1) o
  /// `kmVidaEstimadaRecapada` si era recapada. `null` si el modelo no
  /// tenía valor configurado. Permite calcular el % de vida útil
  /// consumida sin tener que leer el modelo otra vez.
  final int? kmVidaEstimadaAlInstalar;

  /// Inicio de la instalación.
  final DateTime desde;

  /// Fin de la instalación (= retiro). `null` = activa.
  final DateTime? hasta;

  /// Km del odómetro de la unidad (tractor o enganche) al instalar.
  /// Para tractor: `VEHICULOS.KM_ACTUAL` al momento de instalar.
  /// Para enganche: este valor representa el "punto cero" del cálculo
  /// — los km recorridos por la cubierta se calculan con cruce contra
  /// ASIGNACIONES_ENGANCHE (no con el odómetro del enganche, que no
  /// existe).
  final double? kmUnidadAlInstalar;

  /// Km del odómetro al retirar. `null` = aún instalada.
  final double? kmUnidadAlRetirar;

  /// Km recorridos por la cubierta durante esta instalación. `null`
  /// hasta que se retire. Para tractor: diff directa. Para enganche:
  /// suma cruzada con ASIGNACIONES_ENGANCHE.
  final double? kmRecorridos;

  /// DNI del supervisor de gomería que registró la instalación.
  final String instaladoPorDni;
  final String? instaladoPorNombre;

  /// DNI del supervisor que registró el retiro (`null` si activa).
  final String? retiradoPorDni;
  final String? retiradoPorNombre;

  /// Texto libre opcional (ej. "rotación", "reemplazo por pinchazo").
  final String? motivo;

  /// Última lectura de presión (PSI) registrada por el supervisor de
  /// gomería. Pisada en cada control. `null` = nunca se midió.
  final int? ultimaPresionPsi;

  /// Última lectura de profundidad de banda (mm). Pisada en cada control.
  final double? ultimaProfundidadBandaMm;

  /// Cuándo fue la última lectura.
  final DateTime? ultimaLecturaEn;

  /// Quién registró la última lectura.
  final String? ultimaLecturaPorDni;
  final String? ultimaLecturaPorNombre;

  /// `true` si esta instalación fue creada por el script de carga
  /// inicial (`importar_cubiertas_legacy.py`, cohort 1). Significa que
  /// no tenemos datos históricos reales: la cubierta ya estaba montada
  /// físicamente cuando el sistema arrancó. La UI muestra una "L" en
  /// la cubierta para que el operador sepa que faltan datos previos
  /// (modelo "SIN IDENTIFICAR", vidas y km acumulados desconocidos).
  final bool legacyInicial;

  const CubiertaInstalada({
    required this.id,
    required this.cubiertaId,
    required this.cubiertaCodigo,
    required this.unidadId,
    required this.unidadTipo,
    required this.posicion,
    required this.vidaAlInstalar,
    required this.modeloEtiqueta,
    required this.kmVidaEstimadaAlInstalar,
    required this.desde,
    required this.hasta,
    required this.kmUnidadAlInstalar,
    required this.kmUnidadAlRetirar,
    required this.kmRecorridos,
    required this.instaladoPorDni,
    required this.instaladoPorNombre,
    required this.retiradoPorDni,
    required this.retiradoPorNombre,
    required this.motivo,
    required this.ultimaPresionPsi,
    required this.ultimaProfundidadBandaMm,
    required this.ultimaLecturaEn,
    required this.ultimaLecturaPorDni,
    required this.ultimaLecturaPorNombre,
    this.legacyInicial = false,
  });

  bool get esActiva => hasta == null;

  /// Días que duró la instalación. Si activa, contra ahora.
  int diasDuracion() {
    final fin = hasta ?? DateTime.now();
    return fin.difference(desde).inDays;
  }

  /// % de vida útil consumida en esta instalación, en base al km actual
  /// de la unidad y los km esperados snapshot al instalar.
  ///
  /// Devuelve `null` si:
  /// - no hay snapshot de km esperados (modelo sin valor configurado), o
  /// - es enganche y aún no tenemos km cubierta (Fase 2 pendiente), o
  /// - falta el km de la unidad.
  ///
  /// Puede pasar de 100% — la cubierta excedió su vida estimada.
  double? porcentajeVidaConsumida({double? kmActualUnidad}) {
    final esperados = kmVidaEstimadaAlInstalar;
    if (esperados == null || esperados <= 0) return null;
    final base = kmUnidadAlInstalar;
    if (base == null) return null;
    final actual = kmUnidadAlRetirar ?? kmActualUnidad;
    if (actual == null) return null;
    final recorridos = actual - base;
    if (recorridos < 0) return 0;
    return (recorridos / esperados) * 100;
  }

  /// Posición tipada (resuelta del campo `posicion` string).
  PosicionCubierta? get posicionTipada => posicionPorCodigo[posicion];

  factory CubiertaInstalada.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      CubiertaInstalada.fromMap(doc.id, doc.data());

  factory CubiertaInstalada.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return CubiertaInstalada(
      id: id,
      cubiertaId: (d['cubierta_id'] ?? '').toString(),
      cubiertaCodigo: (d['cubierta_codigo'] ?? '').toString(),
      unidadId: (d['unidad_id'] ?? '').toString(),
      // No enmascarar valores corruptos: si `unidad_tipo` viene mal
      // tirar excepción explícita (antes cualquier valor != 'ENGANCHE'
      // caía a tractor por default y ocultaba bugs de escritura).
      unidadTipo: switch (d['unidad_tipo']?.toString().toUpperCase()) {
        'TRACTOR' => TipoUnidadCubierta.tractor,
        'ENGANCHE' => TipoUnidadCubierta.enganche,
        final otro => throw StateError(
            'CUBIERTAS_INSTALADAS/$id tiene unidad_tipo inválido: $otro',
          ),
      },
      posicion: (d['posicion'] ?? '').toString(),
      vidaAlInstalar: (d['vida_al_instalar'] as num?)?.toInt() ?? 1,
      modeloEtiqueta: d['modelo_etiqueta']?.toString(),
      kmVidaEstimadaAlInstalar:
          (d['km_vida_estimada_al_instalar'] as num?)?.toInt(),
      desde: (d['desde'] as Timestamp?)?.toDate() ?? DateTime.now(),
      hasta: (d['hasta'] as Timestamp?)?.toDate(),
      kmUnidadAlInstalar: (d['km_unidad_al_instalar'] as num?)?.toDouble(),
      kmUnidadAlRetirar: (d['km_unidad_al_retirar'] as num?)?.toDouble(),
      kmRecorridos: (d['km_recorridos'] as num?)?.toDouble(),
      instaladoPorDni: (d['instalado_por_dni'] ?? '').toString(),
      instaladoPorNombre: d['instalado_por_nombre']?.toString(),
      retiradoPorDni: d['retirado_por_dni']?.toString(),
      retiradoPorNombre: d['retirado_por_nombre']?.toString(),
      motivo: d['motivo']?.toString(),
      ultimaPresionPsi: (d['ultima_presion_psi'] as num?)?.toInt(),
      ultimaProfundidadBandaMm:
          (d['ultima_profundidad_banda_mm'] as num?)?.toDouble(),
      ultimaLecturaEn: (d['ultima_lectura_en'] as Timestamp?)?.toDate(),
      ultimaLecturaPorDni: d['ultima_lectura_por_dni']?.toString(),
      ultimaLecturaPorNombre: d['ultima_lectura_por_nombre']?.toString(),
      legacyInicial: d['legacy_inicial'] == true,
    );
  }
}
