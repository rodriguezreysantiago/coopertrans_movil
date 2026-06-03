import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/whatsapp_historico_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// M8 + M10 — Pantalla "Historial WhatsApp": auditar mensajes pasados
/// del bot (ENVIADO / ERROR) con filtros y buscador. REFACTOR NÚCLEO (jun 2026).
///
/// COLA_WHATSAPP tiene TTL muy corto (horas) porque su rol es "cola de
/// trabajo". Esto rompía el flujo "¿se mandó el aviso del lunes?" — para
/// el martes ya no había rastro. Esta pantalla resuelve ese caso leyendo
/// WHATSAPP_HISTORICO (TTL 30 días, doc 1:1 con COLA_WHATSAPP cuando
/// llega a estado terminal).
///
/// Server-side: rango fecha + 1 filtro (estado XOR destinatario_id XOR
/// origen) — los compound indexes solo cubren un filtro + registrado_en.
/// Client-side: buscador full-text sobre los resultados (rápido porque
/// la página es 50).
///
/// Layout Núcleo: header eyebrow + hero (cantidad de resultados),
/// AppKpiStrip total/entregados/leídos, card de filtros con tokens,
/// buscador Núcleo, filas AppCard con badge de estado + ack ✓✓ y
/// timestamps/origen en mono. Consulta, filtros y paginación INTACTOS.
class AdminWhatsappHistoricoScreen extends StatefulWidget {
  /// M6 — filtro inicial por origen, para deep-link "Ver último enviado"
  /// desde la card "Reglas de notificación" del dashboard del bot. Si
  /// es null, abre sin filtro.
  final String? initialOrigen;
  const AdminWhatsappHistoricoScreen({super.key, this.initialOrigen});

  @override
  State<AdminWhatsappHistoricoScreen> createState() =>
      _AdminWhatsappHistoricoScreenState();
}

