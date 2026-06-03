import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../eco_driving/utils/etiquetas_alerta_volvo.dart';
import '../services/chofer_actividad_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Tablero personal del chofer: km manejados, tractores que usó y
/// eventos Volvo asociados, en una ventana de 7/30/90 días.
///
/// Se accede desde la ficha del chofer (admin_personal_lista_widgets)
/// con el botón "Ver actividad". Reusa los datos que ya guardan
/// `AsignacionVehiculoService` (con snapshot de odómetro Sitrack desde
/// Fase 2) y `volvoAlertasPoller` (con `chofer_dni` snapshoteado).
///
/// Es read-only — el admin solo consume métricas, no edita nada acá.
///
/// REFACTOR NÚCLEO · jun 2026 — solo el árbol de widgets. El
/// FutureBuilder, `ChoferActividadService.resumen`, el selector de
/// ventana (7/30/90) y el modelo de datos quedaron INTACTOS.
class ChoferActividadScreen extends StatefulWidget {
  final String dni;
  final String nombreCompleto;

  const ChoferActividadScreen({
    super.key,
    required this.dni,
    required this.nombreCompleto,
  });

  @override
  State<ChoferActividadScreen> createState() => _ChoferActividadScreenState();
}

class _ChoferActividadScreenState extends State<ChoferActividadScreen> {
  int _dias = 30;
  Future<ChoferActividadResumen>? _futuro;

  @override
  void initState() {
    super.initState();
    _refrescar();
  }

