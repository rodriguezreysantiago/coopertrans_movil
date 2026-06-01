import 'dart:async';
import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Pantalla "Mapa flota en vivo" del admin.
///
/// Muestra la última posición conocida de TODA la flota (no solo Volvo)
/// según Sitrack — toda la flota tiene Sitrack, así que es la fuente
/// más completa para "dónde está cada tractor ahora". Volvo Vehicle
/// Alerts solo da posición cuando dispara un evento puntual.
///
/// Datos: lee de `SITRACK_POSICIONES` que la Cloud Function
/// `sitrackPosicionPoller` (cron 5 min) actualiza llamando al endpoint
/// `/v2/report` de Sitrack. El doc id es la patente, así que no
/// historizamos — es snapshot.
///
/// UX:
/// - Marker por tractor coloreado según ignición (verde si motor ON,
///   gris si OFF) y frescura del último reporte (rojo si > 1h).
/// - Tap en marker → bottom sheet con datos del tractor + chofer
///   (si está identificado por iButton) + odómetro + link a Maps.
///
/// Modo `embedded`: cuando se renderiza dentro de otra pantalla (ej.
/// el tab "Mapa" del módulo Vista Ejecutiva), pasar `embedded: true`
/// para que se omita el AppScaffold y el título — solo se devuelve el
/// contenido (toolbar + mapa) para que viva en el body del shell padre.
class AdminMapaFlotaScreen extends StatefulWidget {
  /// Si `true`, no envuelve el contenido en `AppScaffold` (sin AppBar
  /// propio). Pensado para embeber dentro de otra pantalla que ya tiene
  /// su scaffold/título. Default false (uso standalone como ruta).
  final bool embedded;

  const AdminMapaFlotaScreen({super.key, this.embedded = false});

  @override
  State<AdminMapaFlotaScreen> createState() => _AdminMapaFlotaScreenState();
}

class _AdminMapaFlotaScreenState extends State<AdminMapaFlotaScreen> {
  // Bahía Blanca centro — operación de Vecchi (fallback si no hay
  // posición persistida en SharedPreferences ni docs en el stream).
  static const _centroFallback = LatLng(-38.7196, -62.2724);
  static const _zoomFallback = 8.0;

  // Centro + zoom efectivos del mapa. Se inicializan con el fallback y
  // se actualizan con la última posición persistida (cargada async en
  // initState) o con auto-fit cuando llegan los primeros markers.
  LatLng _centroInicial = _centroFallback;
  double _zoomInicial = _zoomFallback;

  /// Vista satelital (Mapbox) vs callejera (Carto). Default callejera.
  bool _satelital = false;

  /// Set de excluidos (tanques + sus choferes + testers). Carga async en
  /// initState. Mientras es null no se excluye a nadie (fail-safe).
  ExcluidosSet? _excluidos;

  /// Patente seleccionada desde el panel lateral (resalta su marker +
  /// centra el mapa). null = ninguna.
  String? _seleccionada;

  /// Auto-fit al primer render con docs. Después de la primera vez, no
  /// volvemos a tocar la cámara automáticamente — el admin pan/zoom y
  /// cualquier auto-fit posterior le mataría su contexto visual.
  bool _didInitialFit = false;

  final _mapController = MapController();

  /// Keys de SharedPreferences para persistir centro/zoom entre sesiones.
  static const _prefsKeyLat = 'mapa_flota_last_lat';
  static const _prefsKeyLng = 'mapa_flota_last_lng';
  static const _prefsKeyZoom = 'mapa_flota_last_zoom';

  /// Debounce del save de prefs cuando el usuario pan/zoom — sin debounce
  /// escribiríamos a disco con cada frame del drag.
  Timer? _persistirDebounce;

  @override
  void initState() {
    super.initState();
    _cargarUltimaPosicion();
    // Excluir tanques + sus choferes (combustibles, otra área de Vecchi),
    // igual que el resto de la app. Fail-safe: si falla, no excluye a nadie.
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  @override
  void dispose() {
    _persistirDebounce?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  /// Lee la última posición del mapa de SharedPreferences. Si existe,
  /// la aplica como `_centroInicial`/`_zoomInicial`. Async — el primer
  /// frame puede mostrarse con el fallback y luego se actualiza con
  /// setState cuando llega la posición persistida.
  Future<void> _cargarUltimaPosicion() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lat = prefs.getDouble(_prefsKeyLat);
      final lng = prefs.getDouble(_prefsKeyLng);
      final zoom = prefs.getDouble(_prefsKeyZoom);
      if (lat != null && lng != null && zoom != null && mounted) {
        setState(() {
          _centroInicial = LatLng(lat, lng);
          _zoomInicial = zoom;
        });
      }
    } catch (_) {
      // Silencioso — si SharedPreferences falla, usamos el fallback.
    }
  }

