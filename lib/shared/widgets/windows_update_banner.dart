import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/services/windows_update_service.dart';

/// Overlay para montar arriba del child de `MaterialApp.builder`. Muestra un
/// banner arriba cuando hay una actualización de Windows disponible. Sólo se
/// renderiza en Windows — en otras plataformas devuelve un widget vacío.
///
/// Recibe el [navigatorKey] del `MaterialApp` porque vive ARRIBA del Navigator
/// (en el builder), así que su `context` no tiene Navigator ancestro: necesita
/// ese key para que `showDialog`/`Navigator.of` tengan un context válido.
class WindowsUpdateOverlay extends StatelessWidget {
  const WindowsUpdateOverlay({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();
    return ValueListenableBuilder<WinUpdateInfo?>(
      valueListenable: WindowsUpdateService.instance.actualizacionDisponible,
      builder: (context, info, _) {
        if (info == null) return const SizedBox.shrink();
        return SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: _BannerActualizacion(
                  info: info,
                  navigatorKey: navigatorKey,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BannerActualizacion extends StatefulWidget {
  const _BannerActualizacion({required this.info, required this.navigatorKey});

  final WinUpdateInfo info;
  final GlobalKey<NavigatorState> navigatorKey;

  @override
  State<_BannerActualizacion> createState() => _BannerActualizacionState();
}

class _BannerActualizacionState extends State<_BannerActualizacion> {
  // Race-guard de UI: deshabilita los botones mientras se dispara la descarga
  // (el servicio tiene su propio guard; este es el visual).
  bool _descargando = false;

  @override
  Widget build(BuildContext context) {
    final tema = Theme.of(context);
    final onColor = tema.colorScheme.onPrimaryContainer;
    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(10),
      color: tema.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.system_update_alt, size: 18, color: onColor),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                'Actualización ${widget.info.version} · ${widget.info.sizeMb} MB',
                style: tema.textTheme.bodyMedium?.copyWith(
                  color: onColor,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
                foregroundColor: onColor,
              ),
              onPressed: _descargando
                  ? null
                  : () => WindowsUpdateService.instance.descartar(),
              child: const Text('Más tarde'),
            ),
            const SizedBox(width: 2),
            FilledButton(
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: const Size(0, 32),
              ),
              onPressed: _descargando ? null : _confirmarYDescargar,
              child: const Text('Actualizar'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarYDescargar() async {
    final navCtx = widget.navigatorKey.currentContext;
    if (navCtx == null) return;

    setState(() => _descargando = true);

    // Dialog de progreso ANTES de descargar; en éxito la app hace exit(0) y el
    // dialog "se cierra solo" porque el proceso muere. Si falla, lo cerramos.
    unawaited(showDialog<void>(
      context: navCtx,
      barrierDismissible: false,
      builder: (ctx) => const _DescargaDialog(),
    ));

    final resultado = await WindowsUpdateService.instance.descargarEInstalar(
      info: widget.info,
    );

    if (!mounted) return;
    setState(() => _descargando = false);

    // Si llegamos acá NO hubo exit(0): siempre es fallo o race-guard. Cerramos
    // el dialog de progreso y mostramos el detalle.
    final ctx = widget.navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    Navigator.of(ctx, rootNavigator: true).pop();
    if (resultado == WinUpdateResult.yaEnCurso) return; // silencioso
    await _mostrarError(ctx, resultado);
  }

  Future<void> _mostrarError(BuildContext ctx, WinUpdateResult resultado) async {
    final (titulo, mensaje) = _mensajeError(resultado);
    await showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => AlertDialog(
        title: Text(titulo),
        content: Text(mensaje),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('Cerrar'),
          ),
        ],
      ),
    );
  }

  (String, String) _mensajeError(WinUpdateResult resultado) {
    switch (resultado) {
      case WinUpdateResult.errorNoInstalado:
        return (
          'Versión de desarrollo',
          'Coopertrans Móvil se está ejecutando desde una carpeta de desarrollo, '
              'no desde la instalación. La actualización automática solo corre '
              'sobre la app instalada.',
        );
      case WinUpdateResult.errorDescarga:
        return (
          'No se pudo descargar',
          'Hubo un problema descargando la actualización. Verificá tu conexión '
              'a internet y reintentá.',
        );
      case WinUpdateResult.exito:
      case WinUpdateResult.yaEnCurso:
      case WinUpdateResult.errorOtro:
        return (
          'Error actualizando',
          'No se pudo completar la actualización. Reintentá más tarde, o cerrá '
              'y volvé a abrir Coopertrans Móvil desde el ícono del escritorio.',
        );
    }
  }
}

class _DescargaDialog extends StatelessWidget {
  const _DescargaDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Actualizando Coopertrans Móvil'),
      content: ValueListenableBuilder<double?>(
        valueListenable: WindowsUpdateService.instance.progresoDescarga,
        builder: (context, progreso, _) {
          final p = progreso ?? 0.0;
          final pct = (p * 100).round();
          final terminado = p >= 1.0;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                terminado
                    ? 'Reiniciando con la nueva versión...'
                    : 'Descargando $pct%...',
              ),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: p == 0.0 ? null : p),
            ],
          );
        },
      ),
    );
  }
}
