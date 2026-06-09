import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/agente_conversaciones_service.dart';

/// Dashboard del agente conversacional del bot WhatsApp (F del plan
/// 2026-06-08): tasa de éxito, tools más usadas, errores recientes, lista
/// navegable de chats. Reemplaza al script CLI `revisar_agente_reportes.js`
/// con visibilidad continua para el admin desde la app.
///
/// Se accede desde la pantalla "Estado del Bot" (icon button en actions).
/// Lee de `AGENTE_CONVERSACIONES` — colección con TTL 60d que el bot popula
/// en `_loggear` (whatsapp-bot/src/agente.js) por cada interacción.
class AdminAgenteConversacionesScreen extends StatefulWidget {
  const AdminAgenteConversacionesScreen({super.key});

  @override
  State<AdminAgenteConversacionesScreen> createState() =>
      _AdminAgenteConversacionesScreenState();
}

class _AdminAgenteConversacionesScreenState
    extends State<AdminAgenteConversacionesScreen> {
  int _ventanaDias = 7;
  String _filtroRol = 'TODOS';
  bool _soloProblemas = false;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Agente conversacional',
      body: StreamBuilder<List<AgenteChat>>(
        stream: AgenteConversacionesService.streamUltimos(limit: 250),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el log del agente',
              subtitle: snap.error.toString(),
            );
          }
          if (!snap.hasData) {
            return const AppLoadingState();
          }
          final todos = AgenteConversacionesService.filtrarPorDias(
              snap.data!, _ventanaDias);
          final filtrados = todos.where((c) {
            if (_filtroRol != 'TODOS' && c.rol != _filtroRol) return false;
            if (_soloProblemas && !c.tieneProblema) return false;
            return true;
          }).toList();
          final kpis = AgenteKpis.calcular(todos);
          return ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _Selectores(
                ventanaDias: _ventanaDias,
                onVentana: (d) => setState(() => _ventanaDias = d),
                filtroRol: _filtroRol,
                onRol: (r) => setState(() => _filtroRol = r),
                soloProblemas: _soloProblemas,
                onSoloProblemas: (v) => setState(() => _soloProblemas = v),
              ),
              const SizedBox(height: AppSpacing.lg),
              _KpisRow(kpis: kpis, dias: _ventanaDias),
              const SizedBox(height: AppSpacing.lg),
              _SeccionTools(porTool: kpis.porTool),
              const SizedBox(height: AppSpacing.lg),
              if (kpis.errores > 0) ...[
                _SeccionErrores(porError: kpis.porError),
                const SizedBox(height: AppSpacing.lg),
              ],
              _SeccionChats(
                chats: filtrados,
                totalSinFiltrar: todos.length,
                hayFiltroActivo: _filtroRol != 'TODOS' || _soloProblemas,
              ),
            ],
          );
        },
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// SELECTORES — ventana / rol / solo problemas
// ────────────────────────────────────────────────────────────────────────

class _Selectores extends StatelessWidget {
  final int ventanaDias;
  final ValueChanged<int> onVentana;
  final String filtroRol;
  final ValueChanged<String> onRol;
  final bool soloProblemas;
  final ValueChanged<bool> onSoloProblemas;

