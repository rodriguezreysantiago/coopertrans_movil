import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../core/services/storage_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/fecha_dialog.dart';
import 'vencimiento_item.dart';

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
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al guardar: $e');
      if (mounted) setState(() => _subiendo = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        20,
        20,
        MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
        border: const Border(
          top: BorderSide(color: AppColors.accentGreen, width: 2),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle visual
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Título
          Text(
            'Actualizar ${widget.item.tipoDoc}',
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            widget.item.titulo,
            style: const TextStyle(
              color: AppColors.accentGreen,
              fontWeight: FontWeight.w500,
            ),
          ),
          const Divider(color: Colors.white10, height: 25),

          // Selector de fecha
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text(
              'Fecha de vencimiento',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            subtitle: Text(
              AppFormatters.formatearFecha(_fechaSeleccionada),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
            trailing: const Icon(Icons.event_note,
                color: AppColors.accentGreen, size: 28),
            onTap: _seleccionarFecha,
          ),

          const SizedBox(height: 15),

          // Selector de archivo
          InkWell(
            onTap: _seleccionarArchivo,
            borderRadius: BorderRadius.circular(15),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(15),
                border: Border.all(
                  color: _archivoBytes == null
                      ? Colors.white10
                      : AppColors.accentGreen,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _archivoBytes == null
                        ? Icons.upload_file
                        : Icons.check_circle,
                    color: _archivoBytes == null
                        ? Colors.white38
                        : AppColors.accentGreen,
                    size: 28,
                  ),
                  const SizedBox(width: 15),
                  Expanded(
                    child: Text(
                      _archivoBytes == null
                          ? 'Cargar comprobante nuevo'
                          : 'Archivo listo para subir',
                      style: TextStyle(
                        color: _archivoBytes == null
                            ? Colors.white54
                            : AppColors.accentGreen,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (_archivoBytes == null)
                    const Icon(Icons.add_a_photo_outlined,
                        color: AppColors.accentGreen, size: 20),
                ],
              ),
            ),
          ),

          const SizedBox(height: 20),

          // Botones de acción
          if (_subiendo)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: CircularProgressIndicator(color: AppColors.accentGreen),
            )
          else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.white24),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'CANCELAR',
                      style: TextStyle(
                        color: Colors.white54,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 15),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    // Disabled mientras sube — antes el doble tap rapido
                    // disparaba 2 uploads paralelos (auditoria 2026-05-17).
                    onPressed: _subiendo ? null : _guardar,
                    child: _subiendo
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                        : const Text('GUARDAR CAMBIOS'),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
