// Pantalla admin: ABM de los documentos laborales que viven a nivel
// EMPRESA empleadora (Póliza ART, Formulario 931, SCVO, Libre Deuda
// Sindical). Una tarjeta por empresa del catálogo
// (`AppEmpresasEmpleadoras.catalogo`); cada tarjeta tiene una fila
// editable por documento — fecha + archivo PDF.
//
// Si el doc no existe todavía en Firestore, las filas muestran "—"
// (sin fecha / sin archivo) — al primer save se crea con
// `set(merge: true)` (ver `EmpresaEmpleadoraService`).
//
// REFACTOR NÚCLEO · jun 2026 — solo el árbol de widgets. Datos
// (StreamBuilder por CUIT), `EmpresaEmpleadoraService`, edición de
// fecha (`pickFecha`), subida/reemplazo de archivo (ImagePicker /
// FilePicker) y navegación quedaron INTACTOS.

import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import '../services/empresa_empleadora_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class AdminEmpresasEmpleadorasScreen extends StatelessWidget {
  const AdminEmpresasEmpleadorasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    const empresas = AppEmpresasEmpleadoras.catalogo;
    return AppScaffold(
      title: 'Empresas y seguros',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxl),
        children: [
          const _Intro(),
          const SizedBox(height: AppSpacing.lg),
          for (final e in empresas) ...[
            _CardEmpresa(info: e),
            const SizedBox(height: AppSpacing.mdDense),
          ],
        ],
      ),
    );
  }
}

/// Aviso de encabezado — explica qué se carga acá y que es por empresa,
/// una sola vez. Estilo Núcleo: superficie surface1 con eyebrow + body.
class _Intro extends StatelessWidget {
  const _Intro();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: c.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Una sola carga por empresa'),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Acá cargás la Póliza ART, el Formulario 931, el SCVO y '
                  'el Libre Deuda Sindical de cada empresa empleadora UNA '
                  'SOLA VEZ. Todos los empleados de esa empresa los ven en '
                  'su MIS VENCIMIENTOS sin poder editar.',
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta de una empresa: header (avatar + razón social + CUIT mono) +
/// las 4 filas de documentos a nivel empresa, separadas por hairlines.
class _CardEmpresa extends StatelessWidget {
  final EmpresaEmpleadoraInfo info;

  const _CardEmpresa({required this.info});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: EmpresaEmpleadoraService.stream(info.cuit),
        builder: (ctx, snap) {
          final data = snap.data?.data() ?? const <String, dynamic>{};
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header de la empresa.
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: c.surface3,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: Icon(Icons.business_outlined,
                        color: c.brand, size: 18),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          info.nombre.toUpperCase(),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.h5.copyWith(color: c.text),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'CUIT ${info.cuit}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.monoSm.copyWith(color: c.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              AppHairline(color: c.border),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaPolizaArt,
                campoFecha: AppDocsEmpresa.campoFechaPolizaArt,
                campoUrl: AppDocsEmpresa.campoArchivoPolizaArt,
                data: data,
              ),
              AppHairline(color: c.border),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaForm931,
                campoFecha: AppDocsEmpresa.campoFechaForm931,
                campoUrl: AppDocsEmpresa.campoArchivoForm931,
                data: data,
              ),
              AppHairline(color: c.border),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaScvoAdmin,
                campoFecha: AppDocsEmpresa.campoFechaScvo,
                campoUrl: AppDocsEmpresa.campoArchivoScvo,
                data: data,
              ),
              AppHairline(color: c.border),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaLibreDeudaSindical,
                campoFecha: AppDocsEmpresa.campoFechaLibreDeudaSindical,
                campoUrl: AppDocsEmpresa.campoArchivoLibreDeudaSindical,
                data: data,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Fila editable: thumbnail + etiqueta + fecha (mono) + badge + chevron.
/// Tap abre un sheet con "editar fecha", "ver archivo", "subir/reemplazar".
class _FilaDocEmpresa extends StatelessWidget {
  final String cuit;
  final String etiqueta;
  final String campoFecha;
  final String campoUrl;
  final Map<String, dynamic> data;

