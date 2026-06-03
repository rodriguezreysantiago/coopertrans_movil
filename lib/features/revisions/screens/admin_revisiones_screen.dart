// lib/features/revisions/screens/admin_revisiones_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — bandeja de revisiones en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream (`REVISIONES` con `estado == PENDIENTE`, orderBy
//     fecha_vencimiento),
//   - `AppListPage` (buscador + filtro por chofer/patente/documento),
//   - el flujo de detalle (`_DetalleRevision.abrir`, `abrirDetalleRevision`
//     usado por el CommandPalette),
//   - TODAS las acciones (aprobar/rechazar, `RevisionService.finalizarRevision`,
//     `_aprobarDocumento`, `_aprobarCambioEquipo`, `_elegirUnidadLibre`,
//     confirmaciones destructivas y auditoría fire-and-forget),
//   - la navegación y el `PreviewScreen`.
//
// Layout Núcleo: header (eyebrow REVISIONES + número pendientes) + AppKpiStrip
// (pendientes · documentos · cambios de unidad) derivado del MISMO stream
// visible (cero números inventados — al aprobar/rechazar el doc se borra, no
// hay histórico de aprobadas/rechazadas que mostrar) + filas AppCard(tier:1)
// con AppBadge de tipo + thumbnail (AppFileThumbnail). Embedded: sin fondo.

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/revision_service.dart';

/// Pantalla de Revisiones Pendientes (Admin).
///
/// Lista todas las solicitudes que los choferes envían:
/// - Cambio de unidad (tractor o enganche)
/// - Renovación de papel/documento (fecha + archivo)
///
/// Migrada al sistema de diseño Núcleo.
class AdminRevisionesScreen extends StatefulWidget {
  const AdminRevisionesScreen({super.key});

  @override
  State<AdminRevisionesScreen> createState() =>
      _AdminRevisionesScreenState();
}

class _AdminRevisionesScreenState extends State<AdminRevisionesScreen> {
  late final Stream<QuerySnapshot> _revisionesStream;

  @override
  void initState() {
    super.initState();
    // Filtramos explícito `estado == PENDIENTE` para alinear con los
    // badges del shell + del menú de Vencimientos (admin_shell.dart y
    // admin_vencimientos_menu_screen.dart) — antes la pantalla mostraba
    // cualquier doc de la collection sin importar el estado, pero un doc
    // tirado con otro estado por debug habría dejado al admin sin entender
    // "¿qué hago con esto?". Hoy el flujo borra al aprobar/rechazar; esto
    // es red de seguridad para estados intermedios futuros.
    _revisionesStream = FirebaseFirestore.instance
        .collection(AppCollections.revisiones)
        .where('estado', isEqualTo: 'PENDIENTE')
        .orderBy('fecha_vencimiento', descending: false)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Revisiones Pendientes',
      body: AppListPage(
        stream: _revisionesStream,
        searchHint: 'Buscar por chofer, patente o documento...',
        emptyTitle: 'Sin trámites pendientes',
        emptySubtitle: 'Todas las solicitudes están al día.',
        emptyIcon: Icons.fact_check_outlined,
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 96),
        // Header con el resumen at-a-glance. Sale del MISMO stream que la
        // lista (otro StreamBuilder sobre el stream cacheado), así nunca
        // diverge de lo que se ve.
        header: StreamBuilder<QuerySnapshot>(
          stream: _revisionesStream,
          builder: (ctx, snap) => _HeaderResumen(docs: snap.data?.docs),
        ),
        filter: (doc, q) {
          final data = doc.data() as Map<String, dynamic>;
          final hay = '${data['nombre_usuario'] ?? ''} '
                  '${data['etiqueta'] ?? ''} '
                  '${data['patente'] ?? ''} '
                  '${data['dni'] ?? ''}'
              .toUpperCase();
          return hay.contains(q);
        },
        itemBuilder: (ctx, doc) => _RevisionCard(doc: doc),
      ),
    );
  }
}

// =============================================================================
// HEADER · eyebrow REVISIONES + número pendientes + AppKpiStrip
// =============================================================================

