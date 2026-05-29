import 'package:cloud_firestore/cloud_firestore.dart';

import '../constants/posiciones.dart';

/// Motivo por el que se retira una cubierta de una posición. Alimenta
/// estadísticas de gomería (¿cuántas salen por desgaste vs pinchazo?).
enum MotivoRetiro {
  desgaste('DESGASTE', 'Desgaste'),
  pinchazo('PINCHAZO', 'Pinchazo / rotura'),
  rotacion('ROTACION', 'Rotación'),
  dano('DANO', 'Daño'),
  otro('OTRO', 'Otro');

  final String codigo;
  final String etiqueta;
  const MotivoRetiro(this.codigo, this.etiqueta);

  static MotivoRetiro? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final m in values) {
      if (m.codigo == c) return m;
    }
    return null;
  }
}

/// Destino de la cubierta cuando se retira de una posición.
enum DestinoRetiro {
  /// Vuelve al depósito (usada, sirve para otra posición o más adelante).
  deposito('DEPOSITO', 'Al depósito'),

  /// Se manda al proveedor a recapar.
  recapado('RECAPADO', 'A recapar'),

  /// Fin de vida útil — se da de baja.
  descarte('DESCARTE', 'Descartar');

  final String codigo;
  final String etiqueta;
  const DestinoRetiro(this.codigo, this.etiqueta);

  static DestinoRetiro? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final d in values) {
      if (d.codigo == c) return d;
    }
    return null;
  }
}

/// Un MONTAJE: una cubierta de cierto MODELO y VIDA montada en una
/// POSICIÓN de una unidad durante un período. Es el corazón del modelo
/// REDISEÑADO (2026-05-29).
///
/// A diferencia del modelo viejo (`CubiertaInstalada`), NO serializa la
/// cubierta individual (no hay `CUB-XXXX`): la identidad de lo que está
/// montado es `(unidad, posición, período)`, y la cubierta se describe
/// por su `modeloId` + `vida` (1 = nueva, 2+ = recapada N). El estado se
/// ESTIMA por km recorridos vs la vida esperada del modelo (decisión
/// Santiago: "por la marca y la distancia recorrida sabemos el estado").
///
/// El montaje ACTIVO tiene `hasta == null`. Al retirar se cierra
/// (`hasta`, `kmUnidadAlRetirar`, `kmRecorridos`, `motivoRetiro`, `destino`).
///
/// **km recorridos**:
/// - Tractor: `kmUnidadAlRetirar - kmUnidadAlMontar` directo (odómetro
///   Volvo via `VEHICULOS.KM_ACTUAL` / `TELEMETRIA_HISTORICO`).
/// - Enganche: cálculo robusto cruzando las duplas tractor↔enganche
///   (`ASIGNACIONES_ENGANCHE`) con el odómetro histórico del tractor —
///   los enganches no tienen odómetro propio. Lo resuelve `GomeriaService`.
class Montaje {
  final String id;

  /// Patente del tractor o enganche.
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;

  /// Código de posición (ej. "DIR_IZQ", "ENG2_DER_INT"). Se resuelve con
  /// `posicionPorCodigo[posicion]`.
  final String posicion;

  /// FK a `CUBIERTAS_MODELOS` — define marca + medida + tipo de uso + km
  /// de vida esperados.
  final String modeloId;

  /// Snapshot de la etiqueta del modelo al montar
  /// (ej. "Bridgestone R268 295/80R22.5 — Tracción"). Para listados sin join.
  final String modeloEtiqueta;

  /// Snapshot del tipo de uso (para validar posición sin leer el modelo).
  final TipoUsoCubierta tipoUso;

  /// Vida de la cubierta montada: 1 = nueva, 2 = recapada 1ª vez, etc.
  final int vida;

  /// Snapshot de los km esperados para ESTA vida (de `CUBIERTAS_MODELOS`
  /// según `vida`). `null` si el modelo no tiene el valor configurado →
  /// el % de vida no se puede estimar.
  final int? kmVidaEstimada;

  /// Inicio del montaje.
  final DateTime desde;

  /// Fin del montaje (retiro). `null` = activo.
  final DateTime? hasta;

  /// Odómetro de la unidad al montar. Tractor: `KM_ACTUAL`. Enganche:
  /// "punto cero" — los km reales se calculan por las duplas.
  final double? kmUnidadAlMontar;

  /// Odómetro al retirar. `null` mientras está activo.
  final double? kmUnidadAlRetirar;

  /// Km recorridos por la cubierta en este montaje. `null` hasta retirar
  /// (o hasta que el cálculo robusto lo resuelva en vivo para enganches).
  final double? kmRecorridos;

  final String montadoPorDni;
  final String? montadoPorNombre;

  final String? retiradoPorDni;
  final String? retiradoPorNombre;

  /// Por qué se retiró (`null` mientras está activo).
  final MotivoRetiro? motivoRetiro;

  /// A dónde fue la cubierta tras retirarla (`null` mientras está activo).
  final DestinoRetiro? destino;

