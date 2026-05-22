import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:url_launcher/url_launcher.dart';

import '../constants/app_colors.dart';

/// Visor full-screen de archivos remotos.
///
/// Detecta automáticamente el tipo de archivo:
/// - **PDF** (`.pdf`): usa `PdfViewer.uri` de pdfrx con navegación de páginas
/// - **Imagen**: usa `Image.network` con `InteractiveViewer` para hacer zoom
///
/// Las URLs vienen típicamente de Firebase Storage. Se ignoran query params
/// (como `?alt=media&token=...`) al detectar la extensión.
///
/// Salida externa (auditoría 2026-05-22): pdfrx (PDFium) falla al renderizar
/// algunos PDFs — típicamente los PESADOS — en iOS, mostrando un banner azul
/// con `PdfException: Failed to load PDF document (FPDF_GetLastError=3)`. Caso
/// real: el Formulario 931 (18 MB) que el chofer no podía ver en MIS
/// VENCIMIENTOS. Para esos casos ofrecemos abrir el PDF en el navegador del
/// sistema (Safari/Chrome), que sí lo renderiza: hay un botón "abrir afuera"
/// SIEMPRE visible en la barra + un banner de error propio con el mismo botón.
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
      body: esPdf ? _buildPdfViewer() : _buildImageViewer(context),
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
        // Imprescindible en iOS cuando pdfrx no puede con un PDF pesado.
        if (url.isNotEmpty)
          IconButton(
            tooltip: 'Abrir en el navegador',
            icon: const Icon(Icons.open_in_new),
            onPressed: () => _abrirExterno(context),
          ),
      ],
    );
  }

  /// Abre la URL en el navegador / visor externo del sistema. En iOS abre
  /// Safari, que descarga y muestra el PDF de Firebase Storage sin problemas
  /// (incluso los pesados que pdfium no puede renderizar in-app).
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
  // VISOR DE PDF
  //
  // Usamos los defaults de pdfrx para loading. Para el ERROR reemplazamos el
  // banner crudo de pdfrx (stack trace azul) por uno claro con botón "Abrir en
  // el navegador" — pdfium falla con PDFs pesados en iOS (FPDF_GetLastError=3).
  // ===========================================================================
  Widget _buildPdfViewer() {
    return PdfViewer.uri(
      Uri.parse(url),
      params: PdfViewerParams(
        maxScale: 8.0,
        backgroundColor: Colors.black,
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            _buildPdfError(context),
      ),
    );
  }

  Widget _buildPdfError(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.picture_as_pdf_outlined,
                color: Colors.white38, size: 56),
            const SizedBox(height: 16),
            const Text(
              'No se pudo mostrar el PDF acá.\n'
              'Puede ser un archivo muy pesado.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              onPressed: () => _abrirExterno(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accentGreen,
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