  void _refrescar() {
    setState(() {
      _futuro = ChoferActividadService()
          .resumen(dni: widget.dni, dias: _dias);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Actividad del chofer',
      body: Column(
        children: [
          _Header(nombre: widget.nombreCompleto, dni: widget.dni),
          _SelectorPeriodo(
            diasActuales: _dias,
            onCambio: (d) {
              setState(() => _dias = d);
              _refrescar();
            },
          ),
          Expanded(
            child: FutureBuilder<ChoferActividadResumen>(
              future: _futuro,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.lg),
                    child: AppSkeletonList(count: 5, conAvatar: false),
                  );
                }
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No pudimos cargar la actividad',
                    subtitle: snap.error.toString(),
                  );
                }
                final resumen = snap.data ?? ChoferActividadResumen.empty(
                  widget.dni,
                  _dias,
                );
                return _Resumen(resumen: resumen);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HEADER — eyebrow + nombre + DNI mono
// =============================================================================

class _Header extends StatelessWidget {
  final String nombre;
  final String dni;
  const _Header({required this.nombre, required this.dni});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.person_outline, color: c.brand, size: 18),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nombre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.h5.copyWith(color: c.text),
                ),
                const SizedBox(height: 2),
                Text(
                  'DNI $dni',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SELECTOR DE PERÍODO — chips pill estilo Núcleo
// =============================================================================

class _SelectorPeriodo extends StatelessWidget {
  final int diasActuales;
  final ValueChanged<int> onCambio;
  const _SelectorPeriodo({required this.diasActuales, required this.onCambio});

  static const _opciones = [7, 30, 90];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
      child: Row(
        children: [
          for (final d in _opciones) ...[
            _ChipPeriodo(
              label: 'Últimos $d días',
              activo: d == diasActuales,
              onTap: () => onCambio(d),
            ),
            if (d != _opciones.last) const SizedBox(width: AppSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _ChipPeriodo extends StatelessWidget {
  final String label;
  final bool activo;
  final VoidCallback onTap;
  const _ChipPeriodo({
    required this.label,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: activo ? c.text : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: activo ? null : Border.all(color: c.border),
          ),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.label.copyWith(
              color: activo ? c.bg : c.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// RESUMEN (cuerpo principal)
// =============================================================================

class _Resumen extends StatelessWidget {
  final ChoferActividadResumen resumen;
  const _Resumen({required this.resumen});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayActividad = resumen.kmTotales > 0 ||
        resumen.totalEventos > 0 ||
        resumen.tractores.isNotEmpty ||
        resumen.asignaciones > 0;

    if (!hayActividad) {
      return AppEmptyState(
        icon: Icons.history_toggle_off,
        title: 'Sin actividad registrada',
        subtitle:
            'No hay asignaciones ni eventos del chofer en los últimos ${resumen.dias} días.',
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xxl),
      children: [
        // ─── Hero: km recorridos ───
        _HeroKm(km: resumen.kmTotales),
        const SizedBox(height: AppSpacing.mdDense),

        // ─── KPIs en grilla 2×2 (AppStat) ───
        AppCard(
          margin: EdgeInsets.zero,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: _StatCell(
                        stat: AppStat(
                          label: 'Eventos Volvo',
                          value: '${resumen.totalEventos}',
                          valueStyle: AppType.h3,
                          accent: resumen.totalEventos > 0
                              ? c.warning
                              : c.textMuted,
                        ),
                        borderRight: true,
                      ),
                    ),
                    Expanded(
                      child: _StatCell(
                        stat: AppStat(
                          label: 'Asignaciones',
                          value: '${resumen.asignaciones}',
                          valueStyle: AppType.h3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              AppHairline(color: c.border),
              IntrinsicHeight(
                child: Row(
                  children: [
                    Expanded(
                      child: _StatCell(
                        stat: AppStat(
                          label: 'Tractores',
                          value: '${resumen.tractores.length}',
                          valueStyle: AppType.h3,
                        ),
                        borderRight: true,
                      ),
                    ),
                    Expanded(
                      child: _StatCell(
                        stat: AppStat(
                          label: 'Sin telemetría',
                          value: '${resumen.asignacionesSinTelemetria}',
                          valueStyle: AppType.h3,
                          accent: resumen.asignacionesSinTelemetria > 0
                              ? c.textSecondary
                              : c.textMuted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Aviso de datos parciales si hay asignaciones legacy.
        if (resumen.asignacionesSinTelemetria > 0) ...[
          const SizedBox(height: AppSpacing.mdDense),
          _AvisoParcial(cantidad: resumen.asignacionesSinTelemetria),
        ],

        // ─── Tractores manejados ───
        if (resumen.tractores.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          const _Titulo(label: 'Tractores manejados'),
          const SizedBox(height: AppSpacing.sm),
          AppCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
            child: Column(
              children: [
                for (var i = 0; i < resumen.tractores.length; i++) ...[
                  if (i > 0) AppHairline(color: c.border),
                  _TractorTile(tractor: resumen.tractores[i]),
                ],
              ],
            ),
          ),
        ],

        // ─── Eventos por severidad ───
        if (resumen.totalEventos > 0) ...[
          const SizedBox(height: AppSpacing.xl),
          const _Titulo(label: 'Eventos Volvo'),
          const SizedBox(height: AppSpacing.sm),
          _EventosPorSeveridadCard(eventos: resumen.eventosPorSeveridad),
          if (resumen.eventosPorTipo.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.mdDense),
            _EventosPorTipoCard(eventos: resumen.eventosPorTipo),
          ],
        ],
      ],
    );
  }

  static String _formatearMiles(double n) {
    final i = n.round();
    final s = i.toString();
    final buf = StringBuffer();
    var c = 0;
    for (var k = s.length - 1; k >= 0; k--) {
      buf.write(s[k]);
      c++;
      if (c == 3 && k != 0) {
        buf.write('.');
        c = 0;
      }
    }
    return buf.toString().split('').reversed.join();
  }
}

// =============================================================================
// COMPONENTES
// =============================================================================

/// Hero number del período: km recorridos en grande (neutro, blanco) con
/// la unidad mono al lado. El número héroe nunca lleva color semántico.
class _HeroKm extends StatelessWidget {
  final double km;
  const _HeroKm({required this.km});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayKm = km > 0;
    return AppCard(
      glow: hayKm,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Km recorridos'),
          const SizedBox(height: AppSpacing.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                hayKm ? _Resumen._formatearMiles(km) : '—',
                style: AppType.h1.copyWith(
                  color: c.text,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (hayKm) ...[
                const SizedBox(width: AppSpacing.sm),
                Text('km', style: AppType.mono.copyWith(color: c.textMuted)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// Celda de un AppStat dentro de la grilla 2×2, con un border hairline a la
/// derecha opcional (separa columnas). Patrón del detalle de Flota.
class _StatCell extends StatelessWidget {
  final AppStat stat;
  final bool borderRight;
  const _StatCell({required this.stat, this.borderRight = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.lg),
      decoration: BoxDecoration(
        border: borderRight
            ? Border(right: BorderSide(color: c.border))
            : null,
      ),
      child: stat,
    );
  }
}

class _AvisoParcial extends StatelessWidget {
  final int cantidad;
  const _AvisoParcial({required this.cantidad});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final plural = cantidad == 1 ? '' : 'es';
    final esa = cantidad == 1 ? 'esa' : 'esas';
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 14, color: c.textMuted),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '$cantidad asignación$plural sin datos de odómetro Sitrack — '
              'los km de $esa no se pudieron contar.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  final String label;
  const _Titulo({required this.label});

  @override
  Widget build(BuildContext context) {
    return AppEyebrow(label);
  }
}

class _TractorTile extends StatelessWidget {
  final TractorUsado tractor;
  const _TractorTile({required this.tractor});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final km = tractor.kmEnPeriodo;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        children: [
          Text(
            tractor.patente,
            style: AppType.mono.copyWith(
                color: c.text, fontWeight: FontWeight.w600, letterSpacing: 0.5),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (tractor.activaActual)
            AppBadge(
              text: 'ACTUAL',
              color: c.success,
              size: AppBadgeSize.sm,
            ),
          const Spacer(),
          if (km == null)
            Text(
              '— km',
              style: AppType.mono.copyWith(color: c.textMuted),
            )
          else ...[
            Text(
              '${_Resumen._formatearMiles(km)} km',
              style: AppType.mono.copyWith(
                  color: c.text, fontWeight: FontWeight.w500),
            ),
            if (tractor.esParcial) ...[
              const SizedBox(width: AppSpacing.xs),
              Tooltip(
                message: 'Asignación en curso — km parcial',
                child: Icon(Icons.history, size: 13, color: c.textMuted),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _EventosPorSeveridadCard extends StatelessWidget {
  final Map<String, int> eventos;
  const _EventosPorSeveridadCard({required this.eventos});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final high = eventos['HIGH'] ?? 0;
    final medium = eventos['MEDIUM'] ?? 0;
    final low = eventos['LOW'] ?? 0;
    return AppCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _SeveridadMini(
                  label: 'HIGH', valor: high, color: c.error, borderRight: true),
            ),
            Expanded(
              child: _SeveridadMini(
                  label: 'MEDIUM',
                  valor: medium,
                  color: c.warning,
                  borderRight: true),
            ),
            Expanded(
              child: _SeveridadMini(
                  label: 'LOW', valor: low, color: c.success),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeveridadMini extends StatelessWidget {
  final String label;
  final int valor;
  final Color color;
  final bool borderRight;
  const _SeveridadMini({
    required this.label,
    required this.valor,
    required this.color,
    this.borderRight = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activo = valor > 0;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      decoration: BoxDecoration(
        border: borderRight
            ? Border(right: BorderSide(color: c.border))
            : null,
      ),
      child: Column(
        children: [
          Text(
            '$valor',
            style: AppType.h3.copyWith(
              color: activo ? color : c.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppDot(activo ? color : c.textMuted, size: 6),
              const SizedBox(width: 6),
              Text(
                label,
                style: AppType.eyebrow.copyWith(
                    color: activo ? color : c.textMuted),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EventosPorTipoCard extends StatelessWidget {
  final List<EventoTipoConteo> eventos;
  const _EventosPorTipoCard({required this.eventos});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Mostrar máx 6 — si hay más, "y N más" abajo.
    const maxItems = 6;
    final aMostrar = eventos.take(maxItems).toList();
    final restantes = eventos.length - aMostrar.length;
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Por tipo de evento'),
          const SizedBox(height: AppSpacing.sm),
          for (var i = 0; i < aMostrar.length; i++) ...[
            if (i > 0) AppHairline(color: c.border),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      etiquetaAlertaVolvo(aMostrar[i].tipo),
                      style: AppType.body.copyWith(color: c.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    '${aMostrar[i].cantidad}',
                    style: AppType.mono.copyWith(
                        color: c.text, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
          if (restantes > 0) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Y $restantes tipo${restantes == 1 ? '' : 's'} más',
              style: AppType.monoSm.copyWith(color: c.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}
