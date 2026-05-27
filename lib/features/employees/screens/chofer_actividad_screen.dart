import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../eco_driving/utils/etiquetas_alerta_volvo.dart';
import '../services/chofer_actividad_service.dart';

/// Tablero personal del chofer: km manejados, tractores que usó y
/// eventos Volvo asociados, en una ventana de 7/30/90 días.
///
/// Se accede desde la ficha del chofer (admin_personal_lista_widgets)
/// con el botón "Ver actividad". Reusa los datos que ya guardan
/// `AsignacionVehiculoService` (con snapshot de odómetro Sitrack desde
/// Fase 2) y `volvoAlertasPoller` (con `chofer_dni` snapshoteado).
///
/// Es read-only — el admin solo consume métricas, no edita nada acá.
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
                  return const Center(
                    child: CircularProgressIndicator(
                        color: AppColors.success),
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
// HEADER
// =============================================================================

class _Header extends StatelessWidget {
  final String nombre;
  final String dni;
  const _Header({required this.nombre, required this.dni});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Row(
        children: [
          const Icon(Icons.person, color: AppColors.success, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  nombre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  'DNI $dni',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white54, fontSize: 11),
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
// SELECTOR DE PERÍODO
// =============================================================================

class _SelectorPeriodo extends StatelessWidget {
  final int diasActuales;
  final ValueChanged<int> onCambio;
  const _SelectorPeriodo({required this.diasActuales, required this.onCambio});

  static const _opciones = [7, 30, 90];

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Row(
        children: [
          for (final d in _opciones) ...[
            Expanded(child: _Chip(dias: d, selected: d == diasActuales, onTap: () => onCambio(d))),
            if (d != _opciones.last) const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final int dias;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.dias, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.success : Colors.white38;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.success.withAlpha(25)
              : Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withAlpha(80)),
        ),
        alignment: Alignment.center,
        child: Text(
          'Últimos $dias días',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // ─── KPIs ───
        Row(
          children: [
            Expanded(
              child: _KpiCard(
                label: 'KM RECORRIDOS',
                valor: _formatearMiles(resumen.kmTotales),
                unidad: 'km',
                color: AppColors.success,
                icono: Icons.straighten,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KpiCard(
                label: 'EVENTOS VOLVO',
                valor: '${resumen.totalEventos}',
                color: resumen.totalEventos > 0
                    ? AppColors.warning
                    : Colors.white54,
                icono: Icons.bolt,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _KpiCard(
                label: 'ASIGNACIONES',
                valor: '${resumen.asignaciones}',
                color: AppColors.accentBlue,
                icono: Icons.swap_horiz,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _KpiCard(
                label: 'TRACTORES',
                valor: '${resumen.tractores.length}',
                color: AppColors.accentBlue,
                icono: Icons.local_shipping,
              ),
            ),
          ],
        ),

        // Aviso de datos parciales si hay asignaciones legacy.
        if (resumen.asignacionesSinTelemetria > 0) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withAlpha(8),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, size: 14, color: Colors.white54),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${resumen.asignacionesSinTelemetria} asignación'
                    '${resumen.asignacionesSinTelemetria == 1 ? '' : 'es'} '
                    'sin datos de odómetro Sitrack — los km de '
                    '${resumen.asignacionesSinTelemetria == 1 ? 'esa' : 'esas'} '
                    'no se pudieron contar.',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ],

        const SizedBox(height: 24),

        // ─── Tractores manejados ───
        if (resumen.tractores.isNotEmpty) ...[
          const _Titulo(label: 'TRACTORES MANEJADOS', icono: Icons.local_shipping),
          const SizedBox(height: 8),
          ...resumen.tractores.map((t) => _TractorTile(tractor: t)),
          const SizedBox(height: 24),
        ],

        // ─── Eventos por severidad ───
        if (resumen.totalEventos > 0) ...[
          const _Titulo(label: 'EVENTOS VOLVO', icono: Icons.bolt),
          const SizedBox(height: 8),
          _EventosPorSeveridadCard(eventos: resumen.eventosPorSeveridad),
          const SizedBox(height: 12),
          if (resumen.eventosPorTipo.isNotEmpty)
            _EventosPorTipoCard(eventos: resumen.eventosPorTipo),
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

class _KpiCard extends StatelessWidget {
  final String label;
  final String valor;
  final String? unidad;
  final Color color;
  final IconData icono;

  const _KpiCard({
    required this.label,
    required this.valor,
    required this.color,
    required this.icono,
    this.unidad,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icono, color: color, size: 16),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color.withAlpha(180),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                valor,
                style: TextStyle(
                  color: color,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (unidad != null) ...[
                const SizedBox(width: 4),
                Text(
                  unidad!,
                  style: TextStyle(
                    color: color.withAlpha(180),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Titulo extends StatelessWidget {
  final String label;
  final IconData icono;
  const _Titulo({required this.label, required this.icono});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icono, color: AppColors.success, size: 16),
        const SizedBox(width: 8),
        Text(
          label,
          style: const TextStyle(
            color: AppColors.success,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
      ],
    );
  }
}

class _TractorTile extends StatelessWidget {
  final TractorUsado tractor;
  const _TractorTile({required this.tractor});

  @override
  Widget build(BuildContext context) {
    final km = tractor.kmEnPeriodo;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Text(
            tractor.patente,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 14,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          if (tractor.activaActual)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: AppColors.success.withAlpha(25),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: AppColors.success.withAlpha(80)),
              ),
              child: const Text(
                'ACTUAL',
                style: TextStyle(
                  color: AppColors.success,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.6,
                ),
              ),
            ),
          const Spacer(),
          if (km == null)
            const Text(
              '— km',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            )
          else ...[
            Text(
              '${_Resumen._formatearMiles(km)} km',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (tractor.esParcial) ...[
              const SizedBox(width: 4),
              const Tooltip(
                message: 'Asignación en curso — km parcial',
                child: Icon(Icons.history, size: 13, color: Colors.white38),
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
    final high = eventos['HIGH'] ?? 0;
    final medium = eventos['MEDIUM'] ?? 0;
    final low = eventos['LOW'] ?? 0;
    return Row(
      children: [
        Expanded(
          child: _SeveridadMini(
              label: 'HIGH', valor: high, color: AppColors.error),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SeveridadMini(
              label: 'MEDIUM', valor: medium, color: AppColors.warning),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _SeveridadMini(
              label: 'LOW', valor: low, color: AppColors.success),
        ),
      ],
    );
  }
}

class _SeveridadMini extends StatelessWidget {
  final String label;
  final int valor;
  final Color color;
  const _SeveridadMini({
    required this.label,
    required this.valor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: valor > 0 ? color.withAlpha(20) : Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: valor > 0 ? color.withAlpha(80) : Colors.white12,
        ),
      ),
      child: Column(
        children: [
          Text(
            '$valor',
            style: TextStyle(
              color: valor > 0 ? color : Colors.white54,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            label,
            style: TextStyle(
              color: valor > 0 ? color : Colors.white54,
              fontSize: 9,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
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
    // Mostrar máx 6 — si hay más, "y N más" abajo.
    const maxItems = 6;
    final aMostrar = eventos.take(maxItems).toList();
    final restantes = eventos.length - aMostrar.length;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Por tipo de evento',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 8),
          for (final e in aMostrar)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      etiquetaAlertaVolvo(e.tipo),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${e.cantidad}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          if (restantes > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Y $restantes tipo${restantes == 1 ? '' : 's'} más',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}
