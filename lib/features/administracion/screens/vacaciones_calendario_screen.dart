// lib/features/administracion/screens/vacaciones_calendario_screen.dart
//
// Calendario mensual de vacaciones (paso 5) — el "Gantt" del Excel: ver quién
// está afuera cada día del mes para detectar solapamientos (que no se vaya
// media flota junta).
//
// Layout: columna de nombres FIJA a la izquierda + grilla de días scrollable
// horizontal (sincronizada en vertical con los nombres). Arriba de la grilla,
// una fila de DENSIDAD: cuántos están afuera cada día (heatmap), para ver el
// pico de un vistazo.
//
// Datos: como un período gozado en el mes M/Y puede estar devengado en Y-1 o
// Y, se consultan ambos años (VacacionesService.streamPorAnios) y se cruzan
// con EMPLEADOS (nombre/área) por DNI.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/vacacion.dart';
import '../services/vacaciones_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

const double _kFilaH = 28;
const double _kCeldaW = 24;
const double _kNombreW = 124;

class _FilaCal {
  final String nombre;
  final String area;
  final Set<int> dias; // días del mes (1..N) que está afuera
  _FilaCal({required this.nombre, required this.area, required this.dias});
}

class VacacionesCalendarioScreen extends StatefulWidget {
  /// Mes inicial (primer día). Si null, arranca en el mes en curso.
  final DateTime? mesInicial;
  const VacacionesCalendarioScreen({super.key, this.mesInicial});

  @override
  State<VacacionesCalendarioScreen> createState() =>
      _VacacionesCalendarioScreenState();
}

