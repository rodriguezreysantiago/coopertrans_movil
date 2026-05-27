import 'package:flutter/material.dart';
import '../constants/app_colors.dart';
import 'preview_screen.dart';

/// Thumbnail unificado para archivos almacenados en Firebase Storage.
/// Detecta automáticamente si es PDF o imagen, y al tocar abre [PreviewScreen].
///
/// Estados:
/// - **PDF**: cuadro rojo con ícono de PDF
/// - **Imagen**: miniatura real del archivo, con borde verde
/// - **Sin archivo**: cuadro gris con ícono de "archivo vacío" (no clickeable)
///
/// Uso:
/// ```
/// AppFileThumbnail(
///   url: data['ARCHIVO_RTO'],
///   tituloVisor: 'RTO $patente',
///   size: 36,
/// );
/// ```
class AppFileThumbnail extends StatelessWidget {
  final String? url;
  final String tituloVisor;
  final double size;

  const AppFileThumbnail({
    super.key,
    required this.url,
    required this.tituloVisor,
    this.size = 36,
  });

  /// Detecta si la URL apunta a un PDF (ignorando query params de Firebase).
  bool get _esPdf {
    if (url == null || url!.isEmpty) return false;
    return url!.split('?').first.toLowerCase().endsWith('.pdf');
  }

  bool get _tieneArchivo =>
      url != null && url!.isNotEmpty && url != '-';

  @override
  Widget build(BuildContext context) {
    if (!_tieneArchivo) return _buildSinArchivo();

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _abrirVisor(context),
        child: _esPdf ? _buildPdf() : _buildImagen(),
      ),
    );
  }

  void _abrirVisor(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(url: url!, titulo: tituloVisor),
      ),
    );
  }

  Widget _buildSinArchivo() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Icon(
        Icons.insert_drive_file_outlined,
        color: Colors.white24,
        size: size * 0.5,
      ),
    );
  }

  Widget _buildPdf() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: AppColors.error.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withAlpha(80)),
      ),
      child: Icon(
        Icons.picture_as_pdf,
        color: AppColors.error,
        size: size * 0.55,
      ),
    );
  }

  Widget _buildImagen() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.success.withAlpha(80)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Image.network(
        url!,
        fit: BoxFit.cover,
        loadingBuilder: (ctx, child, progress) {
          if (progress == null) return child;
          return Container(
            color: Colors.white10,
            child: Center(
              child: SizedBox(
                width: size * 0.4,
                height: size * 0.4,
                child: const CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.success,
                ),
              ),
            ),
          );
        },
        errorBuilder: (_, __, ___) => Container(
          color: Colors.white10,
          child: Icon(
            Icons.broken_image,
            color: Colors.white24,
            size: size * 0.5,
          ),
        ),
      ),
    );
  }
}
