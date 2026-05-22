import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../widgets/mantenimiento_badge.dart';
import 'admin_mantenimiento_detalle_screen.dart';

// Modelos privados (_FuenteServiceDistance enum, _ResolucionServiceDistance,
// _Resumen) y widgets (_TractorCard, _BarraResumen, _Chip) extraidos para
// mantener navegable el screen principal. Comparten privacidad via `part of`.
part 'admin_mantenimiento_widgets.dart';

/// Pantalla de mantenimiento preventivo.
///
/// Lista los TRACTORES ordenados por urgencia de service (vencidos
/// primero, después por menor `SERVICE_DISTANCE_KM`). Los datos
/// vienen de la colección `VEHICULOS`, donde `SERVICE_DISTANCE_KM`
/// se actualiza automáticamente por el `AutoSyncService` cada vez
/// que sincroniza con Volvo.
///
/// **Ordenamiento client-side** (no orderBy Firestore): la flota es
/// chica (<100 tractores) y evitar el índice compuesto
/// `TIPO + SERVICE_DISTANCE_KM` simplifica la rule de seguridad.
///
/// **Wrapper público** para abrir desde otros features (ej. CommandPalette
/// o el panel admin).
Future<void> abrirMantenimientoPreventivo(BuildContext context) async {
  await Navigator.pushNamed(context, AppRoutes.adminMantenimiento);
}

class AdminMantenimientoScreen extends StatefulWidget {
  const AdminMantenimientoScreen({super.key});

  @override
  State<AdminMantenimientoScreen> createState() =>
      _AdminMantenimientoScreenState();
}

class _AdminMantenimientoScreenState extends State<AdminMantenimientoScreen> {
  late final Stream<QuerySnapshot> _tractoresStream;
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  /// Filtro por estado de mantenimiento. null = sin filtro (mostrar todos).
  /// Lo setean/limpian los chips de _BarraResumen via tap toggle.
  MantenimientoEstado? _filtroEstado;

  @override
  void initState() {
    super.initState();
    // Solo TRACTORES — los enganches no tienen telemetría Volvo (no
    // tienen motor / VIN registrado en Volvo Connect).
    _tractoresStream = FirebaseFirestore.instance
        .collection(AppCollections.vehiculos)
        .where('TIPO', isEqualTo: AppTiposVehiculo.tractor)
        .snapshots();

    _searchCtl.addListener(() {
      if (!mounted) return;
      setState(() => _query = _searchCtl.text.toUpperCase().trim());
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mantenimiento preventivo',
      body: StreamBuilder<QuerySnapshot>(
        stream: _tractoresStream,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting &&
              !snap.hasData) {
            return const AppLoadingState();
          }
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar la flota',
              subtitle: snap.error.toString(),
            );
          }

          // Soft-delete: tractores dados de baja se excluyen del
          // listado de mantenimiento (no se les debe avisar service).
          final docs = (snap.data?.docs ?? []).where((d) {
            final data = d.data() as Map<String, dynamic>;
            return AppActivo.esActivo(data);
          }).toList();

          // Sort alfabético por patente (doc.id). Más predecible para el
          // admin que ya conoce las patentes de memoria. Los chips del
          // resumen siguen mostrando el conteo por urgencia, así que la
          // info crítica (cuántos vencidos hay) sigue visible arriba.
          final sorted = [...docs]
            ..sort((a, b) => a.id.compareTo(b.id));

          // Filtros encadenados: primero por search (patente/marca/modelo),
          // despues por estado seleccionado en los chips. _filtroEstado
          // null = no filtra. Los chips de _BarraResumen siguen mostrando
          // los conteos GLOBALES (calculados sobre `sorted`) para que el
          // admin sepa cuantos hay en cada estado aunque tenga otro filtro
          // activo y pueda saltar de uno a otro.
          final filtrados = sorted.where((doc) {
            if (_query.isEmpty) return true;
            final data = doc.data() as Map<String, dynamic>;
            final hay = '${doc.id} '
                    '${data['MARCA'] ?? ''} '
                    '${data['MODELO'] ?? ''}'
                .toUpperCase();
            return hay.contains(_query);
          }).where((doc) {
            if (_filtroEstado == null) return true;
            final d = doc.data() as Map<String, dynamic>;
            final servicio = _resolverServiceDistance(d);
            return AppMantenimiento.clasificar(servicio.km) ==
                _filtroEstado;
          }).toList();

          // Resumen agregado: cuántos vencidos / urgentes / etc.
          final resumen = _Resumen.from(sorted);

          if (docs.isEmpty) {
            return const AppEmptyState(
              title: 'Sin tractores cargados',
              subtitle:
                  'Cuando agregues TRACTORES con VIN, su mantenimiento aparecerá acá.',
              icon: Icons.local_shipping_outlined,
            );
          }

          return Column(
            children: [
              _BarraResumen(
                resumen: resumen,
                filtroActivo: _filtroEstado,
                onSeleccionar: (estado) {
                  setState(() {
                    // Tap mismo estado = limpiar; tap distinto = cambia.
                    _filtroEstado =
                        (_filtroEstado == estado) ? null : estado;
                  });
                },
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: TextField(
                  controller: _searchCtl,
                  decoration: const InputDecoration(
                    hintText: 'Buscar patente, marca o modelo...',
                    prefixIcon: Icon(Icons.search, color: Colors.white38),
                    isDense: true,
                  ),
                ),
              ),
              Expanded(
                child: filtrados.isEmpty
                    ? const AppEmptyState(
                        title: 'No se encontraron coincidencias',
                        subtitle: 'Probá con otro término.',
                        icon: Icons.search_off,
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(10, 4, 10, 80),
                        itemCount: filtrados.length,
                        itemBuilder: (ctx, idx) =>
                            _TractorCard(doc: filtrados[idx]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