class _AdminWhatsappHistoricoScreenState
    extends State<AdminWhatsappHistoricoScreen> {
  final _service = WhatsAppHistoricoService();

  /// Rango de fechas a consultar. Default: últimos 7 días.
  late DateTime _desde;
  late DateTime _hasta;

  /// Filtro de estado (null = todos). ENVIADO o ERROR.
  String? _filtroEstado;

  /// Filtro por destinatario DNI (input opcional). Empty = sin filtro.
  final TextEditingController _dniCtrl = TextEditingController();

  /// Filtro por origen (input opcional, ej "vigilador_jornada",
  /// "cron_service_diario"). Empty = sin filtro.
  final TextEditingController _origenCtrl = TextEditingController();

  /// Buscador client-side sobre resultados (tel, mensaje, dni, origen).
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Estado del fetch.
  bool _cargando = false;
  String? _error;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = const [];

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _hasta = DateTime(ahora.year, ahora.month, ahora.day, 23, 59, 59);
    _desde =
        DateTime(ahora.year, ahora.month, ahora.day - 6, 0, 0, 0); // 7 días
    // M6 — deep-link desde la card "Reglas de notificación".
    if (widget.initialOrigen != null && widget.initialOrigen!.isNotEmpty) {
      _origenCtrl.text = widget.initialOrigen!;
    }
    _ejecutarConsulta();
  }

  @override
  void dispose() {
    _dniCtrl.dispose();
    _origenCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Cuenta filtros server-side activos (combinables con el rango fecha).
  /// Si > 1 mostramos un warning porque Firestore no soporta 2 igualdades
  /// + range sin compound indexes que no tenemos.
  int get _filtrosServerActivos {
    int n = 0;
    if (_filtroEstado != null) n++;
    if (_dniCtrl.text.trim().isNotEmpty) n++;
    if (_origenCtrl.text.trim().isNotEmpty) n++;
    return n;
  }

  Future<void> _ejecutarConsulta() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final snap = await _service.consultar(
        destinatarioId:
            _dniCtrl.text.trim().isEmpty ? null : _dniCtrl.text.trim(),
        origen:
            _origenCtrl.text.trim().isEmpty ? null : _origenCtrl.text.trim(),
        estado: _filtroEstado,
        desde: _desde,
        hasta: _hasta,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _docs = snap.docs;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _cargando = false;
      });
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filtrarPorQuery(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return docs;
    return docs.where((doc) {
      final m = doc.data();
      bool contiene(dynamic v) =>
          v != null && v.toString().toLowerCase().contains(q);
      return contiene(m['telefono']) ||
          contiene(m['mensaje']) ||
          contiene(m['origen']) ||
          contiene(m['destinatario_id']) ||
          contiene(m['destinatario_coleccion']) ||
          contiene(m['alert_patente']);
    }).toList();
  }

  Future<void> _elegirRango() async {
    final ahora = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate:
          ahora.subtract(const Duration(days: WhatsAppHistoricoService.ttlDias)),
      lastDate: ahora,
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
    );
    if (picked == null) return;
    setState(() {
      _desde =
          DateTime(picked.start.year, picked.start.month, picked.start.day);
      _hasta = DateTime(
          picked.end.year, picked.end.month, picked.end.day, 23, 59, 59);
    });
    await _ejecutarConsulta();
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _filtrarPorQuery(_docs);
    return AppScaffold(
      title: 'Historial WhatsApp',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            cantidad: _cargando ? null : filtrados.length,
            rango: '${AppFormatters.formatearFechaCorta(_desde)} → '
                '${AppFormatters.formatearFechaCorta(_hasta)}',
            onCambiarRango: _elegirRango,
          ),
          // KPIs sobre los resultados cargados (no los filtrados client-side,
          // para que el panorama del rango sea estable mientras se busca).
          if (!_cargando && _error == null && _docs.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
              child: _ResumenHistorico(docs: _docs),
            ),
          _filtrosCard(),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: _busquedaInput(),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(child: _lista(filtrados)),
        ],
      ),
    );
  }

  Widget _filtrosCard() {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: AppCard(
        tier: 2,
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Chips de estado.
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _chipEstado(null, 'Todos'),
                _chipEstado('ENVIADO', 'Enviados'),
                _chipEstado('ERROR', 'Errores'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            // DNI + origen + botón buscar.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: AppInput(
                    controller: _dniCtrl,
                    hint: 'DNI destinatario',
                    mono: true,
                    keyboardType: TextInputType.number,
                    onSubmitted: (_) => _ejecutarConsulta(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: AppInput(
                    controller: _origenCtrl,
                    hint: 'Origen',
                    mono: true,
                    onSubmitted: (_) => _ejecutarConsulta(),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _BotonBuscar(onTap: _ejecutarConsulta),
              ],
            ),
            if (_filtrosServerActivos > 1)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, size: 14, color: c.warning),
                    const SizedBox(width: AppSpacing.xs),
                    Expanded(
                      child: Text(
                        'Combinar estado + DNI + origen puede requerir un índice '
                        'extra. Si la consulta tarda o falla, dejá un solo filtro '
                        'server-side y refiná con la búsqueda.',
                        style: AppType.label.copyWith(color: c.warning),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _chipEstado(String? value, String label) {
    final c = context.colors;
    final selected = _filtroEstado == value;
    // Color semántico según el estado representado por el chip.
    final accent = value == 'ENVIADO'
        ? c.success
        : value == 'ERROR'
            ? c.error
            : c.brand;
    return InkWell(
      onTap: () {
        setState(() => _filtroEstado = value);
        _ejecutarConsulta();
      },
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color:
              selected ? accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? accent.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(
            color: selected ? accent : c.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _busquedaInput() {
    return AppInput(
      controller: _searchCtrl,
      hint: 'Buscar dentro de los resultados (texto / teléfono / patente)',
      icon: Icons.search,
      onChanged: (v) => setState(() => _query = v),
      trailingAction: _query.isEmpty ? null : 'Limpiar',
      onTrailingTap: _query.isEmpty
          ? null
          : () {
              _searchCtrl.clear();
              setState(() => _query = '');
            },
    );
  }

  Widget _lista(List<QueryDocumentSnapshot<Map<String, dynamic>>> filtrados) {
    if (_cargando) return const AppLoadingState();
    if (_error != null) {
      return AppErrorState(subtitle: _error!);
    }
    if (filtrados.isEmpty) {
      return AppEmptyState(
        icon: Icons.history_toggle_off,
        title: _query.isNotEmpty
            ? 'Sin coincidencias para "$_query"'
            : 'Sin mensajes en el rango',
        subtitle:
            'Aflojar filtros o ampliar el rango de fechas (máximo 30 días).',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0, AppSpacing.lg, 88),
      itemCount: filtrados.length,
      itemBuilder: (ctx, i) => _ItemHistorico(
        doc: filtrados[i],
        onTap: () => _mostrarDetalle(context, filtrados[i]),
      ),
    );
  }

  void _mostrarDetalle(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sCtx) => _DetalleHistoricoSheet(doc: doc),
    );
  }
}

// =============================================================================
// HEADER — eyebrow + hero (cantidad) + pill de rango de fechas
// =============================================================================

class _Header extends StatelessWidget {
  /// Cantidad de mensajes (null mientras carga → muestra "—").
  final int? cantidad;
  final String rango;
  final VoidCallback onCambiarRango;

  const _Header({
    required this.cantidad,
    required this.rango,
    required this.onCambiarRango,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Historial WhatsApp'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      cantidad == null ? '—' : '$cantidad',
                      style: AppType.h2.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        cantidad == 1 ? 'mensaje' : 'mensajes',
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // Pill tappable con el rango de fechas activo.
          _PillRango(rango: rango, onTap: onCambiarRango),
        ],
      ),
    );
  }
}

/// Pill de rango de fechas. Tap abre el date range picker.
class _PillRango extends StatelessWidget {
  final String rango;
  final VoidCallback onTap;
  const _PillRango({required this.rango, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: c.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_today_outlined, size: 14, color: c.textSecondary),
            const SizedBox(width: 6),
            Text(
              rango,
              style: AppType.monoSm.copyWith(
                color: c.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// RESUMEN — AppKpiStrip total / entregados / leídos (M11 acks)
// =============================================================================

class _ResumenHistorico extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  const _ResumenHistorico({required this.docs});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    var enviados = 0, errores = 0, entregados = 0, leidos = 0;
    for (final doc in docs) {
      final m = doc.data();
      final estado = (m['estado'] ?? '').toString();
      if (estado == 'ERROR') {
        errores++;
      } else {
        enviados++;
      }
      if (m['entregado_en'] is Timestamp) entregados++;
      if (m['leido_en'] is Timestamp) leidos++;
    }

    return AppKpiStrip(
      stats: [
        AppStat(label: 'Total', value: '${docs.length}'),
        AppStat(label: 'Enviados', value: '$enviados', accent: c.success),
        AppStat(label: 'Entregados', value: '$entregados', accent: c.info),
        AppStat(label: 'Leídos', value: '$leidos', accent: c.brand),
        if (errores > 0)
          AppStat(label: 'Errores', value: '$errores', accent: c.error),
      ],
    );
  }
}

/// Botón cuadrado de búsqueda (dispara la consulta server-side).
class _BotonBuscar extends StatelessWidget {
  final VoidCallback onTap;
  const _BotonBuscar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        height: 46,
        width: 46,
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: c.borderStrong),
        ),
        child: Icon(Icons.search, size: 18, color: c.textSecondary),
      ),
    );
  }
}

