import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Bandeja de respuestas que el bot recibió pero no pudo asociar
/// automáticamente a un aviso (Fase 3). REFACTOR NÚCLEO (jun 2026).
///
/// Casos:
/// - El chofer mandó una foto sin tener un aviso reciente del bot.
/// - Tiene varios avisos pendientes y la respuesta no cita ninguno
///   (ambiguo: ¿es para la licencia o el preocupacional?).
///
/// El admin las procesa acá: ve el mensaje + foto + fecha detectada y
/// puede convertirlas en revisión eligiendo el papel, o descartarlas.
///
/// Reescrita al layout Núcleo: header eyebrow + hero (conteo de la
/// bandeja), filas AppCard con hairline, badge semántico de razón,
/// DNI/timestamps en mono tabular. Stream, batch de conversión, descarte
/// y el sheet de candidatos quedan INTACTOS — solo cambió la presentación.
class AdminBotBandejaScreen extends StatelessWidget {
  const AdminBotBandejaScreen({super.key});

  static const String _coleccion = 'RESPUESTAS_BOT_AMBIGUAS';

  Future<void> _descartar(BuildContext context, String docId) async {
    final ok = await AppConfirmDialog.show(
      context,
      title: '¿Descartar este mensaje?',
      message:
          'Se elimina de la bandeja. La foto sigue en Storage hasta que se borre manualmente.',
      confirmLabel: 'Descartar',
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
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo descartar el mensaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
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
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sCtx) {
        final c = sCtx.colors;
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.xl, AppSpacing.xl, AppSpacing.xl, AppSpacing.md),
                child: AppEyebrow('¿A qué papel corresponde?'),
              ),
              ...candidatos.map((cand) {
                final cMap = cand as Map<String, dynamic>;
                return ListTile(
                  leading: Icon(Icons.event_note_outlined,
                      size: 20, color: c.brand),
                  title: Text(
                    (cMap['campo_base'] ?? 'Documento').toString(),
                    style: AppType.body,
                  ),
                  trailing: Icon(Icons.chevron_right, size: 18, color: c.textMuted),
                  onTap: () => Navigator.pop(sCtx, cMap),
                );
              }),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        );
      },
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
    } catch (e, s) {
      if (!context.mounted) return;
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo convertir en revisión. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
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
          // Si llegamos al límite, avisamos al admin que puede haber más.
          final llegoAlLimite = docs.length >= 200;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(cantidad: docs.length),
              if (llegoAlLimite) const _BannerLimite(),
              Expanded(
                child: docs.isEmpty
                    ? const AppEmptyState(
                        icon: Icons.inbox_outlined,
                        title: 'Bandeja vacía',
                        subtitle:
                            'Las respuestas que el bot no pueda asociar con un aviso van a aparecer acá.',
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxxl),
                        itemCount: docs.length,
                        itemBuilder: (ctx, i) => _ItemAmbiguo(
                          doc: docs[i],
                          onConvertir: () => _convertirEnRevision(context, docs[i]),
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

// =============================================================================
// HEADER — eyebrow + hero (conteo de la bandeja)
// =============================================================================

class _Header extends StatelessWidget {
  final int cantidad;
  const _Header({required this.cantidad});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Bandeja del bot'),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$cantidad',
                      style: AppType.h2.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'sin asignar',
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BannerLimite extends StatelessWidget {
  const _BannerLimite();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.fromLTRB(
          AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: c.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Mostrando los 200 más recientes. Procesá los antiguos para ver más.',
              style: AppType.label.copyWith(color: c.warning),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ITEM — fila AppCard con hairline interno
// =============================================================================

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
    if (ts is! Timestamp) return '—';
    return AppFormatters.formatearFechaHoraCorta(ts.toDate());
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
      tier: 1,
      accent: c.warning,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: icono + nombre + timestamp de detección.
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 20, color: c.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  nombre,
                  style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                _formatTs(data['creado_en']),
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
          if (dni.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 2),
              child: Text(
                'DNI $dni',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ),
          const SizedBox(height: AppSpacing.md),
          // Foto + mensaje en una fila para aprovechar el ancho.
          if (urlArchivo.isNotEmpty || mensaje.isNotEmpty)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (urlArchivo.isNotEmpty) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: AppFileThumbnail(
                      url: urlArchivo,
                      tituloVisor: 'Comprobante de $nombre',
                      size: 76,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                ],
                if (mensaje.isNotEmpty)
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: c.surface3,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        mensaje,
                        style: AppType.bodySm.copyWith(color: c.textSecondary),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: AppSpacing.md),
          // Línea de meta: fecha detectada + badge de razón.
          Row(
            children: [
              if (fechaDet.isNotEmpty) ...[
                Icon(Icons.event_available_outlined,
                    size: 14, color: c.success),
                const SizedBox(width: AppSpacing.xs),
                Flexible(
                  child: Text(
                    'Detectada: $fechaDet',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(color: c.success),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ],
              const Spacer(),
              _BadgeRazon(razon: razon, candidatos: candidatos),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          // Acciones.
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              AppButton.ghost(
                label: 'Descartar',
                icon: Icons.delete_outline,
                size: AppButtonSize.sm,
                onPressed: onDescartar,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppButton.primary(
                label: 'Convertir en revisión',
                icon: Icons.check,
                size: AppButtonSize.sm,
                onPressed: onConvertir,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Badge semántico de la razón por la que el mensaje quedó sin asignar.
/// "ambiguo" → cantidad de candidatos; "sin_aviso_reciente" → "sin aviso".
class _BadgeRazon extends StatelessWidget {
  final String razon;
  final int candidatos;
  const _BadgeRazon({required this.razon, required this.candidatos});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final etiqueta = razon == 'ambiguo'
        ? '$candidatos candidatos'
        : razon == 'sin_aviso_reciente'
            ? 'sin aviso'
            : (razon.isEmpty ? '—' : razon);
    return AppBadge(
      text: etiqueta,
      color: c.warning,
      size: AppBadgeSize.sm,
    );
  }
}
