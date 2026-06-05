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
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/vacacion.dart';
import '../services/vacaciones_service.dart';

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
  final Vacacion? vac;
  _FilaVac({
    required this.dni,
    required this.nombre,
    required this.empresa,
    required this.area,
    required this.activo,
    required this.vac,
  });
}

class AdminVacacionesScreen extends StatefulWidget {
  const AdminVacacionesScreen({super.key});

  @override
  State<AdminVacacionesScreen> createState() => _AdminVacacionesScreenState();
}

class _AdminVacacionesScreenState extends State<AdminVacacionesScreen> {
  final _svc = VacacionesService();
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _empleadosStream;

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
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Vacaciones',
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
                final activo = m['ACTIVO'] != false;
                final vac = porDni[d.id];
                if (!activo && vac == null) continue;
                filas.add(_FilaVac(
                  dni: d.id,
                  nombre: (m['NOMBRE'] ?? '').toString(),
                  empresa: (m['EMPRESA'] ?? '').toString(),
                  area: (m['AREA'] ?? '').toString(),
                  activo: activo,
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
    final restanTotal =
        conVac.fold<int>(0, (acc, f) => acc + (f.vac!.restan));
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
          AppKpiStrip(stats: [
            AppStat(label: 'Empleados', value: '${filtradas.length}'),
            AppStat(label: 'Días restantes', value: '$restanTotal'),
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
                          onTap: () => _verDetalle(filtradas[i]),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  void _verDetalle(_FilaVac f) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _DetalleSheet(fila: f, anio: _anio),
    );
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

/// Bottom sheet con el detalle de los períodos del empleado.
class _DetalleSheet extends StatelessWidget {
  final _FilaVac fila;
  final int anio;
  const _DetalleSheet({required this.fila, required this.anio});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final v = fila.vac;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Text(fila.nombre, style: AppType.h4.copyWith(color: c.text)),
            const SizedBox(height: 2),
            Text(
              [
                if (fila.empresa.isNotEmpty) fila.empresa,
                if (fila.area.isNotEmpty) _capitalizar(fila.area),
                'Año $anio',
              ].join(' · '),
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: AppSpacing.md),
            if (v == null)
              Text('Sin vacaciones cargadas para $anio.',
                  style: AppType.bodySm.copyWith(color: c.textSecondary))
            else ...[
              Row(
                children: [
                  _ResumenChip('Corresponden', '${v.diasCorresponden}', c.brand),
                  const SizedBox(width: AppSpacing.sm),
                  _ResumenChip('Tomados', '${v.tomados}', c.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  _ResumenChip(
                      'Restan',
                      '${v.restan}',
                      v.restan < 0
                          ? AppColors.error
                          : (v.restan == 0 ? c.textMuted : AppColors.success)),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('PERÍODOS',
                  style: AppType.eyebrow
                      .copyWith(color: AppColors.success, letterSpacing: 1.2)),
              const SizedBox(height: AppSpacing.sm),
              if (v.periodos.isEmpty)
                Text('Sin períodos cargados.',
                    style: AppType.bodySm.copyWith(color: c.textMuted))
              else
                ...v.periodos.map((p) => Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                      child: Row(
                        children: [
                          Icon(Icons.event_outlined, size: 15, color: c.textMuted),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text('${_fecha(p.inicio)}  →  ${_fecha(p.fin)}',
                                style: AppType.bodySm.copyWith(color: c.text)),
                          ),
                          AppBadge(
                              text: '${p.dias} días',
                              color: c.brand,
                              size: AppBadgeSize.sm),
                        ],
                      ),
                    )),
              if (v.tienePeriodosSolapados) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.error),
                  const SizedBox(width: 6),
                  Text('Hay períodos solapados',
                      style: AppType.monoSm.copyWith(color: AppColors.error)),
                ]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ResumenChip extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;
  const _ResumenChip(this.label, this.valor, this.color);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(
            vertical: AppSpacing.sm, horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          children: [
            Text(valor,
                style: AppType.h4.copyWith(color: color, fontWeight: FontWeight.bold)),
            Text(label.toUpperCase(),
                style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 9),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

String _capitalizar(String s) {
  if (s.isEmpty) return s;
  return s[0].toUpperCase() + s.substring(1).toLowerCase();
}

String _fecha(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
