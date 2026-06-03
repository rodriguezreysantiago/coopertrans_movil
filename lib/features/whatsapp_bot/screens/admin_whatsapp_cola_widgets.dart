// =============================================================================
// COMPONENTES VISUALES de la cola WhatsApp — extraídos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
// REFACTOR NÚCLEO (jun 2026): tokens, AppKpiStrip, AppBadge, AppFilterChip,
// mono tabular para teléfonos/timestamps/IDs.
// =============================================================================

part of 'admin_whatsapp_cola_screen.dart';

// =============================================================================
// ENCABEZADO — eyebrow + hero (pendientes) + AppKpiStrip + chips de filtro
// =============================================================================

/// Bloque superior de la cola: título Núcleo + KPIs por estado +
/// chips de filtro. Lee su propio stream (limit 200) para que el
/// panorama sea estable e independiente del filtro activo del listado.
///
/// Cada chip filtra la lista al estado tocado; tap al chip ya activo lo
/// desactiva (toggle). Esto preserva el comportamiento de la versión
/// solo-lectura + filtro anterior.
class _Encabezado extends StatelessWidget {
  /// Estado activo (resaltado). Null = sin filtro.
  final String? filtroActivo;

  /// Callback con el código del estado tocado ('PENDIENTE', 'ERROR', ...).
  final void Function(String estado) onTapEstado;

