// lib/features/administracion/models/vacacion.dart
//
// Modelo del módulo Administración > Vacaciones.
//
// Un [Vacacion] = el registro de vacaciones de UN empleado en UN año
// devengado. Espeja la hoja madre del Excel "VACACIONES <año>": días que
// corresponden + tomados + restan + los períodos de goce (inicio/fin).
//
// Decisiones de modelado:
//   - La identidad del empleado (nombre, empresa, área, ingreso, CUIL) vive
//     en EMPLEADOS. Acá guardamos solo `dni` + una COPIA de nombre/empresa/
//     área para listar y agrupar sin cruzar tablas (snapshot liviano).
//   - `diasCorresponden` lo autocompleta la app por antigüedad (LCT, ver
//     vacaciones_calculo.dart); `diasAuto=false` marca un override manual
//     (proporcionales de 1er año, casos especiales) que NO se recalcula.
//   - `tomados` y `restan` se DERIVAN de los períodos — no son una resta a
//     mano (origen de errores en el Excel). `tomados` se persiste igual para
//     que la vista de saldos no tenga que expandir períodos.

import 'package:cloud_firestore/cloud_firestore.dart';

/// Normaliza un DateTime a día (medianoche local, sin hora) para comparar y
/// persistir fechas de vacaciones de forma estable (el operador piensa en
/// días, no en horas; evita corrimientos por zona horaria).
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

  Map<String, dynamic> toMap() => {
        'inicio': Timestamp.fromDate(inicio),
        'fin': Timestamp.fromDate(fin),
        // Persistimos `dias` (derivado) como conveniencia de lectura/reportes;
        // la fuente de verdad sigue siendo inicio/fin.
        'dias': dias,
      };

  /// ¿Se solapa con [otro]? (para detectar tramos pisados al cargar).
  bool seSolapaCon(PeriodoVacaciones otro) =>
      !inicio.isAfter(otro.fin) && !otro.inicio.isAfter(fin);
}

class Vacacion {
  /// DNI del empleado — referencia al legajo en EMPLEADOS.
  final String dni;

  /// Copia del nombre para listar sin cruzar con EMPLEADOS.
  final String nombre;

  /// Año devengado (ej. 2025), aunque los períodos caigan en el año siguiente.
  final int anio;

  /// Copia de la empresa empleadora (label, ej. "SRL"/"VC") — filtro.
  final String empresa;

  /// Copia del área (manejo/taller/administración/limpieza) — agrupa saldos.
  final String area;

  /// Días de vacaciones que corresponden este año.
  final int diasCorresponden;

  /// `true` = el valor vino del cálculo automático por antigüedad y puede
  /// recalcularse. `false` = lo editó la oficina a mano (override) → respetar.
  final bool diasAuto;

  /// Tramos de goce (ordenados por inicio asc).
  final List<PeriodoVacaciones> periodos;

  final DateTime? actualizadoEn;
  final String? actualizadoPorDni;

  Vacacion({
    required this.dni,
    required this.nombre,
    required this.anio,
    required this.empresa,
    required this.area,
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

  /// Días ya tomados = suma de los días corridos de cada período.
  int get tomados => periodos.fold(0, (acc, p) => acc + p.dias);

  /// Días que quedan por tomar. Puede ser negativo si cargaron de más
  /// (lo dejamos visible como señal de error, no lo clamp-eamos a 0).
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

  factory Vacacion.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final m = doc.data() ?? {};
    return Vacacion.fromMap(m);
  }

  factory Vacacion.fromMap(Map<String, dynamic> m) {
    final rawPeriodos = (m['periodos'] as List?) ?? const [];
    return Vacacion(
      dni: (m['dni'] ?? '').toString(),
      nombre: (m['nombre'] ?? '').toString(),
      anio: (m['anio'] as num?)?.toInt() ?? 0,
      empresa: (m['empresa'] ?? '').toString(),
      area: (m['area'] ?? '').toString(),
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

  /// Mapa para persistir. `tomados` y `restan` se guardan DERIVADOS (la vista
  /// de saldos los lee sin expandir períodos), pero la fuente de verdad son
  /// `diasCorresponden` + `periodos`. `actualizadoEn` lo setea el service con
  /// serverTimestamp (no acá).
  Map<String, dynamic> toMap() => {
        'dni': dni,
        'nombre': nombre,
        'anio': anio,
        'empresa': empresa,
        'area': area,
        'diasCorresponden': diasCorresponden,
        'diasAuto': diasAuto,
        'periodos': periodos.map((p) => p.toMap()).toList(),
        'tomados': tomados,
        'restan': restan,
        if (actualizadoPorDni != null) 'actualizadoPorDni': actualizadoPorDni,
      };

  Vacacion copyWith({
    String? nombre,
    String? empresa,
    String? area,
    int? diasCorresponden,
    bool? diasAuto,
    List<PeriodoVacaciones>? periodos,
    String? actualizadoPorDni,
  }) =>
      Vacacion(
        dni: dni,
        nombre: nombre ?? this.nombre,
        anio: anio,
        empresa: empresa ?? this.empresa,
        area: area ?? this.area,
        diasCorresponden: diasCorresponden ?? this.diasCorresponden,
        diasAuto: diasAuto ?? this.diasAuto,
        periodos: periodos ?? this.periodos,
        actualizadoEn: actualizadoEn,
        actualizadoPorDni: actualizadoPorDni ?? this.actualizadoPorDni,
      );
}
