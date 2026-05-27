// =============================================================================
// COMPONENTES VISUALES de la cola WhatsApp — extraídos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
// =============================================================================

part of 'admin_whatsapp_cola_screen.dart';

// =============================================================================
// RESUMEN COMPACTO ARRIBA
// =============================================================================

/// Mini-row con conteos por estado (PENDIENTE / PROCESANDO / ENVIADO /
/// ERROR). Lee del mismo stream que la lista, así que se actualiza
/// solo cuando el bot mueve docs entre estados.
///
/// Cada contador es clickeable y filtra la lista al estado tocado.
/// Tap al contador ya activo lo desactiva (toggle). Esto reemplaza la
/// versión solo-lectura anterior.
class _ResumenContador extends StatelessWidget {
  /// Estado activo (resaltado). Null = sin filtro, todos opacos.
  final String? filtroActivo;

  /// Callback con el código del estado tocado ('PENDIENTE', 'ERROR', ...).
  final void Function(String estado) onTapEstado;

  const _ResumenContador({
    required this.filtroActivo,
    required this.onTapEstado,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: WhatsAppColaService().streamCola(limit: 200),
      builder: (ctx, snap) {
        var pendientes = 0, procesando = 0, enviados = 0, errores = 0;
        if (snap.hasData) {
          for (final doc in snap.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            final estado = (data['estado'] ?? '').toString();
            if (estado == 'PENDIENTE') pendientes++;
            if (estado == 'PROCESANDO') procesando++;
            if (estado == 'ENVIADO') enviados++;
            if (estado == 'ERROR') errores++;
          }
        }
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Row(
            children: [
              _MiniContador(
                  label: 'Pendientes',
                  count: pendientes,
                  color: AppColors.warning,
                  activo: filtroActivo == 'PENDIENTE',
                  onTap: () => onTapEstado('PENDIENTE')),
              const SizedBox(width: 8),
              _MiniContador(
                  label: 'En envío',
                  count: procesando,
                  color: AppColors.accentBlue,
                  activo: filtroActivo == 'PROCESANDO',
                  onTap: () => onTapEstado('PROCESANDO')),
              const SizedBox(width: 8),
              _MiniContador(
                  label: 'Enviados',
                  count: enviados,
                  color: AppColors.success,
                  activo: filtroActivo == 'ENVIADO',
                  onTap: () => onTapEstado('ENVIADO')),
              const SizedBox(width: 8),
              _MiniContador(
                  label: 'Con error',
                  count: errores,
                  color: AppColors.error,
                  activo: filtroActivo == 'ERROR',
                  onTap: () => onTapEstado('ERROR')),
            ],
          ),
        );
      },
    );
  }
}