  const Montaje({
    required this.id,
    required this.unidadId,
    required this.unidadTipo,
    required this.posicion,
    required this.modeloId,
    required this.modeloEtiqueta,
    required this.tipoUso,
    required this.vida,
    required this.kmVidaEstimada,
    required this.desde,
    required this.hasta,
    required this.kmUnidadAlMontar,
    required this.kmUnidadAlRetirar,
    required this.kmRecorridos,
    required this.montadoPorDni,
    required this.montadoPorNombre,
    required this.retiradoPorDni,
    required this.retiradoPorNombre,
    required this.motivoRetiro,
    required this.destino,
  });

  bool get esActivo => hasta == null;

  /// `true` si la cubierta montada es recapada (vida > 1).
  bool get esRecapada => vida > 1;

  /// Etiqueta de la vida ("Nueva", "Recapada 1", "Recapada 2"...).
  String get etiquetaVida =>
      vida <= 1 ? 'Nueva' : 'Recapada ${vida - 1}';

  /// Días que duró el montaje. Si activo, contra ahora.
  int diasDuracion() => (hasta ?? DateTime.now()).difference(desde).inDays;

  /// % de vida útil consumida (puede pasar de 100% si excedió la estimación).
  ///
  /// Resolución de los km recorridos, en orden de prioridad:
  /// 1. `kmRecorridos` ya persistido (montaje cerrado).
  /// 2. `kmRecorridosCalculado` que pasa el caller (cálculo robusto en vivo,
  ///    necesario para ENGANCHES que no tienen odómetro propio).
  /// 3. `kmActualUnidad - kmUnidadAlMontar` (TRACTOR en vivo).
  ///
  /// Devuelve `null` si falta el km de vida esperado o no se pudo resolver
  /// ningún km recorrido.
  double? porcentajeVidaConsumida({
    double? kmActualUnidad,
    double? kmRecorridosCalculado,
  }) {
    final esperados = kmVidaEstimada;
    if (esperados == null || esperados <= 0) return null;

    double? recorridos = kmRecorridos ?? kmRecorridosCalculado;
    if (recorridos == null) {
      // Capturar el campo en local para que Dart lo promueva a no-null.
      final base = kmUnidadAlMontar;
      if (kmActualUnidad != null && base != null) {
        recorridos = kmActualUnidad - base;
      }
    }
    if (recorridos == null) return null;
    if (recorridos < 0) return 0;
    return (recorridos / esperados) * 100;
  }

  /// Posición tipada (resuelta del campo `posicion`).
  PosicionCubierta? get posicionTipada => posicionPorCodigo[posicion];

  factory Montaje.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Montaje.fromMap(doc.id, doc.data());

  factory Montaje.fromMap(String id, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    return Montaje(
      id: id,
      unidadId: (d['unidad_id'] ?? '').toString(),
      unidadTipo: switch (d['unidad_tipo']?.toString().toUpperCase()) {
        'TRACTOR' => TipoUnidadCubierta.tractor,
        'ENGANCHE' => TipoUnidadCubierta.enganche,
        final otro => throw StateError(
            'GOMERIA_MONTAJES/$id tiene unidad_tipo inválido: $otro',
          ),
      },
      posicion: (d['posicion'] ?? '').toString(),
      modeloId: (d['modelo_id'] ?? '').toString(),
      modeloEtiqueta: (d['modelo_etiqueta'] ?? '').toString(),
      tipoUso: TipoUsoCubierta.fromCodigo(d['tipo_uso']?.toString()) ??
          TipoUsoCubierta.traccion,
      vida: (d['vida'] as num?)?.toInt() ?? 1,
      kmVidaEstimada: (d['km_vida_estimada'] as num?)?.toInt(),
      desde: (d['desde'] as Timestamp?)?.toDate() ?? DateTime.now(),
      hasta: (d['hasta'] as Timestamp?)?.toDate(),
      kmUnidadAlMontar: (d['km_unidad_al_montar'] as num?)?.toDouble(),
      kmUnidadAlRetirar: (d['km_unidad_al_retirar'] as num?)?.toDouble(),
      kmRecorridos: (d['km_recorridos'] as num?)?.toDouble(),
      montadoPorDni: (d['montado_por_dni'] ?? '').toString(),
      montadoPorNombre: d['montado_por_nombre']?.toString(),
      retiradoPorDni: d['retirado_por_dni']?.toString(),
      retiradoPorNombre: d['retirado_por_nombre']?.toString(),
      motivoRetiro: MotivoRetiro.fromCodigo(d['motivo_retiro']?.toString()),
      destino: DestinoRetiro.fromCodigo(d['destino']?.toString()),
    );
  }

  /// Mapa para crear un montaje nuevo (activo). Los campos de retiro van
  /// `null` y se completan al cerrar.
  Map<String, dynamic> toMapNuevo() => {
        'unidad_id': unidadId,
        'unidad_tipo': unidadTipo.codigo,
        'posicion': posicion,
        'modelo_id': modeloId,
        'modelo_etiqueta': modeloEtiqueta,
        'tipo_uso': tipoUso.codigo,
        'vida': vida,
        'km_vida_estimada': kmVidaEstimada,
        'desde': Timestamp.fromDate(desde),
        'hasta': null,
        'km_unidad_al_montar': kmUnidadAlMontar,
        'km_unidad_al_retirar': null,
        'km_recorridos': null,
        'montado_por_dni': montadoPorDni,
        'montado_por_nombre': montadoPorNombre,
        'retirado_por_dni': null,
        'retirado_por_nombre': null,
        'motivo_retiro': null,
        'destino': null,
      };
}
