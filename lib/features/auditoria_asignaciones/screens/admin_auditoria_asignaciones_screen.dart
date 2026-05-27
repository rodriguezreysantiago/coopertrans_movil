import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../asignaciones/models/asignacion_vehiculo.dart';
import '../models/tramo_ibutton.dart';
import '../services/historico_ibutton_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Auditoría de asignaciones: cruza el HISTÓRICO REAL del iButton físico
/// (`SITRACK_IBUTTONS_HISTORICO` — qué iButton estuvo en qué patente y
/// cuándo, reconstruido desde SITRACK_EVENTOS) contra
/// `ASIGNACIONES_VEHICULO` (lo que el sistema dice por las altas/bajas
/// manuales del admin).
///
/// Para cada tramo Sitrack, busca la asignación del sistema activa en
/// ese mismo momento + patente. Si los DNI coinciden → OK. Si no
/// coinciden o no había asignación → discrepancia (highlighted rojo).
///
/// Casos típicos:
///   - **DNI distinto**: el iButton lo usó otro chofer (no el asignado).
///     Útil para multas tardías ("¿quién manejaba realmente el día X?").
///   - **Sin asignación**: el sistema no tenía a NADIE asignado pero el
///     iButton se pasó → falta dar de alta la asignación.
///   - **OK**: confirma que la asignación del sistema coincide con la
///     realidad. Útil para auditoría positiva.
class AdminAuditoriaAsignacionesScreen extends StatefulWidget {
  const AdminAuditoriaAsignacionesScreen({super.key});

  @override
  State<AdminAuditoriaAsignacionesScreen> createState() =>
      _AdminAuditoriaAsignacionesScreenState();
}

