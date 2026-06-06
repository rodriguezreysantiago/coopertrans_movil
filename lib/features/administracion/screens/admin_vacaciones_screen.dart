// lib/features/administracion/screens/admin_vacaciones_screen.dart
//
// Tabla anual de Vacaciones (módulo Administración). Espeja la hoja madre del
// Excel: una fila por empleado con días que corresponden / tomados / restan +
// sus períodos. Solo lectura por ahora (la edición de períodos es el paso 4b).
//
// Datos: join en cliente de EMPLEADOS (nombre/empresa/área — fuente de verdad)
// con VACACIONES (lo propio del año). No se duplica nada (ver vacacion.dart).
// Con ≤85 empleados el join en memoria es instantáneo.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/vacacion.dart';
import '../services/vacaciones_service.dart';
import 'vacaciones_calendario_screen.dart';
import 'vacaciones_editor_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Una fila lista para mostrar: datos del empleado (de EMPLEADOS) + su
/// registro de vacaciones del año (de VACACIONES, puede faltar).
class _FilaVac {
  final String dni;
  final String nombre;
  final String empresa;
  final String area;
  final bool activo;
  final DateTime? fechaIngreso;
  final Vacacion? vac;
  _FilaVac({
    required this.dni,
    required this.nombre,
    required this.empresa,
    required this.area,
    required this.activo,
    required this.fechaIngreso,
    required this.vac,
  });
}

/// FECHA_INGRESO en EMPLEADOS puede venir como Timestamp (docs viejos), como
/// String ISO (lo que escribe el form actual) o como DD-MM-AAAA / DD/MM/AAAA
/// (ediciones manuales en consola o migraciones). Normaliza a DateTime para
/// que el editor pueda sugerir los días por antigüedad.
///
/// El Timestamp se resuelve acá (su `.toString()` no es parseable); el resto
/// de los formatos los maneja el parser canónico `AppFormatters.tryParseFecha`
/// (local-safe, igual que el resto de la app). Antes el parseo de String era
/// solo `DateTime.tryParse` (ISO) → a quien tenía la fecha en DD-MM no se le
/// calculaba la sugerencia de días.
DateTime? _parseFechaIngreso(dynamic raw) {
  if (raw is Timestamp) return raw.toDate();
  return AppFormatters.tryParseFecha(raw);
}

class AdminVacacionesScreen extends StatefulWidget {
  const AdminVacacionesScreen({super.key});

  @override
  State<AdminVacacionesScreen> createState() => _AdminVacacionesScreenState();
}

class _AdminVacacionesScreenState extends State<AdminVacacionesScreen> {
  final _svc = VacacionesService();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _empleadosStream;

  /// Excluidos de la tabla: tanqueros + testers (revisores de Apple/Google).
  /// Null hasta que carga (fail-safe: no esconde a nadie mientras tanto).
  ExcluidosSet? _excluidos;

  int _anio = 2025;
  String? _empresaFiltro;
  String? _areaFiltro;
  String _busqueda = '';

  static const _aniosDisponibles = [2026, 2025, 2024];

