import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/auto_sync_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../providers/sync_dashboard_provider.dart';

/// Dashboard de observabilidad del sync con Volvo Connect.
///
/// Muestra (en este orden):
/// - Estado actual del ciclo (activos / éxito / errores / saltados)
/// - Progreso del ciclo actual (cuántos vehículos van procesados)
/// - Métricas globales (total, tasa de éxito, latencia, último sync)
/// - Botón "ejecutar ahora" para disparar un ciclo on-demand
/// - Actividad reciente (lista de últimos 50 eventos por unidad)
/// - Histórico de ciclos (últimos 15)
class SyncDashboardScreen extends StatelessWidget {
  const SyncDashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Sync Dashboard',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Resetear contadores',
          onPressed: () => context.read<SyncDashboardProvider>().reset(),
        ),
      ],
      body: Consumer<SyncDashboardProvider>(
        builder: (context, dash, _) => _Body(dash: dash),
      ),
    );
  }
}

// =============================================================================
// CUERPO
// =============================================================================

class _Body extends StatelessWidget {
  final SyncDashboardProvider dash;
  const _Body({required this.dash});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ─── Cards de estado ────────────────────────────────────────
        const _SectionHeader(label: 'Estado actual'),
        const SizedBox(height: 8),
        Row(
          children: [
            _LiveCard(
              label: 'Activos',
              value: dash.activeSyncs.toString(),
              color: AppColors.accentOrange,
              icon: Icons.sync,
            ),
            const SizedBox(width: 10),
            _LiveCard(
              label: 'Éxito',
              value: dash.successSyncs.toString(),
              color: AppColors.accentGreen,
              icon: Icons.check_circle,
            ),
            const SizedBox(width: 10),
            _LiveCard(
              label: 'Errores',
              value: dash.failedSyncs.toString(),
              color: AppColors.accentRed,
              icon: Icons.error,
            ),
          ],
        ),
        const SizedBox(height: 24),

        // ─── Ciclo actual ───────────────────────────────────────────
        if (dash.cycleTotal > 0) ...[
          const _SectionHeader(label: 'Ciclo actual'),
          const SizedBox(height: 8),
          _CicloProgress(
            cycle: dash.cycle,
            procesados: dash.cycleProcessed,
            total: dash.cycleTotal,
          ),
          const SizedBox(height: 24),
        ],

        // ─── Métricas globales ─────────────────────────────────────
        const _SectionHeader(label: 'Métricas globales'),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.8,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            _StatTile(
              label: 'Total syncs',
              value: dash.totalSyncs.toString(),
            ),
            _StatTile(
              label: 'Tasa de éxito',
              value: '${(dash.successRate * 100).toStringAsFixed(1)}%',
              accent: dash.successRate >= 0.9
                  ? AppColors.accentGreen
                  : (dash.successRate >= 0.7
                      ? AppColors.accentOrange
                      : AppColors.accentRed),
            ),
            _StatTile(
              label: 'Latencia avg',
              value: '${dash.avgLatencyMs.toStringAsFixed(0)} ms',
            ),
            _StatTile(
              label: 'Saltados',
              value: dash.skippedSyncs.toString(),
              accent: Colors.white60,
            ),
            _StatTile(
              label: 'Último sync',
              value: dash.lastSyncAt != null
                  ? AppFormatters.formatearHora(dash.lastSyncAt!, conSegundos: true)
                  : '—',
            ),
            _StatTile(
              label: 'Ciclos',
              value: dash.cycle.toString(),
            ),
          ],
        ),
        const SizedBox(height: 24),

        // ─── Botón disparar ahora ──────────────────────────────────
        const _BotonEjecutarAhora(),
        const SizedBox(height: 24),

        // ─── Actividad reciente ────────────────────────────────────
        const _SectionHeader(label: 'Actividad reciente'),
        const SizedBox(height: 8),
        _ActividadReciente(eventos: dash.eventosRecientes),
        const SizedBox(height: 24),

        // ─── Histórico de ciclos ───────────────────────────────────
        const _SectionHeader(label: 'Histórico de ciclos'),
        const SizedBox(height: 8),
        _HistoricoCiclos(ciclos: dash.historicoCiclos),
        const SizedBox(height: 30),
      ],
    );
  }

}

