import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import 'vencimiento_item.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Bottom sheet para editar un vencimiento puntual.
///
/// Permite al admin:
/// - Cambiar la fecha de vencimiento
/// - Adjuntar un archivo nuevo (jpg/png/pdf)
/// - Guardar los cambios → actualiza Firestore + sube a Storage
///
/// Reusable entre choferes / chasis / acoplados (toda la lógica de subida y
/// actualización está acá, antes estaba duplicada 3 veces).
///
/// **Nota histórica (2026-04-30):** este sheet tenía además un botón
/// "AVISAR POR WHATSAPP" que abría wa.me con un mensaje pre-armado, y un
/// bloque de historial de avisos. Lo eliminamos cuando el bot Node.js
/// (`whatsapp-bot/`) tomó el envío automático de avisos. Si querés
/// recuperarlo, mirá el commit anterior a esta limpieza.
///
/// Uso:
/// ```
/// VencimientoEditorSheet.show(context, item);
/// ```
class VencimientoEditorSheet {
  VencimientoEditorSheet._();

  static Future<void> show(BuildContext context, VencimientoItem item) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _EditorSheetBody(item: item),
    );
  }
}

class _EditorSheetBody extends StatefulWidget {
  final VencimientoItem item;
  const _EditorSheetBody({required this.item});

  @override
  State<_EditorSheetBody> createState() => _EditorSheetBodyState();
}

class _EditorSheetBodyState extends State<_EditorSheetBody> {
  late DateTime _fechaSeleccionada;
  Uint8List? _archivoBytes;
  String? _archivoNombre;
  bool _subiendo = false;

  final StorageService _storageService = StorageService();

  @override
  void initState() {
    super.initState();
    _fechaSeleccionada =
        AppFormatters.tryParseFecha(widget.item.fecha) ?? DateTime.now();
  }

  Future<void> _seleccionarFecha() async {
    final picker = await pickFecha(
      context,
      initial: _fechaSeleccionada,
      titulo: 'Vencimiento ${widget.item.tipoDoc}',
    );
    if (picker != null && mounted) {
      setState(() => _fechaSeleccionada = picker);
    }
  }

  Future<void> _seleccionarArchivo() async {
    // withData: true para que `bytes` venga poblado en todas las plataformas
    // (en Web `path` es null porque no hay filesystem).
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'pdf'],
      withData: true,
    );
    final picked = result?.files.singleOrNull;
    if (picked != null && picked.bytes != null && mounted) {
      setState(() {
        _archivoBytes = picked.bytes;
        _archivoNombre = picked.name;
      });
    }
  }

  Future<String?> _subirArchivo() async {
    if (_archivoBytes == null) return widget.item.urlArchivo;

    final extension =
        (_archivoNombre ?? '').split('.').last.toLowerCase();
    final nombre =
        '${widget.item.docId}_ADMIN_${widget.item.campoBase}_${DateTime.now().millisecondsSinceEpoch}.$extension';
    final ruta = '${widget.item.storagePath}/$nombre';

    return await _storageService.subirArchivo(
      bytes: _archivoBytes!,
      nombreOriginal: _archivoNombre ?? 'archivo.$extension',
      rutaStorage: ruta,
    );
  }

  Future<void> _guardar() async {
    setState(() => _subiendo = true);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    try {
      final urlFinal = await _subirArchivo();
      final fechaStr = AppFormatters.aIsoFechaLocal(_fechaSeleccionada);

      await FirebaseFirestore.instance
          .collection(widget.item.coleccion)
          .doc(widget.item.docId)
          .update({
        'VENCIMIENTO_${widget.item.campoBase}': fechaStr,
        'ARCHIVO_${widget.item.campoBase}': urlFinal,
        'ultima_modificacion_admin': FieldValue.serverTimestamp(),
      });

      AppFeedback.successOn(messenger, '${widget.item.tipoDoc} actualizado con éxito');
      navigator.pop();
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario:
            'No se pudo guardar el vencimiento. Verificá tu conexión y probá de nuevo.',
        tecnico: e,
        stack: s,
      );
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xl,
        AppSpacing.xl,
        MediaQuery.of(context).viewInsets.bottom + AppSpacing.xl,
      ),
      decoration: const BoxDecoration(
        color: AppColors.surface2,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.lg),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle visual
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppColors.textHint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Título
          Text(
            'Actualizar ${widget.item.tipoDoc}',
            style: AppType.heading.copyWith(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: AppSpacing.xs + 1),
          Text(
            widget.item.titulo,
            style: AppType.body.copyWith(
              color: AppColors.brand,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Divider(color: AppColors.borderSubtle, height: 25),

          // Selector de fecha. El ListTile va envuelto en un
          // Material(transparency): el sheet es un DecoratedBox con color
          // (surface2) y, sin un Material entre medio, el tile pinta su
          // splash sobre ese DecoratedBox → assert de Flutter 3.44
          // "background color or ink splashes may be invisible" (Sentry
          // FLUTTER-27). El Material transparente no cambia layout ni color.
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Fecha de vencimiento',
                style: AppType.label.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
              subtitle: Text(
                AppFormatters.formatearFecha(_fechaSeleccionada),
                style: AppType.heading.copyWith(
                  color: AppColors.textPrimary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              trailing: const Icon(Icons.event_note,
                  color: AppColors.brand, size: 28),
              onTap: _seleccionarFecha,
            ),
          ),

          const SizedBox(height: AppSpacing.lg - 1),

          // Selector de archivo
          InkWell(
            onTap: _seleccionarArchivo,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppColors.surface0,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(
                  color: _archivoBytes == null
                      ? AppColors.borderSubtle
                      : AppColors.success,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _archivoBytes == null
                        ? Icons.upload_file
                        : Icons.check_circle,
                    color: _archivoBytes == null
                        ? AppColors.textDisabled
                        : AppColors.success,
                    size: 28,
                  ),
                  const SizedBox(width: AppSpacing.lg - 1),
                  Expanded(
                    child: Text(
                      _archivoBytes == null
                          ? 'Cargar comprobante nuevo'
                          : 'Archivo listo para subir',
                      style: AppType.body.copyWith(
                        color: _archivoBytes == null
                            ? AppColors.textTertiary
                            : AppColors.success,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (_archivoBytes == null)
                    const Icon(Icons.add_a_photo_outlined,
                        color: AppColors.brand, size: 20),
                ],
              ),
            ),
          ),

          const SizedBox(height: AppSpacing.xl),

          // Botones de acción
          Row(
            children: [
              Expanded(
                child: AppButton.secondary(
                  label: 'Cancelar',
                  expand: true,
                  onPressed:
                      _subiendo ? null : () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: AppSpacing.lg - 1),
              Expanded(
                child: AppButton(
                  label: 'Guardar cambios',
                  expand: true,
                  isLoading: _subiendo,
                  // Disabled mientras sube — antes el doble tap rapido
                  // disparaba 2 uploads paralelos (auditoria 2026-05-17).
                  onPressed: _subiendo ? null : _guardar,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
