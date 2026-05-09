import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Bandeja de respuestas que el bot recibió pero no pudo asociar
/// automáticamente a un aviso (Fase 3).
///
/// Casos:
/// - El chofer mandó una foto sin tener un aviso reciente del bot.
/// - Tiene varios avisos pendientes y la respuesta no cita ninguno
///   (ambiguo: ¿es para la licencia o el preocupacional?).
///
/// El admin las procesa acá: ve el mensaje + foto + fecha detectada y
/// puede convertirlas en revisión eligiendo el papel, o descartarlas.
class AdminBotBandejaScreen extends StatelessWidget {
  const AdminBotBandejaScreen({super.key});

  static const String _coleccion = 'RESPUESTAS_BOT_AMBIGUAS';

  Future<void> _descartar(BuildContext context, String docId) async {
    final ok = await AppConfirmDialog.show(
      context,
      title: '¿Descartar este mensaje?',
      message:
          'Se elimina de la bandeja. La foto sigue en Storage hasta que se borre manualmente.',
      confirmLabel: 'DESCARTAR',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (ok != true) return;
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await FirebaseFirestore.instance
          .collection(_coleccion)
          .doc(docId)
          .delete();
      AppFeedback.successOn(messenger, 'Mensaje descartado.');
    } catch (e) {
      AppFeedback.errorOn(messenger, 'No se pudo descartar: $e');
    }
  }