class _VacacionesCalendarioScreenState
    extends State<VacacionesCalendarioScreen> {
  final _svc = VacacionesService();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _empleadosStream;
  late DateTime _mes; // primer día del mes mostrado

  @override
  void initState() {
    super.initState();
    final base = widget.mesInicial ?? DateTime.now();
    _mes = DateTime(base.year, base.month);
    _empleadosStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .orderBy('NOMBRE')
        .snapshots();
  }

  int get _diasEnMes => DateTime(_mes.year, _mes.month + 1, 0).day;

  void _cambiarMes(int delta) =>
      setState(() => _mes = DateTime(_mes.year, _mes.month + delta));

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Calendario de vacaciones',
      body: Column(
        children: [
          _selectorMes(),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _empleadosStream,
              builder: (context, empSnap) {
                if (empSnap.hasError) {
                  return const AppErrorState(title: 'No se pudo cargar');
                }
                if (!empSnap.hasData) return const AppLoadingState();
                final nombrePorDni = <String, Map<String, String>>{};
                for (final d in empSnap.data!.docs) {
                  final m = d.data();
                  nombrePorDni[d.id] = {
                    'nombre': (m['NOMBRE'] ?? '').toString(),
                    'area': (m['AREA'] ?? '').toString(),
                  };
                }
                return StreamBuilder<List<Vacacion>>(
                  stream: _svc.streamPorAnios([_mes.year - 1, _mes.year]),
                  builder: (context, vacSnap) {
                    if (!vacSnap.hasData) return const AppLoadingState();
                    return _gantt(vacSnap.data!, nombrePorDni);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectorMes() {
    final c = context.colors;
    final label = DateFormat('MMMM yyyy', 'es_AR').format(_mes);
    final cap = label.isEmpty ? label : label[0].toUpperCase() + label.substring(1);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          IconButton(
            onPressed: () => _cambiarMes(-1),
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: Text(cap,
                textAlign: TextAlign.center,
                style: AppType.h4.copyWith(color: c.text)),
          ),
          IconButton(
            onPressed: () => _cambiarMes(1),
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }

  Widget _gantt(
      List<Vacacion> vacs, Map<String, Map<String, String>> empleados) {
    final n = _diasEnMes;
    final primero = DateTime(_mes.year, _mes.month, 1);
    final ultimo = DateTime(_mes.year, _mes.month, n);

    // Por DNI, juntar los días del mes que está afuera (de cualquier período
    // de cualquiera de los 2 años consultados).
    final diasPorDni = <String, Set<int>>{};
    for (final v in vacs) {
      for (final p in v.periodos) {
        if (p.fin.isBefore(primero) || p.inicio.isAfter(ultimo)) continue;
        final desde = p.inicio.isBefore(primero) ? primero : p.inicio;
        final hasta = p.fin.isAfter(ultimo) ? ultimo : p.fin;
        final set = diasPorDni.putIfAbsent(v.dni, () => <int>{});
        for (var d = desde.day; d <= hasta.day; d++) {
          set.add(d);
        }
      }
    }

    if (diasPorDni.isEmpty) {
      return const AppEmptyState(
        title: 'Nadie de vacaciones este mes',
        subtitle: 'Cambiá de mes con las flechas de arriba.',
      );
    }

    // Filas (empleados con días ese mes), ordenadas por primer día afuera.
    final filas = <_FilaCal>[];
    diasPorDni.forEach((dni, dias) {
      final emp = empleados[dni];
      filas.add(_FilaCal(
        nombre: emp?['nombre']?.isNotEmpty == true ? emp!['nombre']! : 'DNI $dni',
        area: emp?['area'] ?? '',
        dias: dias,
      ));
    });
    filas.sort((a, b) {
      final ma = a.dias.reduce((x, y) => x < y ? x : y);
      final mb = b.dias.reduce((x, y) => x < y ? x : y);
      return ma != mb ? ma.compareTo(mb) : a.nombre.compareTo(b.nombre);
    });

    // Densidad: cuántos afuera cada día.
    final densidad = List<int>.filled(n + 1, 0);
    for (final f in filas) {
      for (final d in f.dias) {
        densidad[d]++;
      }
    }
    final maxDens = densidad.fold<int>(0, (a, b) => a > b ? a : b);

    return SingleChildScrollView(
      scrollDirection: Axis.vertical,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Columna fija: nombres ──
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: _kFilaH * 2, width: _kNombreW), // header (densidad + días)
              ...filas.map((f) => _celdaNombre(f)),
            ],
          ),
          // ── Grilla scrollable ──
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _filaDensidad(densidad, maxDens),
                  _filaDias(n),
                  ...filas.map((f) => _filaCeldas(f, n)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _celdaNombre(_FilaCal f) {
    final c = context.colors;
    return Container(
      width: _kNombreW,
      height: _kFilaH,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.only(right: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: c.surface3, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(f.nombre,
              style: AppType.monoSm.copyWith(color: c.text, fontSize: 11),
              maxLines: 1, overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }

  Widget _filaDensidad(List<int> densidad, int maxDens) {
    final c = context.colors;
    return Row(
      children: [
        for (var d = 1; d <= _diasEnMes; d++)
          Container(
            width: _kCeldaW,
            height: _kFilaH,
            alignment: Alignment.center,
            margin: const EdgeInsets.all(0.5),
            decoration: BoxDecoration(
              color: densidad[d] == 0
                  ? Colors.transparent
                  : AppColors.error.withValues(
                      alpha: 0.18 + 0.55 * (densidad[d] / (maxDens == 0 ? 1 : maxDens))),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(densidad[d] == 0 ? '' : '${densidad[d]}',
                style: AppType.monoSm.copyWith(
                    color: c.text, fontSize: 10, fontWeight: FontWeight.bold)),
          ),
      ],
    );
  }

  Widget _filaDias(int n) {
    final c = context.colors;
    return Row(
      children: [
        for (var d = 1; d <= n; d++)
          _ConDiaSemana(
            ancho: _kCeldaW,
            alto: _kFilaH,
            child: Text('$d',
                style: AppType.monoSm.copyWith(
                    color: _esFinde(d) ? c.textMuted : c.textSecondary,
                    fontSize: 10)),
          ),
      ],
    );
  }

  Widget _filaCeldas(_FilaCal f, int n) {
    final c = context.colors;
    return Row(
      children: [
        for (var d = 1; d <= n; d++)
          Container(
            width: _kCeldaW,
            height: _kFilaH,
            margin: const EdgeInsets.all(0.5),
            decoration: BoxDecoration(
              color: f.dias.contains(d)
                  ? AppColors.success.withValues(alpha: 0.55)
                  : (_esFinde(d) ? c.surface3.withValues(alpha: 0.4) : Colors.transparent),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
      ],
    );
  }

  bool _esFinde(int dia) {
    final wd = DateTime(_mes.year, _mes.month, dia).weekday;
    return wd == DateTime.saturday || wd == DateTime.sunday;
  }
}

class _ConDiaSemana extends StatelessWidget {
  final double ancho;
  final double alto;
  final Widget child;
  const _ConDiaSemana({required this.ancho, required this.alto, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: ancho,
      height: alto,
      alignment: Alignment.center,
      child: child,
    );
  }
}
