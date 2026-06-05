// Constantes de posiciones de cubiertas para el módulo Gomería.
//
// Layout fijo confirmado por Santiago el 2026-05-04 (eje neumático corregido a
// ARRASTRE el 2026-06-05):
// - Tractor: 3 ejes (1 dirección, 1 tracción dual, 1 arrastre dual=neumático)
//   = 10 posiciones.
// - Enganche: 3 ejes (todos con duales en cada lado) = 12 posiciones.
//
// Si la flota suma un layout distinto en el futuro (tractor 6x2, enganche
// con eje extra), modelar como variante por TIPO de unidad — por ahora
// es uniforme.

/// Tipo de uso de la cubierta. Define en qué posiciones se puede
/// instalar — la validación es ESTRICTA: cada tipo va solo en su posición
/// (DIRECCIÓN → eje delantero del tractor; TRACCIÓN → ejes motrices del
/// tractor; ARRASTRE → ejes del enganche, libres). Confirmado por Santiago:
/// "que no le permita, sería un error de tipeo seguramente".
enum TipoUsoCubierta {
  direccion('DIRECCION', 'Dirección'),
  traccion('TRACCION', 'Tracción'),
  arrastre('ARRASTRE', 'Arrastre');

  final String codigo;
  final String etiqueta;
  const TipoUsoCubierta(this.codigo, this.etiqueta);

  static TipoUsoCubierta? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final t in values) {
      if (t.codigo == c) return t;
    }
    return null;
  }
}

/// Tipo de unidad sobre la que se instala una cubierta.
enum TipoUnidadCubierta {
  tractor('TRACTOR'),
  enganche('ENGANCHE');

  final String codigo;
  const TipoUnidadCubierta(this.codigo);
}

/// Una posición concreta donde puede haber una cubierta.
///
/// Inmutable, conocida en compile-time. Se usan como claves en mapas
/// (ej. para mostrar el estado actual de un tractor: `Map<PosicionCubierta,
/// CubiertaInstalada?>`). El `codigo` es la clave string que se guarda
/// en Firestore (`CUBIERTAS_INSTALADAS.posicion`).
class PosicionCubierta {
  /// Código único usado en Firestore (ej. "DIR_IZQ", "TRAC1_DER_INT").
  final String codigo;

  /// Etiqueta legible al operador (ej. "Dirección izquierda").
  final String etiqueta;

  /// Tipo de uso requerido para instalar una cubierta acá.
  final TipoUsoCubierta tipoUsoRequerido;

  /// Tipo de unidad al que pertenece esta posición.
  final TipoUnidadCubierta tipoUnidad;

  /// Eje al que pertenece (1, 2, 3, ...). Útil para agrupar visualmente.
  final int eje;

  /// Lado: 'IZQ' o 'DER'. Las posiciones de dirección tienen lado pero
  /// no interno/externo (ruedas simples). Las de tracción dual tienen
  /// los 4: IZQ_EXT, IZQ_INT, DER_INT, DER_EXT.
  final String lado;

  /// `true` si esta posición admite cubiertas RECAPADAS (vida ≥ 2). Si es
  /// `false`, solo se pueden montar NUEVAS (vida 1). Regla Vecchi 2026-06-05:
  /// las recapadas van SOLO en los ejes LIBRES designados — el eje neumático
  /// del tractor y el PRIMER eje del enganche. Dirección, tracción y el resto
  /// del enganche: solo nuevas (ejes críticos / seguridad). Default `false`
  /// (conservador): una posición es solo-nuevas salvo que se la habilite.
  final bool permiteRecapada;

  const PosicionCubierta({
    required this.codigo,
    required this.etiqueta,
    required this.tipoUsoRequerido,
    required this.tipoUnidad,
    required this.eje,
    required this.lado,
    this.permiteRecapada = false,
  });

  /// `true` si una cubierta con [tipoUso] puede ir en esta posición.
  bool aceptaTipoUso(TipoUsoCubierta tipoUso) =>
      tipoUso == tipoUsoRequerido;
}

// =============================================================================
// LAYOUT TRACTOR — 10 posiciones
// =============================================================================
// Eje 1: dirección (2 posiciones simples, IZQ + DER)
// Eje 2: tracción duales (4: IZQ_EXT, IZQ_INT, DER_INT, DER_EXT) — eje motriz.
// Eje 3: ARRASTRE duales (4: IZQ_EXT, IZQ_INT, DER_INT, DER_EXT) — eje neumático
//        (suspensión de aire), LIBRE/no motriz → lleva arrastre, no tracción.
//        Confirmado Santiago 2026-06-05 (corrección del modelado original, que
//        lo tenía como tracción). El `codigo` TRAC2_* se mantiene para no
//        romper montajes/locks ya referenciados — es solo identificador.