// =============================================================================
// ITEM — fila AppCard con badge de estado + ack ✓✓ + mono
// =============================================================================

class _ItemHistorico extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onTap;
  const _ItemHistorico({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = doc.data();
    final estado = (m['estado'] ?? '').toString();
    final esError = estado == 'ERROR';
    final color = esError ? c.error : c.success;
    final telefono = (m['telefono'] ?? '').toString();
    final mensaje = (m['mensaje'] ?? '').toString();
    final origen = (m['origen'] ?? '').toString();
    final registradoEn = m['registrado_en'];
    final entregadoEn = m['entregado_en']; // M11
    final leidoEn = m['leido_en']; // M11
    final hora = registradoEn is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(registradoEn.toDate())
        : '—';
    final preview =
        mensaje.length > 100 ? '${mensaje.substring(0, 100)}…' : mensaje;

    return AppCard(
      tier: 1,
      accent: color,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppBadge(
                text: estado.isEmpty ? '—' : estado,
                color: color,
                size: AppBadgeSize.sm,
                dot: true,
              ),
              // M11 — checkmarks de ack. Solo si NO es error.
              if (!esError) ...[
                const SizedBox(width: 6),
                _AckIcon(
                  entregadoEn:
                      entregadoEn is Timestamp ? entregadoEn.toDate() : null,
                  leidoEn: leidoEn is Timestamp ? leidoEn.toDate() : null,
                ),
              ],
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  PhoneFormatter.paraMostrar(telefono),
                  style: AppType.mono.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                hora,
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            preview,
            style: AppType.bodySm.copyWith(color: c.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (origen.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              origen,
              style: AppType.monoSm.copyWith(color: c.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _DetalleHistoricoSheet extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _DetalleHistoricoSheet({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final m = doc.data();
    final estado = (m['estado'] ?? '').toString();
    final esError = estado == 'ERROR';
    final color = esError ? c.error : c.success;
    final telefono = (m['telefono'] ?? '').toString();
    final mensaje = (m['mensaje'] ?? '').toString();
    final origen = (m['origen'] ?? '').toString();
    final destinatarioId = (m['destinatario_id'] ?? '').toString();
    final destinatarioColec = (m['destinatario_coleccion'] ?? '').toString();
    final alertPatente = (m['alert_patente'] ?? '').toString();
    final waId = (m['wa_message_id'] ?? '').toString();
    final error = (m['error'] ?? '').toString();
    final registrado = m['registrado_en'];
    final entregado = m['entregado_en']; // M11
    final leido = m['leido_en']; // M11
    final fechaTxt = registrado is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(registrado.toDate())
        : '—';
    final entregadoTxt = entregado is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(entregado.toDate())
        : '';
    final leidoTxt = leido is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(leido.toDate())
        : '';

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (ctx, scrollCtl) => SingleChildScrollView(
        controller: scrollCtl,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.xxl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.borderStrong,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Row(
              children: [
                Icon(
                  esError ? Icons.error_outline : Icons.check_circle_outline,
                  color: color,
                  size: 22,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  estado.isEmpty ? '—' : estado,
                  style: AppType.h4.copyWith(color: color),
                ),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: c.textMuted),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            _fila('Teléfono', PhoneFormatter.paraMostrar(telefono)),
            _fila('Enviado', fechaTxt),
            if (entregadoTxt.isNotEmpty) _fila('Entregado ✓✓', entregadoTxt),
            if (leidoTxt.isNotEmpty) _fila('Leído ✓✓ (azul)', leidoTxt),
            if (origen.isNotEmpty) _fila('Origen', origen),
            if (destinatarioId.isNotEmpty) _fila('Destinatario', destinatarioId),
            if (destinatarioColec.isNotEmpty) _fila('Colección', destinatarioColec),
            if (alertPatente.isNotEmpty) _fila('Patente', alertPatente),
            if (waId.isNotEmpty) _fila('WhatsApp ID', waId),
            const SizedBox(height: AppSpacing.md),
            const _SeccionTituloHist(
                icono: Icons.message_outlined, texto: 'Mensaje'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: c.border),
              ),
              child: SelectableText(mensaje, style: AppType.body),
            ),
            if (error.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              _SeccionTituloHist(
                  icono: Icons.error_outline, texto: 'Error', color: c.error),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.errorSoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.error.withValues(alpha: 0.4)),
                ),
                child: SelectableText(
                  error,
                  style: AppType.mono.copyWith(color: c.error),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Center(
              child: AppButton.ghost(
                label: doc.id,
                icon: Icons.copy,
                size: AppButtonSize.sm,
                onPressed: () {
                  final messenger = ScaffoldMessenger.of(context);
                  AppFeedback.successOn(
                    messenger,
                    'Doc ID copiado: ${doc.id}',
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fila(String label, String value) {
    return Builder(builder: (context) {
      final c = context.colors;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: Text(
                label,
                style: AppType.label.copyWith(color: c.textMuted),
              ),
            ),
            Expanded(
              child: SelectableText(value, style: AppType.mono),
            ),
          ],
        ),
      );
    });
  }
}

/// Eyebrow de sección con ícono para el sheet del histórico.
class _SeccionTituloHist extends StatelessWidget {
  final IconData icono;
  final String texto;
  final Color? color;
  const _SeccionTituloHist({
    required this.icono,
    required this.texto,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final col = color ?? context.colors.textSecondary;
    return Row(
      children: [
        Icon(icono, color: col, size: 16),
        const SizedBox(width: AppSpacing.sm),
        AppEyebrow(texto, color: col),
      ],
    );
  }
}

/// M11 — Mini-widget con los ✓/✓✓/✓✓-azul al estilo WhatsApp.
/// gris = solo enviado; gris con doble = entregado; brand con doble = leído.
class _AckIcon extends StatelessWidget {
  final DateTime? entregadoEn;
  final DateTime? leidoEn;
  const _AckIcon({this.entregadoEn, this.leidoEn});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (entregadoEn == null && leidoEn == null) {
      return Icon(Icons.check, size: 14, color: c.textMuted);
    }
    final color = leidoEn != null ? c.brand : c.textSecondary;
    return Icon(Icons.done_all, size: 14, color: color);
  }
}