  const _FilaDocEmpresa({
    required this.cuit,
    required this.etiqueta,
    required this.campoFecha,
    required this.campoUrl,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fecha = data[campoFecha];
    final url = data[campoUrl]?.toString();
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _abrirSheet(context,
            urlActual: url, fechaActual: fecha?.toString()),
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
          child: Row(
            children: [
              AppFileThumbnail(
                url: url,
                tituloVisor: '$etiqueta - $cuit',
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      etiqueta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodyLg
                          .copyWith(color: c.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Row(
                      children: [
                        Text('Vence  ',
                            style:
                                AppType.bodySm.copyWith(color: c.textMuted)),
                        Flexible(
                          child: Text(
                            tieneFecha
                                ? AppFormatters.formatearFecha(fecha)
                                : '—',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                AppType.monoSm.copyWith(color: c.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              VencimientoBadge(fecha: fecha),
              const SizedBox(width: AppSpacing.sm),
              Icon(Icons.chevron_right, color: c.textMuted, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // SHEET de acciones (editar fecha / ver archivo / subir o reemplazar)
  // ---------------------------------------------------------------------------

  void _abrirSheet(
    BuildContext context, {
    required String? urlActual,
    required String? fechaActual,
  }) {
    final c = context.colors;
    final tieneArchivo =
        urlActual != null && urlActual.isNotEmpty && urlActual != '-';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xl),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
          border: Border.all(color: c.border),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.border,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              const AppEyebrow('Documento de empresa'),
              const SizedBox(height: AppSpacing.xs),
              Text(
                etiqueta,
                style: AppType.h5.copyWith(color: c.text),
              ),
              const SizedBox(height: AppSpacing.md),
              _AccionSheet(
                icono: Icons.event_note_outlined,
                titulo: 'Editar fecha de vencimiento',
                color: c.brand,
                onTap: () {
                  Navigator.pop(bCtx);
                  _editarFecha(context, fechaActual);
                },
              ),
              _AccionSheet(
                icono: Icons.visibility_outlined,
                titulo: 'Ver documento digital',
                color: tieneArchivo ? c.success : c.textMuted,
                enabled: tieneArchivo,
                onTap: () {
                  Navigator.pop(bCtx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PreviewScreen(
                        url: urlActual!,
                        titulo: '$etiqueta - $cuit',
                      ),
                    ),
                  );
                },
              ),
              _AccionSheet(
                icono: Icons.upload_file_outlined,
                titulo: tieneArchivo
                    ? 'Reemplazar archivo cargado'
                    : 'Subir archivo nuevo',
                subtitulo: 'Foto o PDF — el cambio se ve para todos los '
                    'empleados de esta empresa.',
                color: c.warning,
                onTap: () {
                  Navigator.pop(bCtx);
                  _subirArchivo(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editarFecha(
      BuildContext context, String? fechaActualIso) async {
    final initial = AppFormatters.tryParseFecha(fechaActualIso ?? '');
    final picked = await pickFecha(
      context,
      initial: initial,
      titulo: 'Vencimiento $etiqueta',
    );
    if (picked == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final iso = AppFormatters.aIsoFechaLocal(picked);
    try {
      await EmpresaEmpleadoraService.actualizarFecha(
        cuit: cuit,
        campoFecha: campoFecha,
        fechaIso: iso,
        actualizadoPorDni: PrefsService.dni,
      );
      AppFeedback.successOn(messenger, 'Fecha actualizada.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo guardar la fecha.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Future<void> _subirArchivo(BuildContext context) async {
    final c = context.colors;
    final fuente = await showModalBottomSheet<_Fuente>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sCtx) => Container(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.xl),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
          border: Border.all(color: c.border),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: c.border,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppEyebrow(etiqueta),
              const SizedBox(height: AppSpacing.md),
              _AccionSheet(
                icono: Icons.camera_alt_outlined,
                titulo: 'Tomar foto con la cámara',
                color: c.brand,
                onTap: () => Navigator.pop(sCtx, _Fuente.camara),
              ),
              _AccionSheet(
                icono: Icons.photo_library_outlined,
                titulo: 'Foto desde la galería',
                color: c.info,
                onTap: () => Navigator.pop(sCtx, _Fuente.galeria),
              ),
              _AccionSheet(
                icono: Icons.picture_as_pdf_outlined,
                titulo: 'PDF / archivo del dispositivo',
                color: c.error,
                onTap: () => Navigator.pop(sCtx, _Fuente.archivo),
              ),
            ],
          ),
        ),
      ),
    );

    if (fuente == null) return;
    if (!context.mounted) return;

    Uint8List? bytes;
    String nombreOriginal = '';
    String extension = 'jpg';

    switch (fuente) {
      case _Fuente.camara:
      case _Fuente.galeria:
        final source = fuente == _Fuente.camara
            ? ImageSource.camera
            : ImageSource.gallery;
        final img =
            await ImagePicker().pickImage(source: source, imageQuality: 60);
        if (img == null) return;
        bytes = await img.readAsBytes();
        nombreOriginal = img.name;
        extension = 'jpg';
        break;
      case _Fuente.archivo:
        final res = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
          withData: true,
        );
        final picked = res?.files.singleOrNull;
        if (picked == null || picked.bytes == null) return;
        bytes = picked.bytes;
        nombreOriginal = picked.name;
        extension = picked.extension?.toLowerCase() ?? 'pdf';
        break;
    }

    if (!context.mounted) return;
    if (bytes == null) return;

    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    AppLoadingDialog.show(context);
    try {
      await EmpresaEmpleadoraService.subirArchivo(
        cuit: cuit,
        campoUrl: campoUrl,
        bytes: bytes,
        nombreOriginal: nombreOriginal,
        extension: extension,
        actualizadoPorDni: PrefsService.dni,
      );
      AppLoadingDialog.hide(navigator);
      AppFeedback.successOn(messenger, 'Archivo cargado.');
    } catch (e, s) {
      AppLoadingDialog.hide(navigator);
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo subir el archivo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

/// Fila de acción dentro de un bottom sheet (ícono en cápsula + título +
/// subtítulo opcional). Estilo Núcleo — reemplaza al ListTile Material.
class _AccionSheet extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String? subtitulo;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const _AccionSheet({
    required this.icono,
    required this.titulo,
    required this.color,
    required this.onTap,
    this.subtitulo,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Opacity(
          opacity: enabled ? 1 : 0.4,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(icono, color: color, size: 18),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        titulo,
                        style: AppType.body.copyWith(
                            color: c.text, fontWeight: FontWeight.w600),
                      ),
                      if (subtitulo != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitulo!,
                          style:
                              AppType.bodySm.copyWith(color: c.textMuted),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

enum _Fuente { camara, galeria, archivo }