const PosicionCubierta posTractorDirIzq = PosicionCubierta(
  codigo: 'DIR_IZQ',
  etiqueta: 'Dirección Izquierda',
  tipoUsoRequerido: TipoUsoCubierta.direccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 1,
  lado: 'IZQ',
);

const PosicionCubierta posTractorDirDer = PosicionCubierta(
  codigo: 'DIR_DER',
  etiqueta: 'Dirección Derecha',
  tipoUsoRequerido: TipoUsoCubierta.direccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 1,
  lado: 'DER',
);

const PosicionCubierta posTractorTrac1IzqExt = PosicionCubierta(
  codigo: 'TRAC1_IZQ_EXT',
  etiqueta: 'Tracción 1 Izquierda Externa',
  tipoUsoRequerido: TipoUsoCubierta.traccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 2,
  lado: 'IZQ_EXT',
);
const PosicionCubierta posTractorTrac1IzqInt = PosicionCubierta(
  codigo: 'TRAC1_IZQ_INT',
  etiqueta: 'Tracción 1 Izquierda Interna',
  tipoUsoRequerido: TipoUsoCubierta.traccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 2,
  lado: 'IZQ_INT',
);
const PosicionCubierta posTractorTrac1DerInt = PosicionCubierta(
  codigo: 'TRAC1_DER_INT',
  etiqueta: 'Tracción 1 Derecha Interna',
  tipoUsoRequerido: TipoUsoCubierta.traccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 2,
  lado: 'DER_INT',
);
const PosicionCubierta posTractorTrac1DerExt = PosicionCubierta(
  codigo: 'TRAC1_DER_EXT',
  etiqueta: 'Tracción 1 Derecha Externa',
  tipoUsoRequerido: TipoUsoCubierta.traccion,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 2,
  lado: 'DER_EXT',
);

const PosicionCubierta posTractorTrac2IzqExt = PosicionCubierta(
  codigo: 'TRAC2_IZQ_EXT',
  etiqueta: 'Eje neumático Izquierda Externa',
  tipoUsoRequerido: TipoUsoCubierta.arrastre,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 3,
  lado: 'IZQ_EXT',
  permiteRecapada: true, // eje libre → admite recapadas
);
const PosicionCubierta posTractorTrac2IzqInt = PosicionCubierta(
  codigo: 'TRAC2_IZQ_INT',
  etiqueta: 'Eje neumático Izquierda Interna',
  tipoUsoRequerido: TipoUsoCubierta.arrastre,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 3,
  lado: 'IZQ_INT',
  permiteRecapada: true, // eje libre → admite recapadas
);
const PosicionCubierta posTractorTrac2DerInt = PosicionCubierta(
  codigo: 'TRAC2_DER_INT',
  etiqueta: 'Eje neumático Derecha Interna',
  tipoUsoRequerido: TipoUsoCubierta.arrastre,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 3,
  lado: 'DER_INT',
  permiteRecapada: true, // eje libre → admite recapadas
);
const PosicionCubierta posTractorTrac2DerExt = PosicionCubierta(
  codigo: 'TRAC2_DER_EXT',
  etiqueta: 'Eje neumático Derecha Externa',
  tipoUsoRequerido: TipoUsoCubierta.arrastre,
  tipoUnidad: TipoUnidadCubierta.tractor,
  eje: 3,
  lado: 'DER_EXT',
  permiteRecapada: true, // eje libre → admite recapadas
);

/// Las 10 posiciones del tractor estándar de Coopertrans, en orden
/// para mostrar consistente (eje 1 → eje 2 → eje 3, IZQ→DER, EXT→INT).
const List<PosicionCubierta> posicionesTractor = [
  posTractorDirIzq,
  posTractorDirDer,
  posTractorTrac1IzqExt,
  posTractorTrac1IzqInt,
  posTractorTrac1DerInt,
  posTractorTrac1DerExt,
  posTractorTrac2IzqExt,
  posTractorTrac2IzqInt,
  posTractorTrac2DerInt,
  posTractorTrac2DerExt,
];

// =============================================================================
// LAYOUT ENGANCHE — 12 posiciones
// =============================================================================
// 3 ejes, todos con duales en cada lado (4 ruedas por eje × 3 ejes = 12).
// Confirmado por Santiago: todos los enganches (BATEAS, TOLVAS,
// BIVUELCOS, TANQUES) tienen el MISMO layout. Si en el futuro hay
// una variante, modelar como override por TIPO de unidad.
//
// Todas las posiciones de enganche son ARRASTRE (ejes libres: ni dirección
// ni tracción). Antes estaban como TRACCIÓN por falta del tipo ARRASTRE.