  /// Convierte la respuesta ambigua en una revisión "real" en
  /// `REVISIONES`. El admin elige cuál papel le corresponde a través
  /// del bottom sheet de candidatos.
  ///
  /// Como esta operación cruza colecciones, la hacemos en un batch
  /// para que sea atómica: o se crea la revisión y se borra la
  /// ambigua, o no pasa nada.
  Future<void> _convertirEnRevision(
    BuildContext context,
    QueryDocumentSnapshot doc,
  ) async {
    final data = doc.data() as Map<String, dynamic>;
    final candidatos = (data['candidatos'] as List<dynamic>? ?? const []);

    final messenger = ScaffoldMessenger.of(context);
    String? campoElegido;
    String? etiquetaElegida;

    if (candidatos.isEmpty) {
      // Sin candidatos: no podemos sugerir ningún papel. Avisamos al
      // admin que use la app de la forma tradicional (subir manual).
      AppFeedback.warningOn(
        messenger,
        'Este mensaje no tiene avisos asociados. Convertilo manualmente desde "Revisiones".',
      );
      return;
    }

    // Sheet con los candidatos (los avisos del bot que aún están
    // pendientes de respuesta para este chofer).
    final elegido = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                '¿A QUÉ PAPEL CORRESPONDE?',
                style: TextStyle(
                  color: AppColors.accentGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ...candidatos.map((c) {
              final cMap = c as Map<String, dynamic>;
              return ListTile(
                leading: const Icon(Icons.event_note,
                    color: AppColors.accentGreen),
                title: Text(
                  (cMap['campo_base'] ?? 'Documento').toString(),
                  style: const TextStyle(color: Colors.white),
                ),
                onTap: () => Navigator.pop(sCtx, cMap),
              );
            }),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (elegido == null) return;
    campoElegido = elegido['campo_base']?.toString();
    etiquetaElegida = campoElegido;
    if (campoElegido == null || campoElegido.isEmpty) return;

    if (!context.mounted) return;

    try {
      final db = FirebaseFirestore.instance;
      final batch = db.batch();
      // Crear la revisión nueva
      final revRef = db.collection(AppCollections.revisiones).doc();
      batch.set(revRef, {
        'dni': data['dni'] ?? '',
        'nombre_usuario': data['nombre_usuario'] ?? '',
        'campo': 'VENCIMIENTO_$campoElegido',
        'coleccion_destino': 'EMPLEADOS',
        'etiqueta': etiquetaElegida,
        'fecha_vencimiento': data['fecha_detectada'] ?? '',
        'url_archivo': data['url_archivo'] ?? '',
        'path_storage': '',
        'estado': 'PENDIENTE',
        'fecha_solicitud': FieldValue.serverTimestamp(),
        'origen': 'BOT_WHATSAPP_MANUAL',
        'mensaje_chofer': data['mensaje_chofer'] ?? '',
      });
      // Borrar el ambiguo
      batch.delete(doc.reference);
      await batch.commit();
      if (!context.mounted) return;
      AppFeedback.successOn(messenger,
          'Convertido en revisión. Ya aparece en "Revisiones Pendientes".');
    } catch (e) {
      if (!context.mounted) return;
      AppFeedback.errorOn(messenger, 'No se pudo convertir: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Bandeja del Bot',
      body: StreamBuilder<QuerySnapshot>(
        // Bug A11 del code review: subimos el limit a 200 (antes 50).
        // Si superan ese número, mostramos un banner indicando que hay
        // más esperando — para implementar paginación real con cursor
        // necesitaríamos refactorizar el stream a paginated futureBuilder.
        // Por ahora 200 cubre el peor caso realista (un mes con 10
        // ambiguos por día).
        stream: FirebaseFirestore.instance
            .collection(_coleccion)
            .orderBy('creado_en', descending: true)
            .limit(200)
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(subtitle: snap.error.toString());
          }
          if (!snap.hasData) return const AppLoadingState();
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const AppEmptyState(
              icon: Icons.inbox_outlined,
              title: 'Bandeja vacía',
              subtitle:
                  'Las respuestas que el bot no pueda asociar con un aviso van a aparecer acá.',
            );
          }
          // Si llegamos al límite, avisamos al admin que puede haber más.
          final llegoAlLimite = docs.length >= 200;
          return Column(
            children: [
              if (llegoAlLimite)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  color: Colors.amber.withAlpha(30),
                  child: const Text(
                    '⚠️ Mostrando los 200 más recientes. Procesá los antiguos para ver más.',
                    style: TextStyle(color: AppColors.accentAmber, fontSize: 12),
                    textAlign: TextAlign.center,
                  ),
                ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                  itemCount: docs.length,
                  itemBuilder: (ctx, i) => _ItemAmbiguo(
                    doc: docs[i],
                    onConvertir: () =>
                        _convertirEnRevision(context, docs[i]),
                    onDescartar: () => _descartar(context, docs[i].id),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _ItemAmbiguo extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  final VoidCallback onConvertir;
  final VoidCallback onDescartar;

  const _ItemAmbiguo({
    required this.doc,
    required this.onConvertir,
    required this.onDescartar,
  });

  String _formatTs(dynamic ts) {
    if (ts is! Timestamp) return '';
    return AppFormatters.formatearFechaHoraCorta(ts.toDate());
  }

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final nombre = (data['nombre_usuario'] ?? data['dni'] ?? '?').toString();
    final dni = (data['dni'] ?? '').toString();
    final mensaje = (data['mensaje_chofer'] ?? '').toString();
    final urlArchivo = (data['url_archivo'] ?? '').toString();
    final fechaDet = (data['fecha_detectada'] ?? '').toString();
    final razon = (data['razon'] ?? '').toString();
    final candidatos =
        (data['candidatos'] as List<dynamic>? ?? const []).length;

    return AppCard(
      borderColor: AppColors.accentOrange.withAlpha(80),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.smart_toy_outlined,
                  size: 18, color: AppColors.accentOrange),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  nombre,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatTs(data['creado_en']),
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
          if (dni.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(
                'DNI $dni',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ),
          const SizedBox(height: 10),
          if (urlArchivo.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AppFileThumbnail(
                url: urlArchivo,
                tituloVisor: 'Comprobante de $nombre',
                size: 80,
              ),
            ),
          if (urlArchivo.isNotEmpty) const SizedBox(height: 10),
          if (mensaje.isNotEmpty)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white.withAlpha(8),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                mensaje,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  height: 1.4,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (fechaDet.isNotEmpty) ...[
                const Icon(Icons.event_note,
                    size: 12, color: AppColors.accentGreen),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    'Fecha detectada: $fechaDet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.accentGreen,
                      fontSize: 11,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              const Spacer(),
              _BadgeRazon(razon: razon, candidatos: candidatos),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(
                onPressed: onDescartar,
                icon: const Icon(Icons.delete_outline,
                    color: Colors.white54, size: 16),
                label: const Text(
                  'Descartar',
                  style: TextStyle(color: Colors.white54, fontSize: 11),
                ),
              ),
              const SizedBox(width: 4),
              ElevatedButton.icon(
                onPressed: onConvertir,
                icon: const Icon(Icons.check, size: 16),
                label: const Text('Convertir en revisión'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BadgeRazon extends StatelessWidget {
  final String razon;
  final int candidatos;
  const _BadgeRazon({required this.razon, required this.candidatos});

  @override
  Widget build(BuildContext context) {
    final etiqueta = razon == 'ambiguo'
        ? '$candidatos candidatos'
        : razon == 'sin_aviso_reciente'
            ? 'sin aviso'
            : razon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accentOrange.withAlpha(20),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.accentOrange.withAlpha(80)),
      ),
      child: Text(
        etiqueta.toUpperCase(),
        style: const TextStyle(
          color: AppColors.accentOrange,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