class _AdminAuditoriaAsignacionesScreenState
    extends State<AdminAuditoriaAsignacionesScreen> {
  late DateTime _desde;
  late DateTime _hasta;
  String _filtroPatente = '';
  String _filtroDni = '';
  bool _soloDiscrepancias = false;

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _desde = ahora.subtract(const Duration(days: 7));
    _hasta = ahora;
  }

  Future<void> _elegirRango() async {
    final ahora = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: ahora.subtract(const Duration(days: 365)),
      lastDate: ahora,
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
      locale: const Locale('es', 'AR'),
      helpText: 'Rango a auditar',
      saveText: 'Aplicar',
    );
    if (r == null) return;
    setState(() {
      _desde = DateTime(r.start.year, r.start.month, r.start.day);
      final esHoy = r.end.year == ahora.year &&
          r.end.month == ahora.month &&
          r.end.day == ahora.day;
      _hasta = esHoy
          ? ahora
          : DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Auditoría asignaciones',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _BannerInfo(),
          _BarraFiltros(
            desde: _desde,
            hasta: _hasta,
            patente: _filtroPatente,
            dni: _filtroDni,
            soloDiscrepancias: _soloDiscrepancias,
            onRango: _elegirRango,
            onPatente: (v) => setState(() => _filtroPatente = v.toUpperCase()),
            onDni: (v) => setState(() => _filtroDni = v),
            onSoloDiscrepancias: (v) => setState(() => _soloDiscrepancias = v),
          ),
          Expanded(
            child: _ListadoCruce(
              desde: _desde,
              hasta: _hasta,
              filtroPatente: _filtroPatente,
              filtroDni: _filtroDni,
              soloDiscrepancias: _soloDiscrepancias,
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.info, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Compara el iButton que físicamente se pasó (Sitrack) contra '
              'la asignación cargada en el sistema. Útil para multas tardías, '
              'investigaciones y reconciliación. Histórico desde 2026-05-23.',
              style: AppType.label.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarraFiltros extends StatelessWidget {
  final DateTime desde;
  final DateTime hasta;
  final String patente;
  final String dni;
  final bool soloDiscrepancias;
  final VoidCallback onRango;
  final ValueChanged<String> onPatente;
  final ValueChanged<String> onDni;
  final ValueChanged<bool> onSoloDiscrepancias;

  const _BarraFiltros({
    required this.desde,
    required this.hasta,
    required this.patente,
    required this.dni,
    required this.soloDiscrepancias,
    required this.onRango,
    required this.onPatente,
    required this.onDni,
    required this.onSoloDiscrepancias,
  });

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onRango,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.sm),
                border: Border.all(
                    color: AppColors.brand.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.date_range,
                      color: AppColors.brand, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${_fmt(desde)} → ${_fmt(hasta)}',
                      style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const Icon(Icons.calendar_today,
                      color: Colors.white54, size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Filtrar por patente',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: onPatente,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: TextField(
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Filtrar por DNI',
                    border: OutlineInputBorder(),
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  onChanged: onDni,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('Solo discrepancias',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            value: soloDiscrepancias,
            onChanged: onSoloDiscrepancias,
          ),
        ],
      ),
    );
  }
}

class _ListadoCruce extends StatelessWidget {
  final DateTime desde;
  final DateTime hasta;
  final String filtroPatente;
  final String filtroDni;
  final bool soloDiscrepancias;

  const _ListadoCruce({
    required this.desde,
    required this.hasta,
    required this.filtroPatente,
    required this.filtroDni,
    required this.soloDiscrepancias,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<TramoIButton>>(
      stream: HistoricoIButtonService.streamPorRango(
        desde: desde,
        hasta: hasta,
        patente: filtroPatente.isEmpty ? null : filtroPatente,
        choferDni: filtroDni.isEmpty ? null : filtroDni,
      ),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Text('Error: ${snap.error}',
                  style: const TextStyle(color: AppColors.error)),
            ),
          );
        }
        final tramos = snap.data ?? const <TramoIButton>[];
        if (tramos.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.history, color: Colors.white24, size: 64),
                  const SizedBox(height: AppSpacing.md),
                  const Text(
                    'Sin tramos en el rango seleccionado.',
                    style: TextStyle(color: Colors.white54),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'El histórico se reconstruye 06:00 ART procesando '
                    'el día anterior — el día actual recién se ve mañana.',
                    textAlign: TextAlign.center,
                    style: AppType.eyebrow.copyWith(color: Colors.white38),
                  ),
                ],
              ),
            ),
          );
        }
        // Cargar TODAS las asignaciones del rango para cruzar. Una sola
        // query por re-render — el stream del tramo refresca al cambio.
        return FutureBuilder<List<AsignacionVehiculo>>(
          future: _cargarAsignacionesRango(desde, hasta),
          builder: (ctx, asnap) {
            if (asnap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            final asignaciones = asnap.data ?? const <AsignacionVehiculo>[];
            final filas = tramos.map((t) {
              final asig = _buscarAsignacion(asignaciones, t);
              final estado = _clasificar(t, asig);
              return _FilaCruce(tramo: t, asignacion: asig, estado: estado);
            }).where((f) {
              if (soloDiscrepancias && f.estado == _Estado.ok) return false;
              return true;
            }).toList();
            if (filas.isEmpty) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(28),
                  child: Text(
                    'No hay discrepancias en el rango y filtros seleccionados.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.all(AppSpacing.md),
              children: [
                _Resumen(filas: filas),
                const SizedBox(height: 10),
                ...filas,
              ],
            );
          },
        );
      },
    );
  }

  static Future<List<AsignacionVehiculo>> _cargarAsignacionesRango(
      DateTime desde, DateTime hasta) async {
    // Traemos asignaciones que se SOLAPAN con el rango: desde <= hasta_filtro
    // && (hasta == null || hasta >= desde_filtro). Firestore no permite
    // dos rangos en distintos campos, así que filtramos client-side luego
    // de traer todas las que arrancaron antes de hasta_filtro.
    final snap = await FirebaseFirestore.instance
        .collection('ASIGNACIONES_VEHICULO')
        .where('desde', isLessThanOrEqualTo: Timestamp.fromDate(hasta))
        .get();
    final l = snap.docs.map(AsignacionVehiculo.fromDoc).toList();
    return l.where((a) {
      if (a.hasta == null) return true;
      return a.hasta!.isAfter(desde);
    }).toList();
  }

  /// Busca la asignación del sistema que CUBRE el momento del tramo
  /// (mismo vehículo, desde <= tramo.desde, hasta == null || hasta >=
  /// tramo.desde). Si hay varias (no debería pero por race), preferimos
  /// la más reciente.
  static AsignacionVehiculo? _buscarAsignacion(
      List<AsignacionVehiculo> all, TramoIButton t) {
    final candidatas = all.where((a) =>
        a.vehiculoId.toUpperCase() == t.patente &&
        !a.desde.isAfter(t.desde) &&
        (a.hasta == null || !a.hasta!.isBefore(t.desde))).toList();
    if (candidatas.isEmpty) return null;
    candidatas.sort((x, y) => y.desde.compareTo(x.desde));
    return candidatas.first;
  }

  static _Estado _clasificar(TramoIButton t, AsignacionVehiculo? a) {
    if (a == null) return _Estado.sinAsignacion;
    if (a.choferDni != t.choferDni) return _Estado.dniDistinto;
    return _Estado.ok;
  }
}

enum _Estado { ok, dniDistinto, sinAsignacion }

class _Resumen extends StatelessWidget {
  final List<_FilaCruce> filas;
  const _Resumen({required this.filas});

