import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/audit_log_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/revision_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Pantalla de Revisiones Pendientes (Admin).
///
/// Lista todas las solicitudes que los choferes envían:
/// - Cambio de unidad (tractor o enganche)
/// - Renovación de papel/documento (fecha + archivo)
///
/// Migrada al sistema de diseño unificado.
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
// CARD DE LA LISTA
// =============================================================================

class _RevisionCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _RevisionCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';
    final esVehiculo = data['coleccion_destino'] == 'VEHICULOS';
    final idAfectado =
        (data['dni'] ?? data['patente'] ?? 'N/A').toString().toUpperCase();
    final nombreUsuario =
        (data['nombre_usuario'] ?? 'Usuario').toString();
    final etiqueta = (data['etiqueta'] ?? 'Documento').toString();
    final url = (data['url_archivo'] ?? '').toString();

    // Color del icono y borde según tipo de solicitud
    final tipoColor = esCambioEquipo
        ? AppColors.warning
        : (esVehiculo ? AppColors.info : AppColors.success);
    final tipoIcon = esCambioEquipo
        ? Icons.swap_horiz
        : (esVehiculo ? Icons.local_shipping : Icons.person);

    return AppCard(
      onTap: () => _DetalleRevision.abrir(context, doc.id, data),
      // Cambios de equipo destacados con borde naranja para que llamen la atención
      highlighted: esCambioEquipo,
      borderColor: esCambioEquipo
          ? AppColors.warning.withAlpha(150)
          : null,
      child: Row(
        children: [
          // Avatar circular con icono según tipo
          CircleAvatar(
            radius: 22,
            backgroundColor: tipoColor.withAlpha(30),
            child: Icon(tipoIcon, color: tipoColor, size: 22),
          ),
          const SizedBox(width: AppSpacing.md),
          // Info del item
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$nombreUsuario → $idAfectado',
                  style: AppType.body.copyWith(fontWeight: FontWeight.bold, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  esCambioEquipo
                      ? ((data['patente'] ?? '').toString().trim().isEmpty
                          ? 'Reporta que ${data['unidad_actual'] ?? 'su unidad'} no es la suya'
                          : 'Solicita: ${data['patente']}')
                      : '$etiqueta · vence ${AppFormatters.formatearFecha(data['fecha_vencimiento'])}',
                  style: AppType.label.copyWith(color: Colors.white54),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Thumbnail del archivo si hay
          if (!esCambioEquipo && url.isNotEmpty) ...[
            const SizedBox(width: AppSpacing.sm),
            AppFileThumbnail(
              url: url,
              tituloVisor: '$etiqueta - $idAfectado',
              size: 32,
            ),
          ],
          const SizedBox(width: AppSpacing.xs),
          const Icon(Icons.chevron_right, color: Colors.white24, size: 18),
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
        (data['dni'] ?? data['patente'] ?? 'N/A').toString().toUpperCase();
    final nombreUsuario =
        (data['nombre_usuario'] ?? 'N/A').toString();

    return Column(
      children: [
        Expanded(
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            children: [
              // Header del solicitante
              _InfoCard(
                label: 'SOLICITANTE',
                valor: nombreUsuario,
                icon: Icons.person_outline,
              ),
              const SizedBox(height: 10),

              if (esCambioEquipo) ..._buildContenidoCambioEquipo()
              else ..._buildContenidoDocumento(
                context,
                url: url,
                etiqueta: etiqueta,
                idAfectado: idAfectado,
              ),
            ],
          ),
        ),

        // Footer con botones (siempre visibles)
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

  List<Widget> _buildContenidoCambioEquipo() {
    return [
      const SizedBox(height: 10),
      const Center(
        child: Icon(Icons.swap_vert_circle,
            size: 70, color: AppColors.warning),
      ),
      const SizedBox(height: 20),
      _InfoCard(
        label: 'SUELTA',
        valor: (data['unidad_actual'] ?? 'NINGUNA').toString(),
        valorColor: AppColors.error,
        icon: Icons.link_off,
      ),
      const SizedBox(height: 10),
      if ((data['patente'] ?? '').toString().trim().isEmpty)
        // Flujo "no es mi unidad" (2026-05-21): el chofer no eligió. El admin
        // elige la unidad al tocar APROBAR.
        const _InfoCard(
          label: 'EL CHOFER REPORTA QUE NO ES SU UNIDAD',
          valor: 'Elegí la unidad correcta al aprobar',
          valorColor: AppColors.warning,
          icon: Icons.report_problem_outlined,
        )
      else
        _InfoCard(
          label: 'SOLICITA',
          valor: (data['patente'] ?? 'S/D').toString(),
          valorColor: AppColors.success,
          icon: Icons.add_link,
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
    final esPdf = url.split('?').first.toLowerCase().endsWith('.pdf');

    return [
      // Preview grande del archivo
      if (url.isNotEmpty)
        _PreviewArchivo(
          url: url,
          titulo: '$etiqueta - $idAfectado',
          esPdf: esPdf,
        ),
      const SizedBox(height: 20),
      _InfoCard(
        label: 'NUEVO VENCIMIENTO PROPUESTO',
        valor: AppFormatters.formatearFecha(data['fecha_vencimiento']),
        valorColor: AppColors.success,
        valorSize: 22,
        icon: Icons.event_note,
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
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        builder: (c, scrollCtl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                'ASIGNAR ${esTractor ? "TRACTOR" : "ENGANCHE"} LIBRE',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
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
                  return ListView.builder(
                    controller: scrollCtl,
                    itemCount: unidades.length,
                    itemBuilder: (c3, i) {
                      final u = unidades[i];
                      final d = u.data() as Map<String, dynamic>;
                      return ListTile(
                        leading: const Icon(Icons.local_shipping_outlined,
                            color: Colors.white38),
                        title: Text(
                          u.id,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          '${d['MARCA'] ?? 'S/D'} ${d['MODELO'] ?? ''}',
                          style: AppType.label.copyWith(color: Colors.white54),
                        ),
                        trailing: const Icon(Icons.check_circle,
                            color: AppColors.success),
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
  final Color valorColor;
  final double valorSize;
  final IconData icon;

  const _InfoCard({
    required this.label,
    required this.valor,
    required this.icon,
    this.valorColor = Colors.white,
    this.valorSize = 16,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(8),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white38, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  valor,
                  style: TextStyle(
                    color: valorColor,
                    fontSize: valorSize,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        onTap: () => _abrirVisor(context),
        child: esPdf
            ? Container(
                height: 180,
                decoration: BoxDecoration(
                  color: AppColors.error.withAlpha(15),
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(
                      color: AppColors.error.withAlpha(80)),
                ),
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.picture_as_pdf,
                          size: 60, color: AppColors.error),
                      const SizedBox(height: 10),
                      Text(
                        'Tocar para ver PDF',
                        style: AppType.label.copyWith(color: AppColors.error, fontWeight: FontWeight.bold, letterSpacing: 0.8),
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
                    return const SizedBox(
                      height: 220,
                      child: Center(
                        child: CircularProgressIndicator(
                          color: AppColors.success,
                        ),
                      ),
                    );
                  },
                  errorBuilder: (_, __, ___) => Container(
                    height: 150,
                    color: Colors.black12,
                    child: const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.broken_image,
                              color: Colors.white24, size: 50),
                          SizedBox(height: 10),
                          Text(
                            'Error al cargar imagen',
                            style: TextStyle(color: Colors.white54),
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
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Colors.white.withAlpha(15)),
        ),
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
                expand: true,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppButton(
                label: 'Aprobar',
                icon: Icons.check,
                onPressed: onAprobar,
                expand: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
