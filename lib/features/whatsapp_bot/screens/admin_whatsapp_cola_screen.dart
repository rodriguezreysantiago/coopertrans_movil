import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/whatsapp_cola_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
// 9 widgets visuales (resumen contadores, item de cola, badge estado,
// detalle sheet, filas de dato, etc) extraidos para mantener navegable
// este screen. Comparten privacidad via `part of`.
part 'admin_whatsapp_cola_widgets.dart';

/// Pantalla "Cola de WhatsApp" — panel del admin para ver el estado
/// de los mensajes encolados al bot.
///
/// Cada doc se muestra con su estado (PENDIENTE / PROCESANDO / ENVIADO
/// / ERROR), número, mensaje (truncado) y timestamp de encolado. Las
/// filas con error tienen botón "REINTENTAR" que vuelve el estado a
/// PENDIENTE para que el bot lo levante de nuevo.
///
/// El stream es `orderBy(encolado_en, desc).limit(100)` — para una
/// flota chica esto cubre semanas de avisos. Si crece, se puede
/// agregar paginación.
///
/// **Deep-link**: el dashboard "Estado del Bot" abre esta pantalla con
/// `initialFilter` seteado en uno de los estados (PENDIENTE, ERROR,
/// etc.) para que el admin aterrice ya filtrado en lo que le importa
/// (ej. "ver con error").
class AdminWhatsAppColaScreen extends StatefulWidget {
  /// Estado precargado al abrir la pantalla. Si es null, no filtra
  /// (muestra todos los estados). Valores típicos: 'PENDIENTE',
  /// 'PROCESANDO', 'ENVIADO', 'ERROR'.
  final String? initialFilter;

  const AdminWhatsAppColaScreen({super.key, this.initialFilter});

  @override
  State<AdminWhatsAppColaScreen> createState() =>
      _AdminWhatsAppColaScreenState();
}

class _AdminWhatsAppColaScreenState extends State<AdminWhatsAppColaScreen> {
  final WhatsAppColaService _service = WhatsAppColaService();

  /// Estado actual del filtro. Inicializado desde `widget.initialFilter`
  /// y modificable desde la fila de chips de filtro.
  String? _filtroEstado;

  /// Texto de búsqueda free-form (M2, 2026-05-24). Se aplica
  /// client-side sobre los docs ya filtrados por estado, matcheando
  /// contra teléfono, mensaje, origen y destinatario_id (DNI).
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _filtroEstado = widget.initialFilter;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Filtra los docs por el query actual (case-insensitive, substring).
  /// Si `_query` está vacío, devuelve la lista tal cual.
  List<QueryDocumentSnapshot> _filtrarPorQuery(
      List<QueryDocumentSnapshot> docs) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return docs;
    return docs.where((doc) {
      final m = doc.data() as Map<String, dynamic>? ?? const {};
      bool contiene(dynamic v) =>
          v != null && v.toString().toLowerCase().contains(q);
      return contiene(m['telefono']) ||
          contiene(m['mensaje']) ||
          contiene(m['origen']) ||
          contiene(m['destinatario_id']) ||
          contiene(m['destinatario_coleccion']) ||
          contiene(m['alert_patente']);
    }).toList();
  }

  Future<void> _reintentar(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _service.reintentar(id);
      AppFeedback.successOn(messenger, 'Marcado para reintento.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo reintentar el mensaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Future<void> _eliminar(String id) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await AppConfirmDialog.show(
      context,
      title: '¿Eliminar de la cola?',
      message:
          'El mensaje se borra del historial. Si todavía no se envió, no se va a enviar.',
      confirmLabel: 'ELIMINAR',
      destructive: true,
      icon: Icons.delete_outline,
    );
    if (ok != true) return;
    try {
      await _service.eliminar(id);
      AppFeedback.successOn(messenger, 'Mensaje eliminado.');
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar el mensaje. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Cola de WhatsApp',
      body: StreamBuilder<QuerySnapshot>(
        // Filtro server-side (Santiago 2026-05-19): si hay estado
        // activo, el query trae solo docs con ese estado para que
        // los conteos del header coincidan con el listado. Antes el
        // filtro era client-side sobre los últimos 100 docs y los
        // mensajes en posiciones más antiguas no aparecían aunque
        // el contador sí los hubiese visto.
        stream: _service.streamCola(estado: _filtroEstado),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(subtitle: snap.error.toString());
          }
          if (!snap.hasData) return const AppLoadingState();
          final docs = snap.data!.docs;
          // Listado vacío total → "No hay mensajes en cola" solo
          // cuando NO hay filtro activo. Con filtro activo se muestra
          // el mensaje "Sin mensajes con estado X" más abajo.
          if (docs.isEmpty && _filtroEstado == null) {
            return const AppEmptyState(
              icon: Icons.smart_toy_outlined,
              title: 'No hay mensajes en cola',
              subtitle:
                  'Cuando encoles un aviso desde la auditoría de vencimientos, aparece acá.',
            );
          }
          final filtrados = _filtrarPorQuery(docs);
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 80),
            children: [
              _ResumenContador(
                filtroActivo: _filtroEstado,
                onTapEstado: (estado) {
                  // Tap a un chip ya activo lo desactiva (toggle).
                  setState(() {
                    _filtroEstado = (_filtroEstado == estado) ? null : estado;
                  });
                },
              ),
              const SizedBox(height: AppSpacing.sm),
              // Búsqueda free-form (M2, 2026-05-24): DNI / patente /
              // teléfono / origen / texto. Útil cuando un chofer reclama
              // "no me llegó X" y hay que ver qué pasó con el mensaje.
              TextField(
                controller: _searchCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search,
                      color: Colors.white54, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear,
                              color: Colors.white54, size: 18),
                          onPressed: () {
                            _searchCtrl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  hintText: 'Buscar DNI / patente / teléfono / origen / texto',
                  hintStyle: const TextStyle(
                      color: Colors.white38, fontSize: 12),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 10),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
              const SizedBox(height: AppSpacing.sm),
              if (filtrados.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Center(
                    child: Text(
                      _query.isNotEmpty
                          ? 'Sin coincidencias para "$_query"'
                          : 'Sin mensajes con estado "${_filtroEstado ?? ''}"',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
                )
              else
                ...filtrados.map((doc) => _ItemCola(
                      doc: doc,
                      onReintentar: () => _reintentar(doc.id),
                      onEliminar: () => _eliminar(doc.id),
                      onTap: () => _mostrarDetalle(context, doc),
                    )),
            ],
          );
        },
      ),
    );
  }

  /// Abre un BottomSheet con el detalle completo del item: mensaje sin
  /// truncar, items agrupados (si los hay), todos los timestamps,
  /// origen, error completo, intentos. Reemplaza al tap por defecto que
  /// no hacía nada — ahora el item es la "puerta de entrada" al detalle.
  void _mostrarDetalle(BuildContext context, QueryDocumentSnapshot doc) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sCtx) => _DetalleColaSheet(doc: doc),
    );
  }
}

