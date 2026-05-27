import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_colors.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Visor full-screen de archivos remotos (Firebase Storage), todo dentro de
/// la app (sin abrir otra app).
///
/// - **Imagen**: `Image.network` con `InteractiveViewer` (zoom).
/// - **PDF en móvil**: descarga el archivo COMPLETO (dio) y lo renderiza desde
///   bytes con `PdfViewer.data`. Antes usábamos `PdfViewer.uri`, que stremea /
///   cachea el PDF y FALLABA con archivos pesados en iOS — banner azul
///   `PdfException FPDF_GetLastError=3` (caso real: Formulario 931 de 18 MB que
///   el chofer no podía ver). Descargando los bytes completos nosotros, pdfium
///   recibe el PDF entero y lo abre bien, sin salir de la app. (2026-05-22)
/// - **PDF en web**: `PdfViewer.uri` (pdfrx maneja la web a su modo).
///
/// Fallback: si aún así un PDF no se puede renderizar in-app, hay un botón
/// "Abrir en el navegador" (siempre en la barra + en el cartel de error).
class PreviewScreen extends StatelessWidget {
  final String url;
  final String titulo;

  const PreviewScreen({
    super.key,
    required this.url,
    required this.titulo,
  });

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: _buildAppBar(context),
        body: _buildErrorPlaceholder('URL de documento no válida'),
      );
    }

    final urlSinParametros = url.split('?').first.toLowerCase();
    final esPdf = urlSinParametros.endsWith('.pdf');

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: _buildAppBar(context),
      backgroundColor: Colors.black,
      body: esPdf
          ? _PdfViewerRobusto(
              url: url,
              onAbrirExterno: () => _abrirExterno(context),
            )
          : _buildImageViewer(context),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      title: Text(
        titulo.toUpperCase(),
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
      centerTitle: true,
      backgroundColor: Colors.black.withAlpha(150),
      elevation: 0,
      foregroundColor: Colors.white,
      actions: [
        // Salida confiable: abrir el archivo en el navegador del sistema.
        // Queda como último recurso si el render in-app fallara.
        if (url.isNotEmpty)
          IconButton(
            tooltip: 'Abrir en el navegador',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _abrirExterno(context),
          ),
      ],
    );
  }

  /// Abre la URL en el navegador / visor externo del sistema (último recurso).
  Future<void> _abrirExterno(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.tryParse(url);
    if (uri == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('El documento tiene una dirección inválida.')),
      );
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(
          const SnackBar(content: Text('No se pudo abrir el documento.')),
        );
      }
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('No se pudo abrir el documento.')),
      );
    }
  }

  // ===========================================================================
  // VISOR DE IMÁGENES con zoom interactivo
  // ===========================================================================
  Widget _buildImageViewer(BuildContext context) {
    return InteractiveViewer(
      panEnabled: true,
      minScale: 0.5,
      maxScale: 5.0,
      child: Center(
        child: Image.network(
          url,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Center(
              child: CircularProgressIndicator(
                value: progress.expectedTotalBytes != null
                    ? progress.cumulativeBytesLoaded /
                        progress.expectedTotalBytes!
                    : null,
                color: Theme.of(context).colorScheme.primary,
                strokeWidth: 2,
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) =>
              _buildErrorPlaceholder('La imagen no está disponible'),
        ),
      ),
    );
  }

  Widget _buildErrorPlaceholder(String mensaje) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.broken_image_outlined,
            color: Colors.white24,
            size: 50,
          ),
          const SizedBox(height: 15),
          Text(
            mensaje,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 13,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// VISOR DE PDF ROBUSTO — descarga completa + render desde bytes (in-app)
// =============================================================================
class _PdfViewerRobusto extends StatefulWidget {
  final String url;
  final VoidCallback onAbrirExterno;

  const _PdfViewerRobusto({
    required this.url,
    required this.onAbrirExterno,
  });

  @override
  State<_PdfViewerRobusto> createState() => _PdfViewerRobustoState();
}

class _PdfViewerRobustoState extends State<_PdfViewerRobusto> {
  Future<Uint8List>? _descarga;
  double? _progreso; // 0..1 mientras baja; null = indeterminado

  @override
  void initState() {
    super.initState();
    // En web dejamos que pdfrx maneje la URI; en móvil descargamos nosotros.
    if (!kIsWeb) _descarga = _bajarPdf();
  }

  Future<Uint8List> _bajarPdf() async {
    final resp = await Dio().get<List<int>>(
      widget.url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(minutes: 3),
      ),
      onReceiveProgress: (recibido, total) {
        if (total > 0 && mounted) {
          setState(() => _progreso = recibido / total);
        }
      },
    );
    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('La descarga vino vacía.');
    }
    return Uint8List.fromList(bytes);
  }

  PdfViewerParams get _params => PdfViewerParams(
        maxScale: 8.0,
        backgroundColor: Colors.black,
        // Si pdfium no puede con el PDF, mostramos un cartel claro con salida
        // al navegador en vez del stack trace azul crudo de pdfrx.
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            _error(),
      );

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return PdfViewer.uri(Uri.parse(widget.url), params: _params);
    }
    return FutureBuilder<Uint8List>(
      future: _descarga,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _cargando();
        }
        if (snap.hasError || snap.data == null) {
          return _error();
        }
        return PdfViewer.data(
          snap.data!,
          sourceName: widget.url,
          params: _params,
        );
      },
    );
  }

  Widget _cargando() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CircularProgressIndicator(
              value: _progreso,
              color: AppColors.success,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            _progreso == null
                ? 'Cargando documento…'
                : 'Cargando documento… ${(_progreso! * 100).round()}%',
            style: const TextStyle(color: Colors.white60, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _error() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf_outlined,
                color: Colors.white38, size: 56),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'No se pudo mostrar el PDF acá.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: widget.onAbrirExterno,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.success,
                foregroundColor: Colors.black,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Abrir en el navegador'),
            ),
          ],
        ),
      ),
    );
  }
}
