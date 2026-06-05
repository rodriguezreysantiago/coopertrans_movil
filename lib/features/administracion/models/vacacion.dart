// lib/features/administracion/models/vacacion.dart
//
// Modelo del módulo Administración > Vacaciones.
//
// Un [Vacacion] = el registro de vacaciones de UN empleado en UN año
// devengado. Espeja la hoja madre del Excel "VACACIONES <año>".
//
// PRINCIPIO (pedido Santiago 2026-06-05): NO repetir información que ya vive
// en EMPLEADOS. Este doc guarda SOLO lo propio de vacaciones:
//   - `dni`  → clave para vincular con el legajo (identidad vive en EMPLEADOS).
//   - `anio` → año devengado.
//   - `diasCorresponden` + `diasAuto` → días que corresponden (autocalculables
//     por antigüedad; `diasAuto=false` marca override manual).
//   - `periodos` → los tramos de goce.
// El nombre / empresa / área se LEEN de EMPLEADOS al armar la vista (join por
// DNI). `tomados` y `restan` se DERIVAN de los períodos — no se persisten (no
// duplicamos un dato que se calcula).

import 'package:cloud_firestore/cloud_firestore.dart';

/// Normaliza un DateTime a día (medianoche local, sin hora) para comparar y
/// persistir fechas de vacaciones de forma estable (el operador piensa en
/// días; evita corrimientos por zona horaria).
DateTime soloDia(DateTime d) => DateTime(d.year, d.month, d.day);

/// Un tramo de vacaciones: del [inicio] al [fin], ambos inclusive.
class PeriodoVacaciones {
  final DateTime inicio;
  final DateTime fin;

  PeriodoVacaciones({required DateTime inicio, required DateTime fin})
      : inicio = soloDia(inicio),
        fin = soloDia(fin);

  /// Días corridos del tramo (inclusive ambos extremos), como manda la LCT.
  /// Ej: 05-01 al 18-01 = 14 días. Nunca negativo.
  int get dias {
    final d = fin.difference(inicio).inDays + 1;
    return d < 0 ? 0 : d;
  }

  factory PeriodoVacaciones.fromMap(Map<String, dynamic> m) {
    final ini = (m['inicio'] as Timestamp?)?.toDate() ?? DateTime(2000);
    final f = (m['fin'] as Timestamp?)?.toDate() ?? ini;
    return PeriodoVacaciones(inicio: ini, fin: f);
  }

  /// Persistimos solo inicio/fin (la fuente de verdad del tramo). `dias` es
  /// derivado — no se guarda.
  Map<String, dynamic> toMap() => {
        'inicio': Timestamp.fromDate(inicio),
        'fin': Timestamp.fromDate(fin),
      };

  /// ¿Se solapa con [otro]? (para detectar tramos pisados al cargar).
  bool seSolapaCon(PeriodoVacaciones otro) =>
      !inicio.isAfter(otro.fin) && !otro.inicio.isAfter(fin);
}

class Vacacion {
  /// DNI del empleado — clave para vincular con EMPLEADOS (de donde salen
  /// nombre/empresa/área al armar la vista).
  final String dni;

  /// Año devengado (ej. 2025), aunque los períodos caigan en el año siguiente.
  final int anio;

  /// Días de vacaciones que corresponden este año.
  final int diasCorresponden;

  /// `true` = vino del cálculo automático por antigüedad y puede recalcularse.
  /// `false` = lo editó la oficina a mano (override) → respetar.
  final bool diasAuto;

  /// Tramos de goce (ordenados por inicio asc).
  final List<PeriodoVacaciones> periodos;

  final DateTime? actualizadoEn;
  final String? actualizadoPorDni;

  Vacacion({
    required this.dni,
    required this.anio,
    required this.diasCorresponden,
    this.diasAuto = true,
    List<PeriodoVacaciones> periodos = const [],
    this.actualizadoEn,
    this.actualizadoPorDni,
  }) : periodos = _ordenar(periodos);

  static List<PeriodoVacaciones> _ordenar(List<PeriodoVacaciones> ps) {
    final l = [...ps]..sort((a, b) => a.inicio.compareTo(b.inicio));
    return List.unmodifiable(l);
  }

  /// Id determinístico del doc: `<anio>_<dni>`. 1 por empleado/año.
  String get docId => idDe(anio, dni);
  static String idDe(int anio, String dni) => '${anio}_$dni';

  /// Días ya tomados = suma de los días corridos de cada período (DERIVADO).
  int get tomados => periodos.fold(0, (acc, p) => acc + p.dias);

  /// Días que quedan por tomar (DERIVADO). Puede ser negativo si cargaron de
  /// más (lo dejamos visible como señal de error, no se clampa a 0).
  int get restan => diasCorresponden - tomados;

  /// ¿Hay algún par de períodos solapados? (señal de carga inconsistente).
  bool get tienePeriodosSolapados {
    for (var i = 0; i < periodos.length; i++) {
      for (var j = i + 1; j < periodos.length; j++) {
        if (periodos[i].seSolapaCon(periodos[j])) return true;
      }
    }
    return false;
  }

  factory Vacacion.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) =>
      Vacacion.fromMap(doc.data() ?? const {});

  factory Vacacion.fromMap(Map<String, dynamic> m) {
    final rawPeriodos = (m['periodos'] as List?) ?? const [];
    return Vacacion(
      dni: (m['dni'] ?? '').toString(),
      anio: (m['anio'] as num?)?.toInt() ?? 0,
      diasCorresponden: (m['diasCorresponden'] as num?)?.toInt() ?? 0,
      diasAuto: m['diasAuto'] as bool? ?? true,
      periodos: rawPeriodos
          .whereType<Map>()
          .map((e) => PeriodoVacaciones.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
      actualizadoEn: (m['actualizadoEn'] as Timestamp?)?.toDate(),
      actualizadoPorDni: m['actualizadoPorDni']?.toString(),
    );
  }

  /// Mapa para persistir — SOLO datos propios de vacaciones. nombre/empresa/
  /// área NO se guardan (viven en EMPLEADOS); tomados/restan tampoco (se
  /// derivan). `actualizadoEn` lo setea el service con serverTimestamp.
  Map<String, dynamic> toMap() => {
        'dni': dni,
        'anio': anio,
        'diasCorresponden': diasCorresponden,
        'diasAuto': diasAuto,
        'periodos': periodos.map((p) => p.toMap()).toList(),
        if (actualizadoPorDni != null) 'actualizadoPorDni': actualizadoPorDni,
      };

  Vacacion copyWith({
    int? diasCorresponden,
    bool? diasAuto,
    List<PeriodoVacaciones>? periodos,
    String? actualizadoPorDni,
  }) =>
      Vacacion(
        dni: dni,
        anio: anio,
        diasCorresponden: diasCorresponden ?? this.diasCorresponden,
        diasAuto: diasAuto ?? this.diasAuto,
        periodos: periodos ?? this.periodos,
        actualizadoEn: actualizadoEn,
        actualizadoPorDni: actualizadoPorDni ?? this.actualizadoPorDni,
      );
}