class _HeaderResumen extends StatelessWidget {
  final List<QueryDocumentSnapshot>? docs;
  const _HeaderResumen({required this.docs});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lista = docs;
    // Breakdown real sobre lo PENDIENTE: documentos vs cambios de unidad.
    // No mostramos "aprobadas/rechazadas" porque esos docs se borran al
    // decidir — no hay dato que contar (regla: nunca inventar).
    var documentos = 0;
    var cambios = 0;
    if (lista != null) {
      for (final d in lista) {
        final data = d.data() as Map<String, dynamic>;
        if (data['tipo_solicitud'] == 'CAMBIO_EQUIPO') {
          cambios++;
        } else {
          documentos++;
        }
      }
    }
    final total = lista?.length ?? 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Revisiones pendientes'),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                lista == null ? '—' : '$total',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  total == 1 ? 'trámite' : 'trámites',
                  style: AppType.monoSm,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppKpiStrip(
            stats: [
              AppStat(
                label: 'Pendientes',
                value: lista == null ? '—' : '$total',
                accent: total > 0 ? c.brand : c.textMuted,
              ),
              AppStat(
                label: 'Documentos',
                value: lista == null ? '—' : '$documentos',
              ),
              AppStat(
                label: 'Cambios de unidad',
                value: lista == null ? '—' : '$cambios',
                accent: cambios > 0 ? c.warning : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARD DE LA LISTA (Núcleo) — AppCard(tier:1) por fila.
// =============================================================================

class _RevisionCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _RevisionCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';
    final esVehiculo = data['coleccion_destino'] == 'VEHICULOS';
    final idAfectado =
        (data['dni'] ?? data['patente'] ?? '—').toString().toUpperCase();
    final nombreUsuario =
        (data['nombre_usuario'] ?? 'Usuario').toString();
    final etiqueta = (data['etiqueta'] ?? 'Documento').toString();
    final url = (data['url_archivo'] ?? '').toString();

    // Color/icono/label semánticos según tipo de solicitud.
    final tipoColor = esCambioEquipo
        ? c.warning
        : (esVehiculo ? c.info : c.success);
    final tipoIcon = esCambioEquipo
        ? Icons.swap_horiz
        : (esVehiculo ? Icons.local_shipping : Icons.person);
    final tipoLabel = esCambioEquipo
        ? 'Cambio de unidad'
        : (esVehiculo ? 'Doc. unidad' : 'Documento');

    final subtitulo = esCambioEquipo
        ? ((data['patente'] ?? '').toString().trim().isEmpty
            ? 'Reporta que ${data['unidad_actual'] ?? 'su unidad'} no es la suya'
            : 'Solicita: ${data['patente']}')
        : '$etiqueta · vence ${AppFormatters.formatearFecha(data['fecha_vencimiento'])}';

    return AppCard(
      tier: 1,
      onTap: () => _DetalleRevision.abrir(context, doc.id, data),
      // Cambios de equipo destacados con un acento ámbar para que llamen
      // la atención (antes era un borde naranja completo).
      accent: esCambioEquipo ? c.warning : null,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Icono del tipo en una caja con tinte semántico suave.
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: tipoColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(tipoIcon, color: tipoColor, size: 20),
          ),
          const SizedBox(width: AppSpacing.md),
          // Info del item.
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$nombreUsuario  →  $idAfectado',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    AppBadge(
                      text: tipoLabel,
                      color: tipoColor,
                      size: AppBadgeSize.sm,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        subtitulo,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Thumbnail del archivo si hay (solo documentos).
          if (!esCambioEquipo && url.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
            AppFileThumbnail(
              url: url,
              tituloVisor: '$etiqueta - $idAfectado',
              size: 36,
            ),
          ],
          const SizedBox(width: AppSpacing.xs),
          Icon(Icons.chevron_right, color: c.textMuted, size: 18),
        ],
      ),
    );
  }
}

// =============================================================================
// DETALLE DE LA REVISIÓN (bottom sheet)
// =============================================================================

/// Wrapper público para abrir el detalle de una revisión desde otros
/// features (ej. el CommandPalette / búsqueda Ctrl+K).
Future<void> abrirDetalleRevision(
  BuildContext context,
  String idDoc,
  Map<String, dynamic> data,
) =>
    _DetalleRevision.abrir(context, idDoc, data);