List<PosicionCubierta> _generarEjeEnganche(int eje) {
  // Regla Vecchi 2026-06-05: las cubiertas RECAPADAS solo se montan en el
  // PRIMER eje del enganche. Los ejes 2 y 3 solo admiten nuevas.
  final permiteRec = eje == 1;
  return [
    PosicionCubierta(
      codigo: 'ENG${eje}_IZQ_EXT',
      etiqueta: 'Eje $eje Izquierda Externa',
      tipoUsoRequerido: TipoUsoCubierta.arrastre,
      tipoUnidad: TipoUnidadCubierta.enganche,
      eje: eje,
      lado: 'IZQ_EXT',
      permiteRecapada: permiteRec,
    ),
    PosicionCubierta(
      codigo: 'ENG${eje}_IZQ_INT',
      etiqueta: 'Eje $eje Izquierda Interna',
      tipoUsoRequerido: TipoUsoCubierta.arrastre,
      tipoUnidad: TipoUnidadCubierta.enganche,
      eje: eje,
      lado: 'IZQ_INT',
      permiteRecapada: permiteRec,
    ),
    PosicionCubierta(
      codigo: 'ENG${eje}_DER_INT',
      etiqueta: 'Eje $eje Derecha Interna',
      tipoUsoRequerido: TipoUsoCubierta.arrastre,
      tipoUnidad: TipoUnidadCubierta.enganche,
      eje: eje,
      lado: 'DER_INT',
      permiteRecapada: permiteRec,
    ),
    PosicionCubierta(
      codigo: 'ENG${eje}_DER_EXT',
      etiqueta: 'Eje $eje Derecha Externa',
      tipoUsoRequerido: TipoUsoCubierta.arrastre,
      tipoUnidad: TipoUnidadCubierta.enganche,
      eje: eje,
      lado: 'DER_EXT',
      permiteRecapada: permiteRec,
    ),
  ];
}

/// Las 12 posiciones del enganche estándar de Coopertrans (3 ejes × 4
/// ruedas duales). En orden: eje 1 → eje 2 → eje 3, IZQ→DER, EXT→INT.
final List<PosicionCubierta> posicionesEnganche = [
  ..._generarEjeEnganche(1),
  ..._generarEjeEnganche(2),
  ..._generarEjeEnganche(3),
];

/// Mapa rápido `codigo → PosicionCubierta` para resolver desde lo que
/// se guarda en Firestore al objeto Dart.
final Map<String, PosicionCubierta> posicionPorCodigo = {
  for (final p in posicionesTractor) p.codigo: p,
  for (final p in posicionesEnganche) p.codigo: p,
};

/// Devuelve las posiciones de la unidad según su tipo. Para tractor
/// son 10 fijas; para enganche son las 12 fijas (todos los enganches
/// tienen el mismo layout).
List<PosicionCubierta> posicionesParaUnidad(TipoUnidadCubierta tipo) {
  switch (tipo) {
    case TipoUnidadCubierta.tractor:
      return posicionesTractor;
    case TipoUnidadCubierta.enganche:
      return posicionesEnganche;
  }
}

/// Estados posibles del ciclo de vida de una cubierta. Guardados
/// en Firestore como string (campo `CUBIERTAS.estado`).
enum EstadoCubierta {
  /// Cubierta en el depósito de gomería, lista para instalar.
  enDeposito('EN_DEPOSITO'),

  /// Instalada en una posición de un tractor o enganche. Ver
  /// `CUBIERTAS_INSTALADAS` con `hasta == null` para saber dónde.
  instalada('INSTALADA'),

  /// En el proveedor de recapado. Ver `CUBIERTAS_RECAPADOS` con
  /// `fecha_retorno == null` para detalle.
  enRecapado('EN_RECAPADO'),

  /// Fin de vida útil. No se puede reinstalar ni recapar.
  descartada('DESCARTADA');

  final String codigo;
  const EstadoCubierta(this.codigo);

  static EstadoCubierta? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final e in values) {
      if (e.codigo == c) return e;
    }
    return null;
  }
}

/// Resultado del proceso de recapado (campo `CUBIERTAS_RECAPADOS.resultado`).
enum ResultadoRecapado {
  /// El proveedor recapó la cubierta exitosamente, vuelve al depósito
  /// con `vidas++`.
  recibida('RECIBIDA'),

  /// El proveedor evaluó la cubierta y NO la recapó (estructura
  /// dañada, etc). La cubierta queda DESCARTADA.
  descartadaPorProveedor('DESCARTADA_POR_PROVEEDOR');

  final String codigo;
  const ResultadoRecapado(this.codigo);

  static ResultadoRecapado? fromCodigo(String? codigo) {
    if (codigo == null) return null;
    final c = codigo.toUpperCase().trim();
    for (final r in values) {
      if (r.codigo == c) return r;
    }
    return null;
  }
}