class _MiniContador extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool activo;
  final VoidCallback onTap;

  const _MiniContador({
    required this.label,
    required this.count,
    required this.color,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // El estado activo se distingue con fondo y borde más fuertes; los
    // inactivos quedan tenues para no distraer cuando se está mirando
    // un filtro puntual.
    final fondoAlpha = activo ? 60 : 15;
    final bordeAlpha = activo ? 200 : 60;
    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
            decoration: BoxDecoration(
              color: color.withAlpha(fondoAlpha),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: color.withAlpha(bordeAlpha),
                width: activo ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    '$count',
                    maxLines: 1,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: activo ? Colors.white : Colors.white60,
                    fontSize: 10,
                    fontWeight: activo ? FontWeight.bold : FontWeight.normal,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
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
  /// BottomSheet con el detalle completo. La firma es opcional para no
  /// romper otros usos del widget si los hubiera; cuando es null el
  /// item se comporta como antes (no clickeable).
  final VoidCallback? onTap;

  const _ItemCola({
    required this.doc,
    required this.onReintentar,
    required this.onEliminar,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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

    final card = AppCard(
      borderColor: _colorEstado(estado).withAlpha(esError ? 150 : 40),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _BadgeEstado(estado: estado),
              if (itemsAgrupados.isNotEmpty) ...[
                const SizedBox(width: 6),
                _BadgeAgrupado(cantidad: itemsAgrupados.length),
              ],
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  telefono,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (intentos > 1)
                Text(
                  'x$intentos',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            mensaje,
            style: const TextStyle(color: Colors.white70, fontSize: 12, height: 1.4),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.schedule, size: 11, color: Colors.white38),
              const SizedBox(width: 4),
              Text(
                _formatTs(encoladoTs, prefijo: 'Encolado'),
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
              if (enviadoTs != null) ...[
                const SizedBox(width: 12),
                const Icon(Icons.check, size: 11, color: AppColors.success),
                const SizedBox(width: 4),
                Text(
                  _formatTs(enviadoTs, prefijo: 'Enviado'),
                  style: const TextStyle(
                      color: AppColors.success, fontSize: 10),
                ),
              ],
            ],
          ),
          if (esError && error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.error.withAlpha(15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                error,
                style: const TextStyle(
                  color: AppColors.error,
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (esError || estado == 'PENDIENTE')
                TextButton.icon(
                  onPressed: onEliminar,
                  icon: const Icon(Icons.delete_outline,
                      color: Colors.white54, size: 16),
                  label: const Text(
                    'Eliminar',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              if (esError) ...[
                const SizedBox(width: 4),
                TextButton.icon(
                  onPressed: onReintentar,
                  icon: const Icon(Icons.refresh,
                      color: AppColors.success, size: 16),
                  label: const Text(
                    'Reintentar',
                    style: TextStyle(
                      color: AppColors.success,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );

    // Si hay onTap, hacemos el card clickeable. AppCard ya tiene su
    // propio padding/borde, asi que el InkWell va por afuera con el
    // mismo borderRadius para que el ripple se vea bien recortado.
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: card,
      ),
    );
  }

  static Color _colorEstado(String estado) {
    switch (estado) {
      case 'PENDIENTE':
        return AppColors.warning;
      case 'PROCESANDO':
        return AppColors.accentBlue;
      case 'ENVIADO':
        return AppColors.success;
      case 'ERROR':
        return AppColors.error;
      default:
        return Colors.white38;
    }
  }

  static String _formatTs(dynamic ts, {String prefijo = ''}) {
    if (ts is! Timestamp) return prefijo;
    final txt = AppFormatters.formatearFechaHoraCorta(ts.toDate());
    return prefijo.isEmpty ? txt : '$prefijo $txt';
  }
}

class _BadgeEstado extends StatelessWidget {
  final String estado;
  const _BadgeEstado({required this.estado});

  @override
  Widget build(BuildContext context) {
    final color = _ItemCola._colorEstado(estado);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        estado,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Pequeno chip que aparece junto al badge de estado cuando el item es
/// un mensaje agrupado (varios papeles del mismo chofer en uno solo).
/// Muestra el icono + cantidad de papeles incluidos.
class _BadgeAgrupado extends StatelessWidget {
  final int cantidad;
  const _BadgeAgrupado({required this.cantidad});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accentCyan.withAlpha(25),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.accentCyan.withAlpha(80)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.attach_file, size: 10, color: AppColors.accentCyan),
          const SizedBox(width: 3),
          Text(
            '${cantidad}x',
            style: const TextStyle(
              color: AppColors.accentCyan,
              fontSize: 9,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BOTTOM SHEET DE DETALLE
// =============================================================================

/// Sheet desplegable con TODA la info del doc de la cola: mensaje sin
/// truncar, lista de items_agrupados (cuando aplica), todos los
/// timestamps, origen, error completo, intentos, IDs de
/// destinatario/admin. Reemplaza al "tap inerte" anterior - ahora cada
/// item es la puerta de entrada al detalle.
///
/// Read-only por diseno: las acciones (eliminar / reintentar) siguen en
/// la card para evitar que el sheet crezca con responsabilidades.
class _DetalleColaSheet extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _DetalleColaSheet({required this.doc});

  @override
  Widget build(BuildContext context) {
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
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: Colors.white24,
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
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    telefono,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white54),
                  tooltip: 'Cerrar',
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (itemsAgrupados.isNotEmpty) ...[
              const _SeccionTitulo(
                  icono: Icons.list_alt, texto: 'Papeles incluidos'),
              const SizedBox(height: 6),
              ...itemsAgrupados.map((it) => _FilaItemAgrupado(item: it)),
              const SizedBox(height: 16),
            ],
            const _SeccionTitulo(
                icono: Icons.message_outlined, texto: 'Mensaje enviado'),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white12),
              ),
              child: SelectableText(
                mensaje,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const _SeccionTitulo(
                icono: Icons.access_time, texto: 'Linea de tiempo'),
            const SizedBox(height: 6),
            _FilaDato(
                label: 'Encolado',
                valor: _ItemCola._formatTs(encoladoTs)),
            _FilaDato(
                label: 'Enviado',
                valor: enviadoTs == null
                    ? 'Sin enviar'
                    : _ItemCola._formatTs(enviadoTs)),
            if (proximoTs != null)
              _FilaDato(
                  label: 'Proximo reintento',
                  valor: _ItemCola._formatTs(proximoTs)),
            _FilaDato(label: 'Intentos', valor: '$intentos'),
            const SizedBox(height: 16),
            const _SeccionTitulo(
                icono: Icons.info_outline, texto: 'Metadata'),
            const SizedBox(height: 6),
            _FilaDato(label: 'Origen', valor: origen.isEmpty ? '-' : origen),
            _FilaDato(
                label: 'Campo base', valor: campoBase.isEmpty ? '-' : campoBase),
            _FilaDato(
                label: 'Destinatario (DNI)',
                valor: destinatarioId.isEmpty ? '-' : destinatarioId),
            _FilaDato(
                label: 'Admin que encolo',
                valor: adminNombre.isEmpty
                    ? (adminDni.isEmpty ? '-' : adminDni)
                    : '$adminNombre ($adminDni)'),
            _FilaDato(label: 'ID del doc', valor: doc.id, copiable: true),
            if (error.isNotEmpty) ...[
              const SizedBox(height: 16),
              const _SeccionTitulo(
                  icono: Icons.error_outline,
                  texto: 'Error',
                  color: AppColors.error),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.error.withAlpha(15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.error.withAlpha(80)),
                ),
                child: SelectableText(
                  error,
                  style: const TextStyle(
                    color: AppColors.error,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
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
  final Color color;
  const _SeccionTitulo({
    required this.icono,
    required this.texto,
    this.color = AppColors.success,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icono, color: color, size: 16),
        const SizedBox(width: 8),
        Text(
          texto.toUpperCase(),
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: copiable
                ? SelectableText(
                    valor,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  )
                : Text(
                    valor,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
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
        colorDias = AppColors.error;
      } else if (d == 0) {
        estadoLegible = 'vence hoy';
        colorDias = AppColors.warning;
      } else {
        estadoLegible = 'vence en ${d}d';
        colorDias = d <= 7 ? AppColors.warning : AppColors.success;
      }
    } else {
      estadoLegible = '-';
      colorDias = Colors.white54;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tipoDoc,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (fecha.isNotEmpty)
                    Text(
                      'Vence: $fecha',
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 10),
                    ),
                ],
              ),
            ),
            Text(
              estadoLegible,
              style: TextStyle(
                color: colorDias,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