  /// Persiste centro + zoom actual con debounce de 1s. Llamado desde
  /// `onMapEvent` cuando el usuario termina un pan o zoom.
  void _persistirPosicion(LatLng center, double zoom) {
    _persistirDebounce?.cancel();
    _persistirDebounce = Timer(const Duration(seconds: 1), () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setDouble(_prefsKeyLat, center.latitude);
        await prefs.setDouble(_prefsKeyLng, center.longitude);
        await prefs.setDouble(_prefsKeyZoom, zoom);
      } catch (_) {/* silencioso */}
    });
  }

  /// Calcula el bounding box de los markers y aplica fitCamera para que
  /// se vean TODOS con un margen. Si no hay markers, no hace nada.
  void _ajustarVistaATodaLaFlota(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    if (docs.isEmpty) return;
    final puntos = docs
        .map((d) {
          final lat = (d.data()['lat'] as num?)?.toDouble();
          final lng = (d.data()['lng'] as num?)?.toDouble();
          if (lat == null || lng == null) return null;
          return LatLng(lat, lng);
        })
        .whereType<LatLng>()
        .toList();
    if (puntos.isEmpty) return;
    if (puntos.length == 1) {
      // Con 1 solo punto no podemos calcular bounds — centramos con
      // zoom moderado.
      _mapController.move(puntos.first, 13);
      return;
    }
    final bounds = LatLngBounds.fromPoints(puntos);
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: bounds,
        padding: const EdgeInsets.all(50),
      ),
    );
  }

  /// Centra el mapa en la unidad elegida desde el panel lateral y la marca
  /// como seleccionada (para resaltar su marker).
  void _seleccionarUnidad(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    setState(() => _seleccionada = doc.id);
    if (lat != null && lng != null) {
      _mapController.move(LatLng(lat, lng), 14);
    }
  }

  /// Abre el panel de unidades como bottom sheet (mobile, donde no entra el
  /// panel lateral fijo).
  void _abrirPanelMobile(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    DateTime ahora,
  ) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (_) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: _PanelUnidades(
          docs: docs,
          ahora: ahora,
          seleccionada: _seleccionada,
          onSeleccionar: (doc) {
            Navigator.of(context).pop();
            _seleccionarUnidad(doc);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    if (widget.embedded) return body;
    return AppScaffold(title: 'Mapa flota en vivo', body: body);
  }

  Widget _buildBody() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.sitrackPosiciones)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
            child: CircularProgressIndicator(color: AppColors.brand),
          );
        }
        if (snap.hasError) {
          return AppErrorState(
            title: 'No pudimos cargar el mapa',
            subtitle: snap.error.toString(),
          );
        }

        final allDocs = snap.data?.docs ?? const [];
        final ahora = DateTime.now();

        // Unidades visibles: con posición válida y NO excluidas. Los tanques
        // y sus choferes quedan afuera (combustibles, otra área de Vecchi),
        // igual que en todo el resto de la app. Ordenadas por patente
        // ascendente (de menor a mayor) para el panel lateral.
        final visibles = allDocs.where((d) {
          final data = d.data();
          final lat = (data['lat'] as num?)?.toDouble();
          final lng = (data['lng'] as num?)?.toDouble();
          if (lat == null || lng == null) return false;
          final driverDni = (data['driver_dni'] ?? '').toString();
          if (ExcluidosService.esExcluido(_excluidos,
              dni: driverDni, patente: d.id)) {
            return false;
          }
          return true;
        }).toList()
          ..sort((a, b) => a.id.compareTo(b.id));

        // Auto-fit al primer render con datos. Si ya hubo fit previo,
        // respetamos el pan/zoom del usuario.
        if (!_didInitialFit && visibles.isNotEmpty) {
          _didInitialFit = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _ajustarVistaATodaLaFlota(visibles);
          });
        }

        // Layout: panel lateral con la lista de unidades + mapa. En pantallas
        // angostas (mobile) el panel no entra fijo → se abre desde un botón
        // sobre el mapa.
        return LayoutBuilder(
          builder: (lbCtx, constraints) {
            final panelFijo = constraints.maxWidth >= 720;
            final mapa = _Mapa(
              controller: _mapController,
              centroInicial: _centroInicial,
              zoomInicial: _zoomInicial,
              docs: visibles,
              ahora: ahora,
              satelital: _satelital,
              seleccionada: _seleccionada,
              onToggleSatelital: () =>
                  setState(() => _satelital = !_satelital),
              onMarkerTap: (doc) => _abrirDetalle(doc),
              onFitFlota: () => _ajustarVistaATodaLaFlota(visibles),
              onPosicionCambiada: _persistirPosicion,
              onAbrirPanel:
                  panelFijo ? null : () => _abrirPanelMobile(visibles, ahora),
            );
            if (!panelFijo) return mapa;
            return Row(
              children: [
                SizedBox(
                  width: 280,
                  child: _PanelUnidades(
                    docs: visibles,
                    ahora: ahora,
                    seleccionada: _seleccionada,
                    onSeleccionar: _seleccionarUnidad,
                  ),
                ),
                const VerticalDivider(
                    width: 1, color: AppColors.borderSubtle),
                Expanded(child: mapa),
              ],
            );
          },
        );
      },
    );
  }

  void _abrirDetalle(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DetalleSheet(patente: doc.id),
    );
  }
}