  @override
  Widget build(BuildContext context) {
    int ok = 0, dni = 0, sin = 0;
    for (final f in filas) {
      if (f.estado == _Estado.ok) {
        ok++;
      } else if (f.estado == _Estado.dniDistinto) {
        dni++;
      } else {
        sin++;
      }
    }
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          _ChipResumen(label: 'OK', valor: ok, color: AppColors.success),
          const SizedBox(width: 10),
          _ChipResumen(
              label: 'DNI distinto', valor: dni, color: AppColors.error),
          const SizedBox(width: 10),
          _ChipResumen(
              label: 'Sin asignación',
              valor: sin,
              color: AppColors.warning),
        ],
      ),
    );
  }
}

class _ChipResumen extends StatelessWidget {
  final String label;
  final int valor;
  final Color color;
  const _ChipResumen({
    required this.label,
    required this.valor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Column(
          children: [
            Text('$valor',
                style: TextStyle(
                    color: color,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            Text(label,
                style: AppType.eyebrow.copyWith(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _FilaCruce extends StatelessWidget {
  final TramoIButton tramo;
  final AsignacionVehiculo? asignacion;
  final _Estado estado;
  const _FilaCruce({
    required this.tramo,
    required this.asignacion,
    required this.estado,
  });

  Color get _color {
    switch (estado) {
      case _Estado.ok:
        return AppColors.success;
      case _Estado.dniDistinto:
        return AppColors.error;
      case _Estado.sinAsignacion:
        return AppColors.warning;
    }
  }

  IconData get _icono {
    switch (estado) {
      case _Estado.ok:
        return Icons.check_circle;
      case _Estado.dniDistinto:
        return Icons.error;
      case _Estado.sinAsignacion:
        return Icons.warning_amber;
    }
  }

  String get _etiqueta {
    switch (estado) {
      case _Estado.ok:
        return 'OK';
      case _Estado.dniDistinto:
        return 'DNI DISTINTO';
      case _Estado.sinAsignacion:
        return 'SIN ASIGNACIÓN';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: Colors.white.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(color: _color.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: patente + estado
            Row(
              children: [
                Text(
                  tramo.patente,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      letterSpacing: 1),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _color.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: _color.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_icono, color: _color, size: 12),
                      const SizedBox(width: AppSpacing.xs),
                      Text(_etiqueta,
                          style: TextStyle(
                              color: _color,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                const Spacer(),
                Text(
                  '${tramo.duracionMin} min',
                  style: AppType.eyebrow.copyWith(color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            // Sitrack iButton
            _LineaActor(
              label: 'iButton (real)',
              labelColor: AppColors.info,
              nombre: tramo.nombreLegible,
              dni: tramo.choferDni,
            ),
            const SizedBox(height: AppSpacing.xs),
            // Asignación sistema
            if (asignacion != null)
              _LineaActor(
                label: 'Sistema',
                labelColor: estado == _Estado.ok
                    ? AppColors.success
                    : AppColors.error,
                nombre: (asignacion!.choferNombre ?? '').isNotEmpty
                    ? asignacion!.choferNombre!
                    : 'DNI ${asignacion!.choferDni}',
                dni: asignacion!.choferDni,
              )
            else
              const _LineaActor(
                label: 'Sistema',
                labelColor: AppColors.warning,
                nombre: '(sin asignación cargada)',
                dni: '',
              ),
            const SizedBox(height: 6),
            // Fechas
            Row(
              children: [
                const Icon(Icons.access_time,
                    size: 12, color: Colors.white38),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  '${AppFormatters.formatearFechaHoraSinSegundos(tramo.desde)} → '
                  '${AppFormatters.formatearFechaHoraSinSegundos(tramo.hasta)}',
                  style: AppType.eyebrow.copyWith(color: Colors.white54),
                ),
                const SizedBox(width: 10),
                Text(
                  '${tramo.eventosCount} eventos',
                  style: AppType.eyebrow.copyWith(color: Colors.white38),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LineaActor extends StatelessWidget {
  final String label;
  final Color labelColor;
  final String nombre;
  final String dni;
  const _LineaActor({
    required this.label,
    required this.labelColor,
    required this.nombre,
    required this.dni,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 95,
          child: Text(
            label,
            style: AppType.eyebrow.copyWith(color: labelColor, fontWeight: FontWeight.bold),
          ),
        ),
        Expanded(
          child: Text(
            nombre,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        if (dni.isNotEmpty)
          Text(
            'DNI $dni',
            style: AppType.eyebrow.copyWith(color: Colors.white38),
          ),
      ],
    );
  }
}
