// Pantalla admin: ABM de los documentos laborales que viven a nivel
// EMPRESA empleadora (Póliza ART + Formulario 931). Una tarjeta por
// empresa del catálogo (`AppEmpresasEmpleadoras.catalogo`); cada
// tarjeta tiene 2 filas editables — fecha + archivo PDF.
//
// Si el doc no existe todavía en Firestore, las filas muestran "Sin
// fecha"/"Sin archivo" — al primer save se crea con `set(merge: true)`
// (ver `EmpresaEmpleadoraService`).
//
// Diseño paralelo a la sección "Seguros y aportes" del form admin de
// empleado, pero sobre EMPRESAS_EMPLEADORAS — para que el admin no
// tenga que aprender una UX distinta.

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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              'Acá cargás la Póliza ART y el Formulario 931 de cada '
              'empresa empleadora UNA SOLA VEZ. Todos los empleados '
              'que figuran en esa empresa los ven en su MIS '
              'VENCIMIENTOS sin poder editar.',
              style: AppType.label.copyWith(color: Colors.white60),
            ),
          ),
          for (final e in empresas) _CardEmpresa(info: e),
          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

class _CardEmpresa extends StatelessWidget {
  final EmpresaEmpleadoraInfo info;

  const _CardEmpresa({required this.info});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: EmpresaEmpleadoraService.stream(info.cuit),
        builder: (ctx, snap) {
          final data = snap.data?.data() ?? const <String, dynamic>{};
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppColors.info.withAlpha(35),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.business,
                        color: AppColors.info, size: 20),
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
                          style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.bold, letterSpacing: 0.4),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'CUIT ${info.cuit}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.eyebrow.copyWith(color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const Divider(color: Colors.white10, height: 24),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaPolizaArt,
                campoFecha: AppDocsEmpresa.campoFechaPolizaArt,
                campoUrl: AppDocsEmpresa.campoArchivoPolizaArt,
                data: data,
              ),
              const Divider(color: Colors.white10, height: 8),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaForm931,
                campoFecha: AppDocsEmpresa.campoFechaForm931,
                campoUrl: AppDocsEmpresa.campoArchivoForm931,
                data: data,
              ),
              const Divider(color: Colors.white10, height: 8),
              _FilaDocEmpresa(
                cuit: info.cuit,
                etiqueta: AppDocsEmpresa.etiquetaScvoAdmin,
                campoFecha: AppDocsEmpresa.campoFechaScvo,
                campoUrl: AppDocsEmpresa.campoArchivoScvo,
                data: data,
              ),
              const Divider(color: Colors.white10, height: 8),
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

/// Fila editable: thumbnail + etiqueta + fecha + badge + chevron. Tap
/// abre un sheet con "editar fecha", "ver archivo", "subir/reemplazar".
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
    final fecha = data[campoFecha];
    final url = data[campoUrl]?.toString();
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;

    return InkWell(
      onTap: () => _abrirSheet(context, urlActual: url, fechaActual: fecha?.toString()),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
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
                    style:
                        AppType.eyebrow.copyWith(color: Colors.white54),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tieneFecha
                        ? AppFormatters.formatearFecha(fecha)
                        : 'Sin fecha',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            VencimientoBadge(fecha: fecha),
            const SizedBox(width: AppSpacing.xs),
            const Icon(Icons.chevron_right,
                color: Colors.white24, size: 18),
          ],
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
    final tieneArchivo =
        urlActual != null && urlActual.isNotEmpty && urlActual != '-';
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (bCtx) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              etiqueta,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 15),
            ListTile(
              leading: const Icon(Icons.event_note,
                  color: AppColors.info),
              title: const Text('Editar fecha de vencimiento',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(bCtx);
                _editarFecha(context, fechaActual);
              },
            ),
            ListTile(
              leading: const Icon(Icons.visibility,
                  color: AppColors.success),
              title: const Text('Ver documento digital',
                  style: TextStyle(color: Colors.white)),
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
            ListTile(
              leading: const Icon(Icons.upload_file,
                  color: AppColors.warning),
              title: Text(
                tieneArchivo
                    ? 'Reemplazar archivo cargado'
                    : 'Subir archivo nuevo',
                style: const TextStyle(color: Colors.white),
              ),
              subtitle: Text(
                'Foto o PDF — el cambio se ve para todos los empleados '
                'de esta empresa.',
                style: AppType.eyebrow.copyWith(color: Colors.white38),
              ),
              onTap: () {
                Navigator.pop(bCtx);
                _subirArchivo(context);
              },
            ),
          ],
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
    final fuente = await showModalBottomSheet<_Fuente>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sCtx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(sCtx).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.success, width: 2)),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  etiqueta.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.camera_alt,
                    color: AppColors.success),
                title: const Text('Tomar foto con la cámara',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(sCtx, _Fuente.camara),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library,
                    color: AppColors.info),
                title: const Text('Foto desde la galería',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(sCtx, _Fuente.galeria),
              ),
              ListTile(
                leading: const Icon(Icons.picture_as_pdf,
                    color: AppColors.error),
                title: const Text('PDF / archivo del dispositivo',
                    style: TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(sCtx, _Fuente.archivo),
              ),
              const SizedBox(height: 20),
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

enum _Fuente { camara, galeria, archivo }