class _DetalleRevision extends StatelessWidget {
  final String idDoc;
  final Map<String, dynamic> data;
  final ScrollController scrollController;

  const _DetalleRevision({
    required this.idDoc,
    required this.data,
    required this.scrollController,
  });

  static Future<void> abrir(
    BuildContext context,
    String idDoc,
    Map<String, dynamic> data,
  ) {
    final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';
    return AppDetailSheet.show(
      context: context,
      title: esCambioEquipo
          ? 'Cambio de unidad'
          : (data['etiqueta'] ?? 'Documento').toString(),
      icon: esCambioEquipo ? Icons.swap_horiz : Icons.fact_check,
      builder: (sheetCtx, scrollCtl) => _DetalleRevision(
        idDoc: idDoc,
        data: data,
        scrollController: scrollCtl,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';
    final url = (data['url_archivo'] ?? '').toString();
    final etiqueta = (data['etiqueta'] ?? 'Documento').toString();
    final idAfectado =
        (data['dni'] ?? data['patente'] ?? '—').toString().toUpperCase();
    final nombreUsuario =
        (data['nombre_usuario'] ?? '—').toString();

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
            children: [
              // Header del solicitante.
              _InfoCard(
                label: 'SOLICITANTE',
                valor: nombreUsuario,
                icon: Icons.person_outline,
              ),
              const SizedBox(height: AppSpacing.sm),

              if (esCambioEquipo) ..._buildContenidoCambioEquipo(context)
              else ..._buildContenidoDocumento(
                context,
                url: url,
                etiqueta: etiqueta,
                idAfectado: idAfectado,
              ),
            ],
          ),
        ),

        // Footer con botones (siempre visibles).
        _BotonesAccion(
          onAprobar: () => _procesarDecision(context, true),
          // Rechazar es destructivo: borra el comprobante del chofer del
          // Storage y elimina la solicitud. No hay manera de revertir, el
          // chofer tiene que volver a fotografiar y subir todo. Por eso
          // pedimos confirmación con copy clara.
          onRechazar: () async {
            final ok = await AppConfirmDialog.show(
              context,
              title: '¿Rechazar este trámite?',
              message:
                  'Se va a borrar el comprobante que subió el chofer y la solicitud desaparece del listado. Esta acción no se puede deshacer.',
              confirmLabel: 'RECHAZAR',
              destructive: true,
              icon: Icons.cancel_outlined,
            );
            if (ok == true && context.mounted) {
              await _procesarDecision(context, false);
            }
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // CONTENIDO: CAMBIO DE EQUIPO
  // ---------------------------------------------------------------------------

  List<Widget> _buildContenidoCambioEquipo(BuildContext context) {
    final c = context.colors;
    return [
      const SizedBox(height: AppSpacing.sm),
      Center(
        child: Icon(Icons.swap_vert_circle, size: 64, color: c.warning),
      ),
      const SizedBox(height: AppSpacing.lg),
      _InfoCard(
        label: 'SUELTA',
        valor: (data['unidad_actual'] ?? 'NINGUNA').toString(),
        valorColor: c.error,
        icon: Icons.link_off,
        mono: true,
      ),
      const SizedBox(height: AppSpacing.sm),
      if ((data['patente'] ?? '').toString().trim().isEmpty)
        // Flujo "no es mi unidad" (2026-05-21): el chofer no eligió. El admin
        // elige la unidad al tocar APROBAR.
        _InfoCard(
          label: 'EL CHOFER REPORTA QUE NO ES SU UNIDAD',
          valor: 'Elegí la unidad correcta al aprobar',
          valorColor: c.warning,
          icon: Icons.report_problem_outlined,
        )
      else
        _InfoCard(
          label: 'SOLICITA',
          valor: (data['patente'] ?? '—').toString(),
          valorColor: c.success,
          icon: Icons.add_link,
          mono: true,
        ),
    ];
  }

  // ---------------------------------------------------------------------------
  // CONTENIDO: DOCUMENTO (renovación de papel)
  // ---------------------------------------------------------------------------

  List<Widget> _buildContenidoDocumento(
    BuildContext context, {
    required String url,
    required String etiqueta,
    required String idAfectado,
  }) {
    final c = context.colors;
    final esPdf = url.split('?').first.toLowerCase().endsWith('.pdf');

    return [
      // Preview grande del archivo.
      if (url.isNotEmpty)
        _PreviewArchivo(
          url: url,
          titulo: '$etiqueta - $idAfectado',
          esPdf: esPdf,
        ),
      const SizedBox(height: AppSpacing.lg),
      _InfoCard(
        label: 'NUEVO VENCIMIENTO PROPUESTO',
        valor: AppFormatters.formatearFecha(data['fecha_vencimiento']),
        valorColor: c.success,
        valorSize: 22,
        icon: Icons.event_note,
        mono: true,
      ),
    ];
  }

  // ---------------------------------------------------------------------------
  // PROCESAR APROBACIÓN / RECHAZO
  // ---------------------------------------------------------------------------

  Future<void> _procesarDecision(
    BuildContext context,
    bool aprobado,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';

    // Validación previa: si no tenemos id de la solicitud no podemos hacer
    // nada útil — abortamos antes de cerrar el sheet.
    if (idDoc.isEmpty) {
      AppFeedback.errorOn(messenger, 'Solicitud inválida (sin ID).');
      return;
    }

    // Bug A7 del code review: antes cerrábamos el sheet ANTES del delete.
    // Si fallaba el update/delete, el admin veía "operación aprobada"
    // pero el doc seguía. Ahora primero hacemos el cambio, después
    // cerramos el sheet con feedback de éxito o error real.
    try {
      if (aprobado) {
        if (esCambioEquipo) {
          var datosFinal = data;
          final patenteSolicitada = (data['patente'] ?? '').toString().trim();
          if (patenteSolicitada.isEmpty) {
            // Flujo nuevo 2026-05-21: el chofer reporta "no es mi unidad" SIN
            // elegir. El admin asigna la unidad correcta acá. Sin elección no
            // se aprueba (return sin tocar nada).
            final esTractor = (data['campo'] ?? '') == 'SOLICITUD_VEHICULO';
            final elegida =
                await _elegirUnidadLibre(context, esTractor: esTractor);
            if (elegida == null || elegida.trim().isEmpty) return;
            datosFinal = {...data, 'patente': elegida.trim()};
          }
          await _aprobarCambioEquipo(datosFinal);
        } else {
          await _aprobarDocumento();
        }
      } else {
        // Rechazo: solo borramos la solicitud
        await FirebaseFirestore.instance
            .collection(AppCollections.revisiones)
            .doc(idDoc)
            .delete();
      }

      // Audit fire-and-forget: una sola entrada por revisión, con tipo
      // (cambio de equipo o documento) en `detalles` para auditar luego.
      // Solo se llama tras éxito real del cambio.
      unawaited(AuditLog.registrar(
        accion: aprobado
            ? AuditAccion.aprobarRevision
            : AuditAccion.rechazarRevision,
        entidad: 'REVISIONES',
        entidadId: idDoc,
        detalles: {
          'tipo': esCambioEquipo ? 'CAMBIO_EQUIPO' : 'DOCUMENTO',
          'solicitante': (data['nombre_usuario'] ?? '').toString(),
          'sobre': (data['etiqueta'] ?? data['campo'] ?? '').toString(),
        },
      ));

      // Cerrar sheet solo después del éxito.
      if (context.mounted) navigator.pop();

      final mensaje = aprobado
          ? 'Operación aprobada y guardada'
          : 'Solicitud rechazada y eliminada';
      if (aprobado) {
        AppFeedback.successOn(messenger, mensaje);
      } else {
        AppFeedback.errorOn(messenger, mensaje);
      }
    } on StateError catch (e) {
      // Solicitudes corruptas (sin dni/patente/campo) — mensaje claro
      // en vez del críptico "document path must be a non-empty string".
      debugPrint('Solicitud corrupta: ${e.message}');
      // En este caso sí cerramos el sheet (el doc se eliminó dentro de
      // _aprobarCambioEquipo / _aprobarDocumento al detectar la
      // corrupción).
      if (context.mounted) navigator.pop();
      AppFeedback.warningOn(messenger, e.message);
    } catch (e, s) {
      // En error genérico el sheet QUEDA abierto para que el admin
      // vea que la operación falló y pueda reintentar o cancelar
      // manualmente.
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo conectar con la base de datos. Probá de nuevo en unos segundos.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Future<void> _aprobarCambioEquipo(Map<String, dynamic> datos) async {
    // Delegamos al RevisionService que YA pasa por AsignacionVehiculoService
    // / AsignacionEngancheService — esos services crean el doc en
    // ASIGNACIONES_VEHICULO/ASIGNACIONES_ENGANCHE (log temporal
    // inmutable + cierre del anterior + odometer snapshot al cierre),
    // ademas de actualizar EMPLEADOS.VEHICULO/ENGANCHE y
    // VEHICULOS.ESTADO.
    //
    // `datos` puede traer la `patente` que eligió el admin (flujo "no es mi
    // unidad" 2026-05-21) o la que ya venía en la solicitud (flujo viejo).
    //
    // RevisionService.finalizarRevision tiene su propia validacion
    // defensiva (StateError si la solicitud no tiene IDs minimos +
    // borra la solicitud rota), asi que no necesitamos duplicarla aca.
    await RevisionService().finalizarRevision(
      idSolicitud: idDoc,
      aprobado: true,
      datos: datos,
    );
  }

  /// Bottom sheet para que el ADMIN elija una unidad LIBRE al aprobar un
  /// reporte "no es mi unidad" (el chofer ya no elige; ver
  /// user_mi_equipo_widgets). Devuelve la patente elegida, o null si cerró.
  Future<String?> _elegirUnidadLibre(
    BuildContext context, {
    required bool esTractor,
  }) {
    final c = context.colors;
    final patenteActual = (data['unidad_actual'] ?? '').toString().trim();
    final stream = esTractor
        ? FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .where('TIPO', isEqualTo: 'TRACTOR')
            .where('ESTADO', isEqualTo: 'LIBRE')
            .snapshots()
        : FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .where('TIPO', whereIn: AppTiposVehiculo.enganches)
            .where('ESTADO', isEqualTo: 'LIBRE')
            .snapshots();

    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: c.bg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (cc, scrollCtl) => Column(
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(
                  top: AppSpacing.sm, bottom: AppSpacing.xs),
              decoration: BoxDecoration(
                color: c.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppEyebrow(
                    'Asignar ${esTractor ? "tractor" : "enganche"} libre'),
              ),
            ),
            const AppHairline(),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: stream,
                builder: (c2, snap) {
                  if (!snap.hasData) return const AppLoadingState();
                  final unidades = snap.data!.docs
                      .where((d) => d.id != patenteActual)
                      .toList();
                  if (unidades.isEmpty) {
                    return const AppEmptyState(
                      icon: Icons.directions_car_outlined,
                      title: 'No hay unidades libres',
                      subtitle:
                          'No hay unidades de este tipo en estado LIBRE.',
                    );
                  }
                  return ListView.separated(
                    controller: scrollCtl,
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.lg),
                    itemCount: unidades.length,
                    separatorBuilder: (_, __) => const AppHairline(),
                    itemBuilder: (c3, i) {
                      final u = unidades[i];
                      final d = u.data() as Map<String, dynamic>;
                      final modelo =
                          '${d['MARCA'] ?? '—'} ${d['MODELO'] ?? ''}'.trim();
                      return ListTile(
                        leading: Icon(Icons.local_shipping_outlined,
                            color: c.textMuted),
                        title: Text(
                          u.id,
                          style: AppType.body.copyWith(
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.5,
                          ),
                        ),
                        subtitle: Text(
                          modelo.isEmpty ? '—' : modelo,
                          style: AppType.monoSm.copyWith(color: c.textMuted),
                        ),
                        trailing:
                            Icon(Icons.check_circle, color: c.success),
                        onTap: () => Navigator.pop(ctx, u.id),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _aprobarDocumento() async {
    final db = FirebaseFirestore.instance;
    final coleccion = (data['coleccion_destino'] ?? 'EMPLEADOS').toString().trim();
    final idDestino =
        (data['dni'] ?? data['patente'] ?? '').toString().trim().toUpperCase();
    final campoVencimiento = (data['campo'] ?? '').toString().trim();
    final urlArchivo = (data['url_archivo'] ?? '').toString();

    // Validación defensiva: sin idDestino o sin campo no podemos persistir
    // el cambio. Sin idDoc no podemos borrar la solicitud. Cualquier doc
    // path vacío hace explotar el plugin de Firestore.
    if (idDoc.isEmpty) {
      throw StateError('La solicitud no tiene ID válido.');
    }
    if (idDestino.isEmpty || campoVencimiento.isEmpty || coleccion.isEmpty) {
      // Limpiamos la solicitud rota — el admin no la puede salvar.
      await db.collection(AppCollections.revisiones).doc(idDoc).delete();
      throw StateError(
        'La solicitud no tiene destino (dni/patente) o campo válidos. '
        'Se eliminó del listado.',
      );
    }

    final campoArchivo =
        campoVencimiento.replaceAll('VENCIMIENTO_', 'ARCHIVO_');
    await db.collection(coleccion).doc(idDestino).update({
      campoVencimiento: data['fecha_vencimiento'],
      campoArchivo: urlArchivo,
      'ultima_actualizacion_sistema': FieldValue.serverTimestamp(),
    });
    await db.collection(AppCollections.revisiones).doc(idDoc).delete();
  }
}

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

/// Card de información tipo "etiqueta + valor" para mostrar campos del trámite.
class _InfoCard extends StatelessWidget {
  final String label;
  final String valor;
  final Color? valorColor;
  final double? valorSize;
  final IconData icon;
  final bool mono;

  const _InfoCard({
    required this.label,
    required this.valor,
    required this.icon,
    this.valorColor,
    this.valorSize,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valBase = mono ? AppType.mono : AppType.body;
    return AppCard(
      tier: 1,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(icon, color: c.textMuted, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label.toUpperCase(),
                  style: AppType.eyebrow.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: 3),
                Text(
                  valor,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: valBase.copyWith(
                    color: valorColor ?? c.text,
                    fontWeight: FontWeight.w600,
                    fontSize: valorSize,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview grande del archivo adjunto (se puede tocar para ver pantalla completa).
class _PreviewArchivo extends StatelessWidget {
  final String url;
  final String titulo;
  final bool esPdf;

  const _PreviewArchivo({
    required this.url,
    required this.titulo,
    required this.esPdf,
  });

  void _abrirVisor(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PreviewScreen(url: url, titulo: titulo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => _abrirVisor(context),
        child: esPdf
            ? Container(
                height: 180,
                decoration: BoxDecoration(
                  color: c.errorSoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.error.withValues(alpha: 0.5)),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.picture_as_pdf, size: 56, color: c.error),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        'Tocar para ver PDF',
                        style: AppType.eyebrow.copyWith(color: c.error),
                      ),
                    ],
                  ),
                ),
              )
            : ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.lg),
                child: Image.network(
                  url,
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  loadingBuilder: (ctx, child, progress) {
                    if (progress == null) return child;
                    return SizedBox(
                      height: 220,
                      child: Center(
                        child: CircularProgressIndicator(color: c.brand),
                      ),
                    );
                  },
                  errorBuilder: (_, __, ___) => Container(
                    height: 150,
                    decoration: BoxDecoration(
                      color: c.surface1,
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      border: Border.all(color: c.border),
                    ),
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.broken_image,
                              color: c.textMuted, size: 48),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Error al cargar imagen',
                            style: AppType.bodySm
                                .copyWith(color: c.textSecondary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Botones grandes de Aprobar/Rechazar al pie del sheet.
class _BotonesAccion extends StatelessWidget {
  final VoidCallback onAprobar;
  final VoidCallback onRechazar;

  const _BotonesAccion({
    required this.onAprobar,
    required this.onRechazar,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface2,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: AppButton.danger(
                label: 'Rechazar',
                icon: Icons.close,
                onPressed: onRechazar,
                full: true,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppButton(
                label: 'Aprobar',
                icon: Icons.check,
                onPressed: onAprobar,
                full: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