// =============================================================================
// BOTÓN EJECUTAR AHORA
// =============================================================================

class _BotonEjecutarAhora extends StatefulWidget {
  const _BotonEjecutarAhora();

  @override
  State<_BotonEjecutarAhora> createState() => _BotonEjecutarAhoraState();
}

class _BotonEjecutarAhoraState extends State<_BotonEjecutarAhora> {
  bool _ejecutando = false;

  Future<void> _disparar() async {
    if (_ejecutando) return;
    setState(() => _ejecutando = true);
    final messenger = ScaffoldMessenger.of(context);
    final svc = context.read<AutoSyncService>();

    final lanzado = await svc.runNow();

    if (!mounted) return;
    setState(() => _ejecutando = false);
    final msg = lanzado ? 'Ciclo manual disparado.' : 'Ya hay un ciclo en curso, esperá a que termine.';
    if (lanzado) {
      AppFeedback.successOn(messenger, msg);
    } else {
      AppFeedback.warningOn(messenger, msg);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: _ejecutando ? null : _disparar,
        icon: _ejecutando
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.accentCyan),
              )
            : const Icon(Icons.play_arrow, color: AppColors.accentCyan),
        label: Text(
          _ejecutando ? 'EJECUTANDO...' : 'EJECUTAR CICLO AHORA',
          style: const TextStyle(
            color: AppColors.accentCyan,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: AppColors.accentCyan),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// ACTIVIDAD RECIENTE
// =============================================================================

class _ActividadReciente extends StatelessWidget {
  final List<SyncEvent> eventos;
  const _ActividadReciente({required this.eventos});

  @override
  Widget build(BuildContext context) {
    if (eventos.isEmpty) {
      return const AppCard(
        margin: EdgeInsets.zero,
        padding: EdgeInsets.all(20),
        child: Text(
          'Sin actividad todavía. El primer ciclo arranca al abrir la app '
          'y se repite cada minuto. Si seguís sin ver nada, tocá '
          '"EJECUTAR CICLO AHORA" para disparar uno manual.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }

    return AppCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (int i = 0; i < eventos.length; i++) ...[
            _EventoTile(evento: eventos[i]),
            if (i < eventos.length - 1)
              const Divider(color: Colors.white10, height: 1),
          ],
        ],
      ),
    );
  }
}

class _EventoTile extends StatelessWidget {
  final SyncEvent evento;
  const _EventoTile({required this.evento});

  ({IconData icon, Color color, String label}) get _info {
    switch (evento.tipo) {
      case SyncEventTipo.exito:
        return (
          icon: Icons.check_circle,
          color: AppColors.accentGreen,
          label: 'OK'
        );
      case SyncEventTipo.error:
        return (
          icon: Icons.error,
          color: AppColors.accentRed,
          label: 'ERROR'
        );
      case SyncEventTipo.saltado:
        return (
          icon: Icons.skip_next,
          color: Colors.white54,
          label: 'SKIP'
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(info.icon, color: info.color, size: 16),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      evento.patente,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: info.color.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        info.label,
                        style: TextStyle(
                          color: info.color,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      AppFormatters.formatearHora(evento.cuando, conSegundos: true),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                if (evento.mensaje != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    evento.mensaje!,
                    style: TextStyle(
                      color: info.color.withAlpha(180),
                      fontSize: 11,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// HISTÓRICO DE CICLOS
// =============================================================================

class _HistoricoCiclos extends StatelessWidget {
  final List<CicloResumen> ciclos;
  const _HistoricoCiclos({required this.ciclos});

  @override
  Widget build(BuildContext context) {
    if (ciclos.isEmpty) {
      return const AppCard(
        margin: EdgeInsets.zero,
        padding: EdgeInsets.all(20),
        child: Text(
          'No hay ciclos completados todavía.',
          style: TextStyle(color: Colors.white54, fontSize: 12),
        ),
      );
    }

    // Tabla con 7 columnas — en mobile (<400 dp) las 4 Expanded del medio
    // (Tot/OK/Err/Skip) quedan ~50 dp y los números de 3 dígitos chocan.
    // Forzamos un mínimo de ancho con scroll horizontal: en desktop entra
    // sin scroll (Expanded distribuye), en mobile aparece scrollbar.
    return AppCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 480),
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  children: [
                    SizedBox(width: 36, child: _Hdr('#')),
                    SizedBox(width: 60, child: _Hdr('Hora')),
                    Expanded(child: _Hdr('Tot')),
                    Expanded(child: _Hdr('OK')),
                    Expanded(child: _Hdr('Err')),
                    Expanded(child: _Hdr('Skip')),
                    SizedBox(width: 50, child: _Hdr('Dur')),
                  ],
                ),
              ),
              const Divider(color: Colors.white10, height: 1),
              for (int i = 0; i < ciclos.length; i++) ...[
                _CicloTile(c: ciclos[i]),
                if (i < ciclos.length - 1)
                  const Divider(color: Colors.white10, height: 1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Hdr extends StatelessWidget {
  final String t;
  const _Hdr(this.t);
  @override
  Widget build(BuildContext context) => Text(
        t,
        style: const TextStyle(
          color: AppColors.accentGreen,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      );
}

class _CicloTile extends StatelessWidget {
  final CicloResumen c;
  const _CicloTile({required this.c});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '#${c.numero}',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(
            width: 60,
            child: Text(
              AppFormatters.formatearHora(c.inicio),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Expanded(child: _Num(c.total, Colors.white)),
          Expanded(child: _Num(c.exito, AppColors.accentGreen)),
          Expanded(child: _Num(c.error, AppColors.accentRed)),
          Expanded(child: _Num(c.saltado, Colors.white54)),
          SizedBox(
            width: 50,
            child: Text(
              '${c.duracion.inSeconds}s',
              style: const TextStyle(
                color: AppColors.accentCyan,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Num extends StatelessWidget {
  final int n;
  final Color color;
  const _Num(this.n, this.color);
  @override
  Widget build(BuildContext context) => Text(
        n.toString(),
        style: TextStyle(
          color: n > 0 ? color : Colors.white24,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      );
}

// =============================================================================
// COMPONENTES VIEJOS (ya existían)
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          color: AppColors.accentGreen,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _LiveCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        padding: const EdgeInsets.all(14),
        margin: EdgeInsets.zero,
        borderColor: color.withAlpha(60),
        child: Column(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 8),
            // FittedBox: si "1.234" no entra (3 cards en mobile, ~105 dp
            // por card) escala automáticamente. fontSize 24 es ambicioso.
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CicloProgress extends StatelessWidget {
  final int cycle;
  final int procesados;
  final int total;

  const _CicloProgress({
    required this.cycle,
    required this.procesados,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final progress = total == 0 ? 0.0 : (procesados / total).clamp(0.0, 1.0);
    return AppCard(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timelapse,
                  color: AppColors.accentCyan, size: 18),
              const SizedBox(width: 8),
              Text(
                'Ciclo #$cycle',
                style: const TextStyle(
                  color: AppColors.accentCyan,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1,
                ),
              ),
              const Spacer(),
              Text(
                '$procesados / $total',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 8,
              backgroundColor: Colors.white12,
              valueColor: const AlwaysStoppedAnimation(AppColors.accentCyan),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _StatTile({
    required this.label,
    required this.value,
    this.accent = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(12),
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 11,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }
}