// =============================================================================
// PANEL LATERAL — lista de unidades (de menor a mayor patente)
// =============================================================================

/// Panel con la lista de todas las unidades visibles, ordenadas por patente.
/// Tap en una → centra el mapa en ella. Reemplazó a la toolbar de filtros el
/// 2026-06-01 (pedido Santiago: sacar filtros, poner lista lateral).
class _PanelUnidades extends StatefulWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final DateTime ahora;
  final String? seleccionada;
  final ValueChanged<QueryDocumentSnapshot<Map<String, dynamic>>>
      onSeleccionar;

  const _PanelUnidades({
    required this.docs,
    required this.ahora,
    required this.seleccionada,
    required this.onSeleccionar,
  });

  @override
  State<_PanelUnidades> createState() => _PanelUnidadesState();
}

class _PanelUnidadesState extends State<_PanelUnidades> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Filtro client-side por patente o chofer (la lista ya está en memoria).
    final f = _filtro.trim().toUpperCase();
    final filtrados = f.isEmpty
        ? widget.docs
        : widget.docs.where((d) {
            if (d.id.toUpperCase().contains(f)) return true;
            final data = d.data();
            final apellido =
                (data['driver_apellido'] ?? '').toString().toUpperCase();
            final nombre =
                (data['driver_nombre'] ?? '').toString().toUpperCase();
            return apellido.contains(f) || nombre.contains(f);
          }).toList();

    return Container(
      color: AppColors.surface0,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xs),
            child: Row(
              children: [
                const Icon(Icons.local_shipping_outlined,
                    size: 18, color: AppColors.textSecondary),
                const SizedBox(width: AppSpacing.sm),
                Text('UNIDADES (${filtrados.length})',
                    style: AppType.eyebrow
                        .copyWith(color: AppColors.textSecondary)),
              ],
            ),
          ),
          // Buscador por patente o chofer.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.md, 0, AppSpacing.md, AppSpacing.sm),
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _ctrl,
                textCapitalization: TextCapitalization.characters,
                style: AppType.label.copyWith(color: AppColors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search,
                      size: 18, color: AppColors.textTertiary),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: const Icon(Icons.clear,
                              size: 16, color: AppColors.textTertiary),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _filtro = '');
                          },
                        ),
                  hintText: 'Buscar patente o chofer…',
                  hintStyle:
                      AppType.label.copyWith(color: AppColors.textTertiary),
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm, vertical: 0),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
          ),
          const Divider(height: 1, color: AppColors.borderSubtle),
          Expanded(
            child: filtrados.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        widget.docs.isEmpty
                            ? 'Sin unidades con posición.'
                            : 'Sin coincidencias con "$_filtro".',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.textTertiary),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    itemCount: filtrados.length,
                    itemBuilder: (ctx, i) {
                      final d = filtrados[i];
                      return _ItemUnidad(
                        doc: d,
                        ahora: widget.ahora,
                        seleccionada: d.id == widget.seleccionada,
                        onTap: () => widget.onSeleccionar(d),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Un item del panel: dot de estado (motor/frescura/drift) + patente +
/// chofer si está identificado.
class _ItemUnidad extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final DateTime ahora;
  final bool seleccionada;
  final VoidCallback onTap;

  const _ItemUnidad({
    required this.doc,
    required this.ahora,
    required this.seleccionada,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final data = doc.data();
    final ignition = data['ignition'] == true;
    final reportTs = (data['report_date'] as Timestamp?)?.toDate();
    final minStale =
        reportTs == null ? null : ahora.difference(reportTs).inMinutes;
    final tieneDrift = (data['drift_tipo'] ?? '').toString().isNotEmpty;
    final color = _Mapa._colorMarker(
      ignition: ignition,
      minStale: minStale,
      tieneDrift: tieneDrift,
    );

    final apellido = (data['driver_apellido'] ?? '').toString();
    final nombre = (data['driver_nombre'] ?? '').toString();
    final chofer = [apellido, nombre]
        .where((s) => s.isNotEmpty)
        .join(' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');

    return InkWell(
      onTap: onTap,
      child: Container(
        color: seleccionada ? AppColors.brand.withAlpha(30) : null,
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration:
                  BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.id,
                    style: AppType.body.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (chofer.isNotEmpty)
                    Text(
                      chofer,
                      style: AppType.label
                          .copyWith(color: AppColors.textTertiary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (tieneDrift)
              const Icon(Icons.warning_amber,
                  size: 16, color: AppColors.warning),
          ],
        ),
      ),
    );
  }
}

/// Botón flotante tipo "pill" sobre el mapa (toggle satélite / abrir panel).
class _BotonMapa extends StatelessWidget {
  final IconData icono;
  final String label;
  final VoidCallback onTap;
  const _BotonMapa(
      {required this.icono, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surface1,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      elevation: 3,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 16, color: AppColors.textPrimary),
              const SizedBox(width: AppSpacing.xs),
              Text(label,
                  style: AppType.label.copyWith(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// MAPA
// =============================================================================

class _Mapa extends StatelessWidget {
  final MapController controller;
  final LatLng centroInicial;
  final double zoomInicial;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final DateTime ahora;
  final bool satelital;
  final String? seleccionada;
  final VoidCallback onToggleSatelital;
  final ValueChanged<QueryDocumentSnapshot<Map<String, dynamic>>> onMarkerTap;
  final VoidCallback onFitFlota;
  final void Function(LatLng center, double zoom) onPosicionCambiada;

  /// Si no es null, muestra un botón arriba-izquierda para abrir el panel de
  /// unidades (mobile). En desktop el panel es fijo y esto es null.
  final VoidCallback? onAbrirPanel;

  const _Mapa({
    required this.controller,
    required this.centroInicial,
    required this.zoomInicial,
    required this.docs,
    required this.ahora,
    required this.satelital,
    required this.seleccionada,
    required this.onToggleSatelital,
    required this.onMarkerTap,
    required this.onFitFlota,
    required this.onPosicionCambiada,
    required this.onAbrirPanel,
  });

  @override
  Widget build(BuildContext context) {
    // Satélite Mapbox si hay token configurado; si no, cae a callejero
    // (Carto Voyager).
    final usarSatelite = satelital && MapConstants.tieneMapbox;
    return Stack(
      children: [
        FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: centroInicial,
            initialZoom: zoomInicial,
            minZoom: 4,
            maxZoom: 18,
            // Persistir posición cuando el usuario termina un pan/zoom.
            // El debounce vive en el padre — acá solo notificamos.
            onMapEvent: (event) {
              if (event is MapEventMoveEnd ||
                  event is MapEventDoubleTapZoomEnd ||
                  event is MapEventFlingAnimationEnd ||
                  event is MapEventScrollWheelZoom) {
                onPosicionCambiada(event.camera.center, event.camera.zoom);
              }
            },
          ),
          children: [
            // Vista satelital (Mapbox, sin subdomains) o callejera (Carto
            // Voyager, con subdomains a/b/c/d).
            if (usarSatelite)
              TileLayer(
                urlTemplate: MapConstants.tileSatelliteUrl,
                userAgentPackageName: MapConstants.userAgent,
              )
            else
              TileLayer(
                urlTemplate: MapConstants.tileUrl,
                subdomains: MapConstants.tileSubdomains,
                userAgentPackageName: MapConstants.userAgent,
              ),
            // Agrupamos pins muy cerca (radio chico de 25px) para evitar
            // superposición en el mismo predio. A zoom alto se separan.
            MarkerClusterLayerWidget(
              options: MarkerClusterLayerOptions(
                maxClusterRadius: 25,
                size: const Size(38, 38),
                alignment: Alignment.center,
                padding: const EdgeInsets.all(50),
                markers: docs.map((d) => _markerDeDoc(d)).toList(),
                builder: (ctx, markers) => Container(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppColors.brand,
                  ),
                  child: Center(
                    child: Text(
                      AppFormatters.formatearMiles(markers.length),
                      style: AppType.heading
                          .copyWith(color: AppColors.textPrimary),
                    ),
                  ),
                ),
              ),
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                    usarSatelite ? '© Mapbox · © Maxar' : '© OpenStreetMap'),
              ],
            ),
          ],
        ),

        // Botón "abrir panel de unidades" (solo mobile, arriba-izquierda).
        if (onAbrirPanel != null)
          Positioned(
            top: AppSpacing.md,
            left: AppSpacing.md,
            child: _BotonMapa(
              icono: Icons.list,
              label: 'Unidades',
              onTap: onAbrirPanel!,
            ),
          ),

        // Toggle satélite / mapa (arriba-derecha).
        Positioned(
          top: AppSpacing.md,
          right: AppSpacing.md,
          child: _BotonMapa(
            icono: satelital ? Icons.map_outlined : Icons.satellite_alt,
            label: satelital ? 'Mapa' : 'Satélite',
            onTap: onToggleSatelital,
          ),
        ),

        // FAB "centrar en toda la flota". Solo si hay markers visibles.
        if (docs.isNotEmpty)
          Positioned(
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: FloatingActionButton.small(
              heroTag: 'mapa_flota_fit',
              backgroundColor: AppColors.brand,
              foregroundColor: AppColors.textPrimary,
              tooltip: 'Ver toda la flota',
              onPressed: onFitFlota,
              child: const Icon(Icons.crop_free),
            ),
          ),
      ],
    );
  }

  Marker _markerDeDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final esSeleccionada = doc.id == seleccionada;
    final lat = (data['lat'] as num).toDouble();
    final lng = (data['lng'] as num).toDouble();
    final ignition = data['ignition'] == true;
    final reportTs = (data['report_date'] as Timestamp?)?.toDate();
    final minDesdeReporte =
        reportTs == null ? null : ahora.difference(reportTs).inMinutes;
    final tieneDrift = (data['drift_tipo'] ?? '').toString().isNotEmpty;

    // Rumbo + velocidad (Sitrack): si el camión se está moviendo y hay
    // heading, mostramos una flechita rotada arriba del círculo apuntando
    // al rumbo. Si está parado o no hay heading, no la mostramos —
    // visualmente más limpio (rumbo de un camión parado no aporta).
    // Preferimos gps_speed sobre speed (gps_speed es la velocidad medida
    // por GPS, más confiable que la del ECU).
    final headingRaw = data['heading'];
    final speedRaw = data['gps_speed'] ?? data['speed'];
    final heading = headingRaw is num ? headingRaw.toDouble() : null;
    final speed = speedRaw is num ? speedRaw.toDouble() : null;
    // Umbral 5 km/h: filtra "ruido" de GPS en parado (un camión detenido
    // puede reportar 1-3 km/h por imprecisión del GPS).
    final enMovimiento =
        ignition && speed != null && speed > 5 && heading != null;

    final color = _colorMarker(
      ignition: ignition,
      minStale: minDesdeReporte,
      tieneDrift: tieneDrift,
    );

    // Ícono adentro del círculo:
    // - Si se está moviendo: flecha de navegación rotada al heading.
    //   Reemplaza al camión — es el indicador de rumbo más directo,
    //   no asoma "afuera" del círculo (que se camuflaba a zoom bajo).
    // - Si tiene drift: warning_amber (siempre, sobre el rumbo).
    // - Si está parado / motor off: camión.
    //
    // Drift tiene prioridad sobre rumbo — si el chofer físico ≠ asignado,
    // queremos que el admin vea el warning antes que la dirección.
    final IconData iconoMarker;
    final double rotacionMarker;
    if (tieneDrift) {
      iconoMarker = Icons.warning_amber;
      rotacionMarker = 0;
    } else if (enMovimiento) {
      iconoMarker = Icons.navigation;
      // El ícono `navigation` apunta al norte por defecto (cabeza arriba).
      // Sitrack reporta heading en grados con 0=norte, sentido horario,
      // que coincide con la rotación nativa de Transform.rotate.
      rotacionMarker = heading * math.pi / 180;
    } else {
      iconoMarker = Icons.local_shipping;
      rotacionMarker = 0;
    }

    return Marker(
      point: LatLng(lat, lng),
      width: 96,
      height: 54,
      // El conjunto es círculo + etiqueta debajo. Con esta alineación el
      // CENTRO del círculo (a ~18px del top, sobre un alto total de 54)
      // queda anclado a la posición GPS real y la patente cuelga debajo
      // (pedido Santiago 2026-06-01). -0.33 ≈ 18/54 mapeado a [-1,1].
      alignment: const Alignment(0, -0.33),
      child: GestureDetector(
        onTap: () => onMarkerTap(doc),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                // Borde brand grueso si está seleccionada desde el panel;
                // si no, más grueso/contrastado cuando hay drift.
                border: Border.all(
                  color: esSeleccionada
                      ? AppColors.brand
                      : AppColors.textPrimary,
                  width: esSeleccionada ? 4 : (tieneDrift ? 3 : 2),
                ),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.surface0,
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Transform.rotate(
                angle: rotacionMarker,
                child: Icon(
                  iconoMarker,
                  color: AppColors.textPrimary,
                  size: tieneDrift ? 20 : 22,
                ),
              ),
            ),
            const SizedBox(height: 2),
            // Etiqueta con la patente debajo del marker — para identificar
            // cada unidad sin tener que tocarla.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.78),
                borderRadius: BorderRadius.circular(4),
                border: esSeleccionada
                    ? Border.all(color: AppColors.brand, width: 1.5)
                    : null,
              ),
              child: Text(
                doc.id,
                maxLines: 1,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Naranja si tiene drift (chofer físico ≠ asignado). Rojo si > 60 min
  /// sin reportar. Verde si motor ON. Gris si motor OFF.
  /// Drift gana sobre stale, y stale gana sobre ignición.
  static Color _colorMarker({
    required bool ignition,
    required int? minStale,
    required bool tieneDrift,
  }) {
    if (tieneDrift) return AppColors.warning;
    if (minStale != null && minStale > 60) return AppColors.error;
    if (ignition) return AppColors.success;
    return AppColors.textSecondary;
  }
}

// =============================================================================
// SHEET DE DETALLE
// =============================================================================

class _DetalleSheet extends StatelessWidget {
  final String patente;

  const _DetalleSheet({required this.patente});

  @override
  Widget build(BuildContext context) {
    // Stream del doc — antes pasábamos `data` como snapshot estático y
    // si la unidad cambiaba mientras el sheet estaba abierto el admin
    // veía info vieja (velocidad cero, ubicación obsoleta). Con stream
    // los datos se refrescan en vivo.
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.sitrackPosiciones)
          .doc(patente)
          .snapshots(),
      builder: (ctx, snap) {
        final data = snap.data?.data();
        if (data == null) {
          // Loading inicial — sheet vacío con altura mínima para que la
          // animación de apertura no flickeree.
          return Container(
            height: 200,
            decoration: const BoxDecoration(
              color: AppColors.surface2,
              borderRadius: BorderRadius.vertical(
                  top: Radius.circular(AppRadius.lg)),
            ),
            child: const Center(child: CircularProgressIndicator()),
          );
        }
        return _buildContenido(context, data);
      },
    );
  }

  Widget _buildContenido(BuildContext context, Map<String, dynamic> data) {
    final ignition = data['ignition'] == true;
    final speed = (data['speed'] as num?)?.toDouble();
    final gpsSpeed = (data['gps_speed'] as num?)?.toDouble();
    final headingRaw = (data['heading'] as num?)?.toDouble();
    final odometer = (data['odometer'] as num?)?.toDouble();
    final hourmeter = (data['hourmeter'] as num?)?.toDouble();
    final reportTs = (data['report_date'] as Timestamp?)?.toDate();
    final ignitionTs = (data['ignition_date'] as Timestamp?)?.toDate();
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    final location = (data['location'] ?? '').toString();
    final driverDni = (data['driver_dni'] ?? '').toString();
    final driverApellido = (data['driver_apellido'] ?? '').toString();
    final driverNombre = (data['driver_nombre'] ?? '').toString();
    final eventName = (data['event_name'] ?? '').toString();
    final driftTipo = (data['drift_tipo'] ?? '').toString();
    final asignacionDni = (data['asignacion_dni'] ?? '').toString();
    final asignacionNombre = (data['asignacion_nombre'] ?? '').toString();

    // En movimiento: misma lógica que el marker (gps_speed > 5 km/h).
    final speedEfectiva = gpsSpeed ?? speed;
    final enMovimiento = ignition &&
        speedEfectiva != null &&
        speedEfectiva > 5 &&
        headingRaw != null;

    final choferTexto = driverDni.isEmpty
        ? '— (sin identificar)'
        : [driverApellido, driverNombre]
            .where((s) => s.isNotEmpty)
            .join(' ')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .ifEmpty('DNI $driverDni');

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface2,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
        border: Border.all(
          color: ignition
              ? AppColors.success.withAlpha(60)
              : AppColors.textHint,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.textHint,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: Text(
                  patente,
                  style: AppType.title,
                ),
              ),
              _BadgeIgnicion(on: ignition),
            ],
          ),
          if (driftTipo.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.md),
            _DriftBanner(
              tipo: driftTipo,
              sitrackDni: driverDni,
              sitrackApellido: driverApellido,
              asignacionDni: asignacionDni,
              asignacionNombre: asignacionNombre,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          _Fila(
            label: 'Chofer',
            valor: choferTexto,
            icono: Icons.person_outline,
            colorIcono: driverDni.isEmpty ? AppColors.textDisabled : AppColors.success,
          ),
          if (driverDni.isNotEmpty)
            _Fila(label: 'DNI', valor: driverDni),
          _Fila(
            label: 'Velocidad',
            valor: speed == null ? '—' : '${speed.toStringAsFixed(0)} km/h',
            icono: Icons.speed,
          ),
          // Rumbo: solo si está en movimiento. Texto formato "NE (45°)"
          // — cardinal + grados exactos. Helper en `_rumboCardinal`.
          if (enMovimiento)
            _Fila(
              label: 'Rumbo',
              valor:
                  '${_rumboCardinal(headingRaw)} (${headingRaw.toStringAsFixed(0)}°)',
              icono: Icons.navigation,
              colorIcono: AppColors.success,
            ),
          _Fila(
            label: 'Odómetro',
            valor: odometer == null
                ? '—'
                : '${AppFormatters.formatearMiles(odometer.round())} km',
            icono: Icons.straighten,
          ),
          if (hourmeter != null)
            _Fila(
              label: 'Horómetro',
              valor: '${hourmeter.toStringAsFixed(1)} h',
              icono: Icons.access_time,
            ),
          // Telemetría Volvo Connect (combustible, AdBlue, autonomía).
          // Vive en el doc VEHICULOS — no en SITRACK_POSICIONES — porque
          // la pobla `vehiculo_manager.actualizarTelemetria` cuando el
          // admin entra a la pantalla de unidades. Solo aparece si hay
          // dato (las unidades sin Volvo Connect quedan sin estos campos).
          _TelemetriaVolvoFila(patente: patente),
          _Fila(
            label: 'Último reporte',
            valor: AppFormatters.formatearFechaHoraCorta(reportTs),
            icono: Icons.update,
          ),
          if (ignitionTs != null)
            _Fila(
              label: 'Ignición desde',
              valor: AppFormatters.formatearFechaHoraCorta(ignitionTs),
            ),
          if (eventName.isNotEmpty)
            _Fila(
              label: 'Evento',
              valor: eventName,
              icono: Icons.bolt,
            ),
          if (location.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            _Fila(
              label: 'Dirección',
              valor: location,
              icono: Icons.place_outlined,
              esLargo: true,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: AppButton.ghost(
                  label: 'Cerrar',
                  expand: true,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              if (lat != null && lng != null) ...[
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: AppButton(
                    label: 'Ver en Maps',
                    icon: Icons.open_in_new,
                    expand: true,
                    onPressed: () => _abrirMaps(context, lat, lng),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// Abre Google Maps en una ventana externa. Si el launch falla (raro
  /// pero pasa con browser desconfigurado o Android sin queries en
  /// manifest), notificamos al admin con SnackBar — antes fallaba
  /// silencioso y el botón parecía roto.
  Future<void> _abrirMaps(
      BuildContext context, double lat, double lng) async {
    final messenger = ScaffoldMessenger.of(context);
    final uri = Uri.parse('https://www.google.com/maps?q=$lat,$lng');
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) {
        messenger.showSnackBar(const SnackBar(
          content:
              Text('No se pudo abrir Google Maps en este dispositivo.'),
        ));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(
        content: Text('Error abriendo Maps: $e'),
      ));
    }
  }

  /// Convierte heading en grados (0=N, 90=E, 180=S, 270=O) a sentido
  /// cardinal de 8 direcciones (N, NE, E, SE, S, SO, O, NO).
  static String _rumboCardinal(double heading) {
    const cardinales = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];
    // Normalizar a [0, 360) por si vienen valores fuera de rango.
    final h = ((heading % 360) + 360) % 360;
    // Cada cardinal cubre 45° centrado en su ángulo. +22.5 desplaza
    // los bordes para que 0..22.5 sea N, 22.5..67.5 sea NE, etc.
    final idx = ((h + 22.5) / 45).floor() % 8;
    return cardinales[idx];
  }
}

class _Fila extends StatelessWidget {
  final String label;
  final String valor;
  final IconData? icono;
  final Color? colorIcono;
  final bool esLargo;

  const _Fila({
    required this.label,
    required this.valor,
    this.icono,
    this.colorIcono,
    this.esLargo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment:
            esLargo ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 14, color: colorIcono ?? AppColors.textDisabled),
            const SizedBox(width: AppSpacing.xs),
          ] else ...[
            const SizedBox(width: AppSpacing.xl),
          ],
          SizedBox(
            width: 90,
            child: Text(label, style: AppType.label),
          ),
          Expanded(
            child: Text(
              valor,
              style: AppType.body.copyWith(color: AppColors.textPrimary),
              maxLines: esLargo ? 3 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BadgeIgnicion extends StatelessWidget {
  final bool on;

  const _BadgeIgnicion({required this.on});

  @override
  Widget build(BuildContext context) {
    final color = on ? AppColors.success : AppColors.textTertiary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        on ? 'EN MARCHA' : 'APAGADO',
        style: AppType.eyebrow.copyWith(color: color),
      ),
    );
  }
}

extension _StringIfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Bloque de telemetría Volvo Connect (combustible / AdBlue / autonomía)
/// para una patente. Lee de VEHICULOS/{patente} una sola vez al abrir
/// el sheet — no necesita stream porque los valores cambian con baja
/// frecuencia (cron cada ~6h o sync manual desde la pantalla de
/// unidades). Si la unidad no tiene Volvo Connect (campos ausentes),
/// el widget no renderiza nada — silencioso.
///
/// **Stateful con Future cacheado** (antes era StatelessWidget con el
/// `.get()` dentro de FutureBuilder, lo que re-fetcheaba en cada
/// rebuild del sheet — costos Firestore extra). Ahora la query corre
/// una sola vez en initState.
class _TelemetriaVolvoFila extends StatefulWidget {
  final String patente;
  const _TelemetriaVolvoFila({required this.patente});

  @override
  State<_TelemetriaVolvoFila> createState() => _TelemetriaVolvoFilaState();
}

class _TelemetriaVolvoFilaState extends State<_TelemetriaVolvoFila> {
  late final Future<DocumentSnapshot<Map<String, dynamic>>> _futuro;

  @override
  void initState() {
    super.initState();
    _futuro = FirebaseFirestore.instance
        .collection(AppCollections.vehiculos)
        .doc(widget.patente)
        .get();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: _futuro,
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data?.data() == null) {
          return const SizedBox.shrink();
        }
        final data = snap.data!.data()!;
        final combustible = (data['NIVEL_COMBUSTIBLE'] as num?)?.toDouble();
        final adblue = (data['NIVEL_ADBLUE'] as num?)?.toDouble();
        final autonomia = (data['AUTONOMIA_KM'] as num?)?.toDouble();

        if (combustible == null && adblue == null && autonomia == null) {
          // Unidad sin Volvo Connect → no mostramos placeholder.
          return const SizedBox.shrink();
        }

        return Column(
          children: [
            if (combustible != null)
              _Fila(
                label: 'Combustible',
                valor: '${combustible.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.local_gas_station,
                colorIcono: _colorPorcentaje(combustible),
              ),
            if (adblue != null)
              _Fila(
                label: 'AdBlue',
                valor: '${adblue.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.water_drop_outlined,
                colorIcono: _colorPorcentaje(adblue),
              ),
            if (autonomia != null)
              _Fila(
                label: 'Autonomía',
                valor: '${autonomia.toStringAsFixed(0)} km',
                icono: Icons.timeline,
              ),
          ],
        );
      },
    );
  }

  /// Verde >50%, naranja 20-50%, rojo <20%. Mismo criterio que el
  /// listado de unidades.
  static Color _colorPorcentaje(double pct) {
    if (pct > 50) return AppColors.success;
    if (pct >= 20) return AppColors.warning;
    return AppColors.error;
  }
}