  const _Encabezado({
    required this.filtroActivo,
    required this.onTapEstado,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot>(
      stream: WhatsAppColaService().streamCola(limit: 200),
      builder: (ctx, snap) {
        var pendientes = 0, procesando = 0, enviados = 0, errores = 0;
        final tieneDatos = snap.hasData;
        if (tieneDatos) {
          for (final doc in snap.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final estado = (data['estado'] ?? '').toString();
            if (estado == 'PENDIENTE') pendientes++;
            if (estado == 'PROCESANDO') procesando++;
            if (estado == 'ENVIADO') enviados++;
            if (estado == 'ERROR') errores++;
          }
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Hero: COLA · pendientes.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppEyebrow('Cola de WhatsApp'),
                      const SizedBox(height: 6),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            tieneDatos ? '$pendientes' : '—',
                            style: AppType.h2.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              'pendientes',
                              style: AppType.monoSm
                                  .copyWith(color: c.textMuted),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // KPI strip por estado (panorama estable sobre los 200).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
              child: AppKpiStrip(
                stats: [
                  AppStat(
                    label: 'Pendientes',
                    value: tieneDatos ? '$pendientes' : '—',
                    accent: c.warning,
                  ),
                  AppStat(
                    label: 'En envío',
                    value: tieneDatos ? '$procesando' : '—',
                    accent: c.info,
                  ),
                  AppStat(
                    label: 'Enviados',
                    value: tieneDatos ? '$enviados' : '—',
                    accent: c.success,
                  ),
                  AppStat(
                    label: 'Con error',
                    value: tieneDatos ? '$errores' : '—',
                    accent: c.error,
                  ),
                ],
              ),
            ),
            // Chips de filtro (toggle por estado).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ChipEstado(
                    label: 'Pendientes',
                    count: pendientes,
                    color: c.warning,
                    activo: filtroActivo == 'PENDIENTE',
                    onTap: () => onTapEstado('PENDIENTE'),
                  ),
                  _ChipEstado(
                    label: 'En envío',
                    count: procesando,
                    color: c.info,
                    activo: filtroActivo == 'PROCESANDO',
                    onTap: () => onTapEstado('PROCESANDO'),
                  ),
                  _ChipEstado(
                    label: 'Enviados',
                    count: enviados,
                    color: c.success,
                    activo: filtroActivo == 'ENVIADO',
                    onTap: () => onTapEstado('ENVIADO'),
                  ),
                  _ChipEstado(
                    label: 'Con error',
                    count: errores,
                    color: c.error,
                    activo: filtroActivo == 'ERROR',
                    onTap: () => onTapEstado('ERROR'),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Pill de filtro por estado, estilo Núcleo. Inactivo: transparente con
/// borde. Activo: tinte del color semántico del estado + borde del mismo.
/// El contador va en mono tabular.
class _ChipEstado extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool activo;
  final VoidCallback onTap;

  const _ChipEstado({
    required this.label,
    required this.count,
    required this.color,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = activo ? color : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? color.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: activo ? color.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: AppType.label.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$count',
              style: AppType.monoSm.copyWith(
                color: activo ? color : c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// ITEM DE LA LISTA
// =============================================================================

class _ItemCola extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final VoidCallback onReintentar;
  final VoidCallback onEliminar;

  /// Tap general en el item (afuera de los botones inferiores) abre el
  /// BottomSheet con el detalle completo.
  final VoidCallback? onTap;

  const _ItemCola({
    required this.doc,
    required this.onReintentar,
    required this.onEliminar,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final estado = (data['estado'] ?? 'PENDIENTE').toString();
    // Mostramos el teléfono en formato local (sin prefijo 549).
    // El doc en Firestore lo guarda completo porque el bot lo necesita
    // así para WhatsApp Web.
    final telefono = PhoneFormatter.paraMostrar(data['telefono']?.toString());
    final mensaje = (data['mensaje'] ?? '').toString();
    final encoladoTs = data['encolado_en'];
    final enviadoTs = data['enviado_en'];
    final error = (data['error'] ?? '').toString();
    final intentos = (data['intentos'] ?? 0) as int;
    // items_agrupados está poblado solo cuando el cron juntó varios
    // papeles del mismo chofer en un único mensaje (origen
    // 'cron_aviso_agrupado'). Ver whatsapp-bot/src/cron.js.
    final itemsAgrupados =
        (data['items_agrupados'] as List<dynamic>?) ?? const [];

    final esError = estado == 'ERROR';
    final estadoColor = _colorEstado(context, estado);

    return AppCard(
      tier: 1,
      accent: estadoColor,
      onTap: onTap,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: badge estado + (agrupado) + teléfono + intentos.
          Row(
            children: [
              _BadgeEstado(estado: estado),
              if (itemsAgrupados.isNotEmpty) ...[
                const SizedBox(width: 6),
                _BadgeAgrupado(cantidad: itemsAgrupados.length),
              ],
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  telefono,
                  style: AppType.mono.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (intentos > 1)
                Text(
                  'x$intentos',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            mensaje,
            style: AppType.bodySm.copyWith(color: c.textSecondary),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          // Timeline compacta: encolado + (enviado).
          Row(
            children: [
              Icon(Icons.schedule, size: 13, color: c.textMuted),
              const SizedBox(width: AppSpacing.xs),
              Flexible(
                child: Text(
                  _formatTs(encoladoTs, prefijo: 'Encolado'),
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (enviadoTs != null) ...[
                const SizedBox(width: AppSpacing.md),
                Icon(Icons.check, size: 13, color: c.success),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    _formatTs(enviadoTs, prefijo: 'Enviado'),
                    style: AppType.monoSm.copyWith(color: c.success),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          if (esError && error.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: c.errorSoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Text(
                error,
                style: AppType.monoSm.copyWith(color: c.error),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          // Acciones (solo cuando hay algo que hacer).
          if (esError || estado == 'PENDIENTE') ...[
            const SizedBox(height: AppSpacing.md),
            const AppHairline(),
            const SizedBox(height: AppSpacing.md),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton.ghost(
                  label: 'Eliminar',
                  icon: Icons.delete_outline,
                  size: AppButtonSize.sm,
                  onPressed: onEliminar,
                ),
                if (esError) ...[
                  const SizedBox(width: AppSpacing.sm),
                  AppButton.secondary(
                    label: 'Reintentar',
                    icon: Icons.refresh,
                    size: AppButtonSize.sm,
                    onPressed: onReintentar,
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Color semántico por estado, resuelto contra el theme activo.
  static Color _colorEstado(BuildContext context, String estado) {
    final c = context.colors;
    switch (estado) {
      case 'PENDIENTE':
        return c.warning;
      case 'PROCESANDO':
        return c.info;
      case 'ENVIADO':
        return c.success;
      case 'ERROR':
        return c.error;
      default:
        return c.textMuted;
    }
  }

  static String _formatTs(dynamic ts, {String prefijo = ''}) {
    if (ts is! Timestamp) return prefijo.isEmpty ? '—' : prefijo;
    final txt = AppFormatters.formatearFechaHoraCorta(ts.toDate());
    return prefijo.isEmpty ? txt : '$prefijo $txt';
  }
}

class _BadgeEstado extends StatelessWidget {
  final String estado;
  const _BadgeEstado({required this.estado});

  @override
  Widget build(BuildContext context) {
    return AppBadge(
      text: estado,
      color: _ItemCola._colorEstado(context, estado),
      size: AppBadgeSize.sm,
      dot: true,
    );
  }
}

/// Pequeño chip que aparece junto al badge de estado cuando el item es
/// un mensaje agrupado (varios papeles del mismo chofer en uno solo).
/// Muestra el icono + cantidad de papeles incluidos.
class _BadgeAgrupado extends StatelessWidget {
  final int cantidad;
  const _BadgeAgrupado({required this.cantidad});

  @override
  Widget build(BuildContext context) {
    return AppBadge(
      text: '${cantidad}x',
      color: context.colors.brand,
      size: AppBadgeSize.sm,
      icon: Icons.attach_file,
    );
  }
}

// =============================================================================
// BOTTOM SHEET DE DETALLE
// =============================================================================

/// Sheet desplegable con TODA la info del doc de la cola: mensaje sin
/// truncar, lista de items_agrupados (cuando aplica), todos los
/// timestamps, origen, error completo, intentos, IDs de
/// destinatario/admin.
///
/// Read-only por diseño: las acciones (eliminar / reintentar) siguen en
/// la card para evitar que el sheet crezca con responsabilidades.
class _DetalleColaSheet extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _DetalleColaSheet({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final estado = (data['estado'] ?? '').toString();
    final telefono = PhoneFormatter.paraMostrar(data['telefono']?.toString());
    final mensaje = (data['mensaje'] ?? '').toString();
    final origen = (data['origen'] ?? '').toString();
    final error = (data['error'] ?? '').toString();
    final intentos = (data['intentos'] ?? 0) as int;
    final adminDni = (data['admin_dni'] ?? '').toString();
    final adminNombre = (data['admin_nombre'] ?? '').toString();
    final destinatarioId = (data['destinatario_id'] ?? '').toString();
    final campoBase = (data['campo_base'] ?? '').toString();
    final itemsAgrupados =
        (data['items_agrupados'] as List<dynamic>?) ?? const [];
    final encoladoTs = data['encolado_en'];
    final enviadoTs = data['enviado_en'];
    final proximoTs = data['proximoIntentoEn'];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
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
                _BadgeEstado(estado: estado),
                if (itemsAgrupados.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  _BadgeAgrupado(cantidad: itemsAgrupados.length),
                ],
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    telefono,
                    style: AppType.mono.copyWith(
                        fontSize: 16, fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, size: 18, color: c.textMuted),
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (itemsAgrupados.isNotEmpty) ...[
              const _SeccionTitulo(
                  icono: Icons.list_alt, texto: 'Papeles incluidos'),
              const SizedBox(height: 6),
              ...itemsAgrupados.map((it) => _FilaItemAgrupado(item: it)),
              const SizedBox(height: AppSpacing.lg),
            ],
            const _SeccionTitulo(
                icono: Icons.message_outlined, texto: 'Mensaje enviado'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: c.border),
              ),
              child: SelectableText(
                mensaje,
                style: AppType.body,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const _SeccionTitulo(
                icono: Icons.access_time, texto: 'Línea de tiempo'),
            const SizedBox(height: 6),
            _FilaDato(
                label: 'Encolado', valor: _ItemCola._formatTs(encoladoTs)),
            _FilaDato(
                label: 'Enviado',
                valor: enviadoTs == null
                    ? 'Sin enviar'
                    : _ItemCola._formatTs(enviadoTs)),
            if (proximoTs != null)
              _FilaDato(
                  label: 'Próximo reintento',
                  valor: _ItemCola._formatTs(proximoTs)),
            _FilaDato(label: 'Intentos', valor: '$intentos'),
            const SizedBox(height: AppSpacing.lg),
            const _SeccionTitulo(icono: Icons.info_outline, texto: 'Metadata'),
            const SizedBox(height: 6),
            _FilaDato(label: 'Origen', valor: origen.isEmpty ? '—' : origen),
            _FilaDato(
                label: 'Campo base',
                valor: campoBase.isEmpty ? '—' : campoBase),
            _FilaDato(
                label: 'Destinatario (DNI)',
                valor: destinatarioId.isEmpty ? '—' : destinatarioId),
            _FilaDato(
                label: 'Admin que encoló',
                valor: adminNombre.isEmpty
                    ? (adminDni.isEmpty ? '—' : adminDni)
                    : '$adminNombre ($adminDni)'),
            _FilaDato(label: 'ID del doc', valor: doc.id, copiable: true),
            if (error.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.lg),
              _SeccionTitulo(
                  icono: Icons.error_outline,
                  texto: 'Error',
                  color: c.error),
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
          ],
        ),
      ),
    );
  }
}

class _SeccionTitulo extends StatelessWidget {
  final IconData icono;
  final String texto;
  final Color? color;
  const _SeccionTitulo({
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

class _FilaDato extends StatelessWidget {
  final String label;
  final String valor;

  /// Si true, el valor se renderiza como SelectableText para que el
  /// admin pueda copiar (util para IDs de doc, DNIs largos, etc).
  final bool copiable;

  const _FilaDato({
    required this.label,
    required this.valor,
    this.copiable = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: AppType.label.copyWith(color: c.textMuted),
            ),
          ),
          Expanded(
            child: copiable
                ? SelectableText(
                    valor,
                    style: AppType.mono,
                  )
                : Text(
                    valor,
                    style: AppType.mono,
                  ),
          ),
        ],
      ),
    );
  }
}

class _FilaItemAgrupado extends StatelessWidget {
  final dynamic item;
  const _FilaItemAgrupado({required this.item});

  @override
  Widget build(BuildContext context) {
    if (item is! Map) return const SizedBox.shrink();
    final c = context.colors;
    final m = item;
    final tipoDoc = (m['tipoDoc'] ?? m['campoBase'] ?? '').toString();
    final fecha = (m['fecha'] ?? '').toString();
    final dias = m['dias'];
    String estadoLegible;
    Color colorDias;
    if (dias is num) {
      final d = dias.toInt();
      if (d < 0) {
        estadoLegible = 'vencido hace ${d.abs()}d';
        colorDias = c.error;
      } else if (d == 0) {
        estadoLegible = 'vence hoy';
        colorDias = c.warning;
      } else {
        estadoLegible = 'vence en ${d}d';
        colorDias = d <= 7 ? c.warning : c.success;
      }
    } else {
      estadoLegible = '—';
      colorDias = c.textMuted;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tipoDoc.isEmpty ? '—' : tipoDoc,
                    style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (fecha.isNotEmpty)
                    Text(
                      'Vence: $fecha',
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              estadoLegible,
              style: AppType.monoSm.copyWith(
                  color: colorDias, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