  @override
  void initState() {
    super.initState();
    _empleadosStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .orderBy('NOMBRE')
        .snapshots();
    // Excluir tanqueros + testers (revisores Apple/Google), igual que el resto
    // de la app. Al cargar, setState re-filtra la tabla.
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Vacaciones',
      actions: [
        IconButton(
          tooltip: 'Calendario mensual',
          icon: const Icon(Icons.calendar_month_outlined),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const VacacionesCalendarioScreen(),
          )),
        ),
      ],
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _empleadosStream,
        builder: (context, empSnap) {
          if (empSnap.hasError) {
            return const AppErrorState(title: 'No se pudo cargar el personal');
          }
          if (!empSnap.hasData) return const AppLoadingState();
          final empleados = empSnap.data!.docs;

          return StreamBuilder<List<Vacacion>>(
            stream: _svc.streamPorAnio(_anio),
            builder: (context, vacSnap) {
              final vacs = vacSnap.data ?? const <Vacacion>[];
              final porDni = {for (final v in vacs) v.dni: v};

              // Armar filas: empleado activo, O inactivo con vacaciones del año
              // (para no esconder a alguien dado de baja que tenía días).
              final filas = <_FilaVac>[];
              for (final d in empleados) {
                final m = d.data();
                // Tanqueros + testers (Apple/Google) fuera de la tabla.
                if (ExcluidosService.esExcluido(_excluidos, dni: d.id)) {
                  continue;
                }
                final activo = m['ACTIVO'] != false;
                final vac = porDni[d.id];
                if (!activo && vac == null) continue;
                filas.add(_FilaVac(
                  dni: d.id,
                  nombre: (m['NOMBRE'] ?? '').toString(),
                  empresa: (m['EMPRESA'] ?? '').toString(),
                  area: (m['AREA'] ?? '').toString(),
                  activo: activo,
                  fechaIngreso: _parseFechaIngreso(m['FECHA_INGRESO']),
                  vac: vac,
                ));
              }

              return _contenido(filas, cargando: !vacSnap.hasData);
            },
          );
        },
      ),
    );
  }

  Widget _contenido(List<_FilaVac> todas, {required bool cargando}) {
    final c = context.colors;

    // Opciones de filtro (sobre el universo, no sobre lo filtrado).
    final empresas = todas.map((f) => f.empresa).where((e) => e.isNotEmpty).toSet().toList()..sort();
    final areas = todas.map((f) => f.area).where((a) => a.isNotEmpty).toSet().toList()..sort();

    // Aplicar filtros + búsqueda.
    final q = _busqueda.trim().toUpperCase();
    final filtradas = todas.where((f) {
      if (_empresaFiltro != null && f.empresa != _empresaFiltro) return false;
      if (_areaFiltro != null && f.area != _areaFiltro) return false;
      if (q.isNotEmpty && !f.nombre.toUpperCase().contains(q)) return false;
      return true;
    }).toList()
      ..sort((a, b) => a.nombre.toUpperCase().compareTo(b.nombre.toUpperCase()));

    // KPIs sobre lo filtrado.
    final conVac = filtradas.where((f) => f.vac != null).toList();
    // El total clampea cada saldo a >= 0: un saldo negativo es señal de carga
    // errónea (cargaron más días de los que corresponden), no "días de menos"
    // que compensen a otro. Sumarlo crudo dejaba que un +5 y un −5 se anularan
    // y escondía AMBAS anomalías. Los negativos se cuentan aparte abajo.
    final restanTotal =
        conVac.fold<int>(0, (acc, f) => acc + (f.vac!.restan < 0 ? 0 : f.vac!.restan));
    final conNegativo = conVac.where((f) => f.vac!.restan < 0).length;
    final sinCargar = filtradas.length - conVac.length;

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header: eyebrow + selector de año ──
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppEyebrow('Personal · días por antigüedad'),
                    const SizedBox(height: 2),
                    Text('${filtradas.length} empleados',
                        style: AppType.h4.copyWith(color: c.text)),
                  ],
                ),
              ),
              _SelectorAnio(
                anio: _anio,
                opciones: _aniosDisponibles,
                onChanged: (a) => setState(() => _anio = a),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),

          // ── KPIs ──
          // "Días restantes" suma solo saldos >= 0 (ver restanTotal). Si hay
          // saldos negativos —carga errónea— se avisa con un delta en rojo en
          // vez de dejarlos compensar el total y desaparecer.
          AppKpiStrip(stats: [
            AppStat(label: 'Empleados', value: '${filtradas.length}'),
            AppStat(
              label: 'Días restantes',
              value: '$restanTotal',
              delta: conNegativo > 0
                  ? '$conNegativo en negativo'
                  : null,
              deltaColor: AppColors.error,
            ),
            AppStat(label: 'Sin cargar', value: '$sinCargar'),
          ]),
          const SizedBox(height: AppSpacing.md),

          // ── Filtros: empresa + área ──
          if (empresas.length > 1) ...[
            _FilaChips(
              titulo: 'Empresa',
              valores: empresas,
              seleccionado: _empresaFiltro,
              countDe: (e) => todas.where((f) => f.empresa == e).length,
              onTap: (e) => setState(() => _empresaFiltro = e),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          if (areas.length > 1)
            _FilaChips(
              titulo: 'Área',
              valores: areas,
              seleccionado: _areaFiltro,
              countDe: (a) => todas.where((f) => f.area == a).length,
              onTap: (a) => setState(() => _areaFiltro = a),
            ),
          const SizedBox(height: AppSpacing.md),

          // ── Búsqueda ──
          TextField(
            onChanged: (v) => setState(() => _busqueda = v),
            style: AppType.bodySm.copyWith(color: c.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Buscar por nombre…',
              hintStyle: AppType.bodySm.copyWith(color: c.textMuted),
              prefixIcon: Icon(Icons.search, size: 18, color: c.textMuted),
              filled: true,
              fillColor: c.surface3,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // ── Lista ──
          Expanded(
            child: cargando
                ? const AppLoadingState()
                : filtradas.isEmpty
                    ? const AppEmptyState(
                        title: 'Sin resultados',
                        subtitle: 'Probá quitar filtros o cambiar el año.')
                    : ListView.separated(
                        itemCount: filtradas.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.sm),
                        itemBuilder: (_, i) => _FilaWidget(
                          fila: filtradas[i],
                          onTap: () => _abrirEditor(filtradas[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  void _abrirEditor(_FilaVac f) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VacacionEditorScreen(
        dni: f.dni,
        nombre: f.nombre,
        empresa: f.empresa,
        area: f.area,
        fechaIngreso: f.fechaIngreso,
        anio: _anio,
        inicial: f.vac,
      ),
    ));
  }
}

/// Selector de año compacto (dropdown).
class _SelectorAnio extends StatelessWidget {
  final int anio;
  final List<int> opciones;
  final ValueChanged<int> onChanged;
  const _SelectorAnio(
      {required this.anio, required this.opciones, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<int>(
          value: anio,
          isDense: true,
          dropdownColor: c.surface2,
          style: AppType.bodySm.copyWith(color: c.text),
          icon: Icon(Icons.expand_more, size: 18, color: c.textMuted),
          items: opciones
              .map((a) => DropdownMenuItem(value: a, child: Text('Año $a')))
              .toList(),
          onChanged: (v) => v == null ? null : onChanged(v),
        ),
      ),
    );
  }
}

/// Fila de chips de filtro (con "Todas" + un chip por valor).
class _FilaChips extends StatelessWidget {
  final String titulo;
  final List<String> valores;
  final String? seleccionado;
  final int Function(String) countDe;
  final ValueChanged<String?> onTap;
  const _FilaChips({
    required this.titulo,
    required this.valores,
    required this.seleccionado,
    required this.countDe,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          AppFilterChip(
            label: 'Todas',
            count: valores.fold<int>(0, (a, v) => a + countDe(v)),
            activo: seleccionado == null,
            onTap: () => onTap(null),
          ),
          for (final v in valores) ...[
            const SizedBox(width: AppSpacing.xs),
            AppFilterChip(
              label: _capitalizar(v),
              count: countDe(v),
              activo: seleccionado == v,
              onTap: () => onTap(seleccionado == v ? null : v),
            ),
          ],
        ],
      ),
    );
  }
}

/// Fila de un empleado en la tabla.
class _FilaWidget extends StatelessWidget {
  final _FilaVac fila;
  final VoidCallback onTap;
  const _FilaWidget({required this.fila, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = fila.vac;
    final sub = [
      if (fila.empresa.isNotEmpty) fila.empresa,
      if (fila.area.isNotEmpty) _capitalizar(fila.area),
      if (!fila.activo) 'inactivo',
    ].join(' · ');

    return AppCard(
      tier: 1,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(fila.nombre,
                    style: AppType.h5.copyWith(color: c.text),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 2),
                Text(sub,
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (v == null)
            Text('sin cargar',
                style: AppType.monoSm.copyWith(color: c.textMuted))
          else
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _Num(label: 'Corr', valor: v.diasCorresponden, color: c.textSecondary),
                _Num(label: 'Tom', valor: v.tomados, color: c.textSecondary),
                _Num(
                  label: 'Rest',
                  valor: v.restan,
                  color: v.restan < 0
                      ? AppColors.error
                      : (v.restan == 0 ? c.textMuted : AppColors.success),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Mini columna de número con label arriba (Corr / Tom / Rest).
class _Num extends StatelessWidget {
  final String label;
  final int valor;
  final Color color;
  const _Num({required this.label, required this.valor, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 42,
      margin: const EdgeInsets.only(left: 4),
      child: Column(
        children: [
          Text(label.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 9)),
          const SizedBox(height: 2),
          Text('$valor',
              style: AppType.h5.copyWith(color: color, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

String _capitalizar(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1).toLowerCase();
}