/// Banner naranja en el sheet del tractor cuando el chofer físico
/// (Sitrack, vía iButton) no coincide con la asignación activa del
/// sistema. El cron `sitrackPosicionPoller` setea `drift_tipo` con
/// uno de tres valores que determinan el copy mostrado.
class _DriftBanner extends StatelessWidget {
  final String tipo;
  final String sitrackDni;
  final String sitrackApellido;
  final String asignacionDni;
  final String asignacionNombre;

  const _DriftBanner({
    required this.tipo,
    required this.sitrackDni,
    required this.sitrackApellido,
    required this.asignacionDni,
    required this.asignacionNombre,
  });

  @override
  Widget build(BuildContext context) {
    String titulo;
    String detalle;
    switch (tipo) {
      case 'CHOFER_DISTINTO':
        titulo = 'Chofer distinto al asignado';
        final fisico = sitrackApellido.isNotEmpty
            ? '$sitrackApellido (DNI $sitrackDni)'
            : 'DNI $sitrackDni';
        final asignado = asignacionNombre.isNotEmpty
            ? '$asignacionNombre (DNI $asignacionDni)'
            : 'DNI $asignacionDni';
        detalle = 'Sistema: $asignado.\nFísico (iButton): $fisico.';
        break;
      case 'SIN_ASIGNACION':
        final fisico = sitrackApellido.isNotEmpty
            ? '$sitrackApellido (DNI $sitrackDni)'
            : 'DNI $sitrackDni';
        titulo = 'Manejando sin estar asignado';
        detalle = 'El tractor no tiene asignación activa, pero $fisico '
            'está identificado en él via iButton.';
        break;
      case 'CHOFER_NO_IDENTIFICADO':
        final asignado = asignacionNombre.isNotEmpty
            ? '$asignacionNombre (DNI $asignacionDni)'
            : 'DNI $asignacionDni';
        titulo = 'Chofer no se identificó';
        detalle = 'Sistema asignado: $asignado.\n'
            'El motor está encendido pero nadie pasó el iButton.';
        break;
      default:
        titulo = 'Inconsistencia detectada';
        detalle = 'Tipo: $tipo';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(30),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.warning.withAlpha(120)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber,
              color: AppColors.warning, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: AppType.label.copyWith(color: AppColors.warning, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  detalle,
                  style: AppType.label.copyWith(color: AppColors.textPrimary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