  const _Selectores({
    required this.ventanaDias,
    required this.onVentana,
    required this.filtroRol,
    required this.onRol,
    required this.soloProblemas,
    required this.onSoloProblemas,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final d in const [1, 3, 7, 14, 30])
              _Chip(
                label: d == 1 ? '24h' : '${d}d',
                activo: ventanaDias == d,
                onTap: () => onVentana(d),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final r in const ['TODOS', 'CHOFER', 'ADMIN', 'SUPERVISOR', 'SEG_HIGIENE'])
              _Chip(
                label: r == 'TODOS' ? 'Todos' : r,
                activo: filtroRol == r,
                onTap: () => onRol(r),
              ),
            _Chip(
              label: 'Solo problemas',
              activo: soloProblemas,
              onTap: () => onSoloProblemas(!soloProblemas),
              icon: Icons.warning_amber_rounded,
            ),
          ],
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool activo;
  final VoidCallback onTap;
  final IconData? icon;
  const _Chip({
    required this.label,
    required this.activo,
    required this.onTap,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: activo ? c.brand.withValues(alpha: 0.15) : c.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
                color: activo ? c.brand.withValues(alpha: 0.6) : c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: activo ? c.brand : c.textMuted),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: AppType.label.copyWith(
                  color: activo ? c.brand : c.text,
                  fontWeight: activo ? FontWeight.w600 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// KPI ROW — total · tasa éxito · errores · fallbacks · por rol
// ────────────────────────────────────────────────────────────────────────

class _KpisRow extends StatelessWidget {
  final AgenteKpis kpis;
  final int dias;
  const _KpisRow({required this.kpis, required this.dias});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tasaColor = kpis.tasaExitoPct >= 95
        ? c.success
        : kpis.tasaExitoPct >= 85
            ? c.warning
            : c.error;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppEyebrow('Últimos ${dias == 1 ? "24 hs" : "$dias días"}'),
          const SizedBox(height: AppSpacing.md),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Kpi(label: 'CHATS', value: '${kpis.total}'),
                _Kpi(
                  label: 'TASA ÉXITO',
                  value: '${kpis.tasaExitoPct.toStringAsFixed(0)}%',
                  color: tasaColor,
                ),
                _Kpi(
                  label: 'ERRORES',
                  value: '${kpis.errores}',
                  color: kpis.errores == 0 ? c.text : c.error,
                ),
                _Kpi(
                  label: 'FALLBACKS',
                  value: '${kpis.fallbacks}',
                  color: kpis.fallbacks == 0 ? c.text : c.warning,
                ),
              ],
            ),
          ),
          if (kpis.porRol.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            const AppHairline(),
            const SizedBox(height: AppSpacing.md),
            Text('Por rol', style: AppType.eyebrow.copyWith(color: c.textMuted)),
            const SizedBox(height: 6),
            Wrap(
              spacing: AppSpacing.md,
              runSpacing: AppSpacing.sm,
              children: [
                for (final e in kpis.porRol.entries)
                  Text(
                    '${e.key}: ${e.value}',
                    style: AppType.monoSm.copyWith(color: c.textSecondary),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;
  const _Kpi({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppType.eyebrow.copyWith(color: c.textMuted)),
          const SizedBox(height: 4),
          Text(
            value,
            style: AppType.h4.copyWith(color: color ?? c.text),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// SECCIONES — tools / errores / chats
// ────────────────────────────────────────────────────────────────────────

class _SeccionTools extends StatelessWidget {
  final Map<String, int> porTool;
  const _SeccionTools({required this.porTool});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ordenadas = porTool.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final max = ordenadas.isEmpty ? 1 : ordenadas.first.value;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.info, size: 7),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('TOOLS USADAS', color: c.info),
              const Spacer(),
              Text('${ordenadas.length} distintas',
                  style: AppType.monoSm.copyWith(color: c.textMuted)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (ordenadas.isEmpty)
            Text(
              'Sin tools invocadas en el rango.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            )
          else
            for (final e in ordenadas.take(15)) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text('${e.value}',
                          textAlign: TextAlign.right,
                          style: AppType.mono.copyWith(color: c.text)),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Stack(
                        children: [
                          Container(
                            height: 14,
                            decoration: BoxDecoration(
                              color: c.surface3,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: max == 0 ? 0 : e.value / max,
                            child: Container(
                              height: 14,
                              decoration: BoxDecoration(
                                color: c.info.withValues(alpha: 0.7),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    SizedBox(
                      width: 180,
                      child: Text(
                        e.key,
                        style: AppType.monoSm.copyWith(color: c.textSecondary),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
        ],
      ),
    );
  }
}

class _SeccionErrores extends StatelessWidget {
  final Map<String, int> porError;
  const _SeccionErrores({required this.porError});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ordenados = porError.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.error, size: 7),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('ERRORES POR TIPO', color: c.error),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          for (final e in ordenados) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Text('${e.value}',
                      style: AppType.mono.copyWith(color: c.text)),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _labelError(e.key),
                      style:
                          AppType.bodySm.copyWith(color: c.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _labelError(String marca) {
    switch (marca) {
      case 'rate_limit_429':
        return 'Rate-limit (HTTP 429 / cuota)';
      case 'http_5xx':
        return 'Error servidor (HTTP 5xx)';
      case 'http_4xx':
        return 'Error cliente (HTTP 4xx)';
      case 'safety_block':
        return 'Bloqueado por seguridad del modelo';
      case 'sin_texto':
        return 'Sin texto (Gemini no respondió)';
      case 'max_iters':
        return 'Tope de iteraciones / tokens';
      default:
        return 'Otro';
    }
  }
}

class _SeccionChats extends StatelessWidget {
  final List<AgenteChat> chats;
  final int totalSinFiltrar;
  final bool hayFiltroActivo;
  const _SeccionChats({
    required this.chats,
    required this.totalSinFiltrar,
    required this.hayFiltroActivo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('CHATS'),
              const Spacer(),
              Text(
                hayFiltroActivo
                    ? '${chats.length} de $totalSinFiltrar'
                    : '${chats.length}',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (chats.isEmpty)
            Text(
              hayFiltroActivo
                  ? 'Ningún chat coincide con los filtros.'
                  : 'Sin chats en el rango.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            )
          else
            for (var i = 0; i < chats.length; i++) ...[
              if (i > 0) ...[
                const SizedBox(height: AppSpacing.md),
                const AppHairline(),
                const SizedBox(height: AppSpacing.md),
              ],
              _ChatRow(chat: chats[i]),
            ],
        ],
      ),
    );
  }
}

class _ChatRow extends StatelessWidget {
  final AgenteChat chat;
  const _ChatRow({required this.chat});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final cuandoStr = chat.creadoEn != null ? _fmtHoraFecha(chat.creadoEn!) : '—';
    final problema = chat.tieneProblema;
    final color = problema
        ? (chat.error != null ? c.error : c.warning)
        : c.textMuted;
    return InkWell(
      onTap: () => _abrirDetalle(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: AppDot(color, size: 6),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    cuandoStr,
                    style: AppType.mono.copyWith(color: c.text),
                  ),
                ),
                Text(
                  '${chat.nombre ?? chat.dni ?? '?'} · ${chat.rol}',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text(
                'P: ${chat.pregunta}',
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (chat.respuesta.isNotEmpty) ...[
              const SizedBox(height: 2),
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(
                  'R: ${chat.respuesta}',
                  style: AppType.bodySm.copyWith(color: c.textMuted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
            if (chat.toolsUsadas.isNotEmpty || problema) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Wrap(
                  spacing: 4,
                  children: [
                    for (final t in chat.toolsUsadas)
                      AppBadge(text: t, color: c.info, size: AppBadgeSize.sm),
                    if (chat.esFallback)
                      AppBadge(
                          text: 'fallback', color: c.warning, size: AppBadgeSize.sm),
                    if (chat.error != null && chat.error!.isNotEmpty)
                      AppBadge(
                          text: chat.error!.length > 40
                              ? '${chat.error!.substring(0, 40)}…'
                              : chat.error!,
                          color: c.error,
                          size: AppBadgeSize.sm),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _abrirDetalle(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface1,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) => _DetalleChat(chat: chat),
    );
  }
}

class _DetalleChat extends StatelessWidget {
  final AgenteChat chat;
  const _DetalleChat({required this.chat});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final screenH = MediaQuery.of(context).size.height;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: screenH * 0.85),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const AppEyebrow('CHAT DEL AGENTE'),
                const SizedBox(height: AppSpacing.sm),
                _kv(c, 'Cuando', chat.creadoEn != null
                    ? _fmtHoraFecha(chat.creadoEn!)
                    : '—'),
                _kv(c, 'Quien',
                    '${chat.nombre ?? chat.dni ?? '?'} · ${chat.rol}'),
                if (chat.telefono != null) _kv(c, 'Tel', chat.telefono!),
                if (chat.modelo != null)
                  _kv(c, 'Modelo', '${chat.proveedor} · ${chat.modelo}'),
                if (chat.toolsUsadas.isNotEmpty)
                  _kv(c, 'Tools', chat.toolsUsadas.join(', ')),
                if (chat.esFallback)
                  _kv(c, 'Fallback', 'sí', valueColor: c.warning),
                if (chat.error != null && chat.error!.isNotEmpty)
                  _kv(c, 'Error', chat.error!, valueColor: c.error),
                const SizedBox(height: AppSpacing.md),
                Text('PREGUNTA',
                    style: AppType.eyebrow.copyWith(color: c.textMuted)),
                const SizedBox(height: 4),
                SelectableText(
                  chat.pregunta,
                  style: AppType.body.copyWith(color: c.text),
                ),
                const SizedBox(height: AppSpacing.md),
                Text('RESPUESTA',
                    style: AppType.eyebrow.copyWith(color: c.textMuted)),
                const SizedBox(height: 4),
                SelectableText(
                  chat.respuesta.isEmpty ? '(vacío)' : chat.respuesta,
                  style: AppType.body.copyWith(
                      color: chat.respuesta.isEmpty
                          ? c.textMuted
                          : c.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _kv(AppColorsExt c, String k, String v, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 78,
            child: Text(
              k.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              v,
              style: AppType.bodySm.copyWith(color: valueColor ?? c.text),
            ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Format
// ────────────────────────────────────────────────────────────────────────

String _fmtHoraFecha(DateTime d) {
  final dd = d.day.toString().padLeft(2, '0');
  final mm = d.month.toString().padLeft(2, '0');
  final hh = d.hour.toString().padLeft(2, '0');
  final mi = d.minute.toString().padLeft(2, '0');
  return '$dd/$mm $hh:$mi';
}
