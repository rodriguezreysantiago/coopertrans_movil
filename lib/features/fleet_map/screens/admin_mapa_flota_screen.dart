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
/// UX (refactor Núcleo · jun 2026):
/// - Desktop (≥1024px): 3 columnas — sidebar de unidades (320) │ mapa │
///   panel de detalle de la seleccionada (340). El tap en un marker o en
///   la lista selecciona la unidad y el panel derecho se actualiza en
///   vivo (StreamBuilder del doc).
/// - Tablet (720–1024px): sidebar (320) + mapa; el detalle abre como sheet.
/// - Mobile (<720px): mapa full + botón para abrir la lista (sheet) +
///   detalle como sheet.
///
/// Marker por tractor coloreado según ignición (verde si motor ON,
/// gris si OFF), frescura del último reporte (rojo si > 1h) y drift
/// (naranja si el chofer físico ≠ asignado).
///
/// Modo `embedded`: cuando se renderiza dentro de otra pantalla (ej.
/// el tab "Mapa" del módulo Vista Ejecutiva, o el AdminShell), pasar
/// `embedded: true` para que se omita el AppScaffold y el título — solo
/// se devuelve el contenido para que viva en el body del shell padre.
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

  /// Vista satelital (Mapbox satellite-streets) vs callejera (Carto).
  /// **Default SATELITAL** (Santiago 2026-06-10): el mapa abre en satélite
  /// — se identifican silos/galpones/accesos físicos. El toggle del mapa
  /// vuelve a la vista callejera. Requiere token Mapbox (embebido en
  /// `MapConstants`); sin token, `_Mapa` cae a callejero igual.
  bool _satelital = true;

  /// Set de excluidos (tanques + sus choferes + testers). Carga async en
  /// initState. Mientras es null no se excluye a nadie (fail-safe).
  ExcluidosSet? _excluidos;

  /// Patente seleccionada desde el panel lateral (resalta su marker +
  /// centra el mapa). null = ninguna.
  String? _seleccionada;

  /// Panel de detalle (columna derecha, desktop ≥1024) colapsado para
  /// ganar ancho de mapa (Santiago 2026-06-10). Lo togglea un botón del
  /// mapa. En memoria (no persiste), default visible; al elegir una
  /// unidad se reabre solo.
  bool _detalleColapsado = false;

  /// Auto-fit al primer render con docs. Después de la primera vez, no
  /// volvemos a tocar la cámara automáticamente — el admin pan/zoom y
  /// cualquier auto-fit posterior le mataría su contexto visual.
  bool _didInitialFit = false;

  final _mapController = MapController();

  /// Stream de posiciones CACHEADO. Crítico: antes se creaba inline en
  /// `_buildBody()`, así que CADA setState (ej. seleccionar una unidad,
  /// togglear satélite o colapsar el panel) generaba un stream nuevo → el
  /// StreamBuilder se re-suscribía, volvía a `waiting` y RE-MONTABA todo el
  /// subárbol, perdiendo el scroll de la lista lateral (Santiago 2026-06-10:
  /// "selecciono una unidad y me vuelve al principio de la lista"). Cacheado,
  /// el subárbol se preserva. Mismo patrón que la lista de Viajes
  /// (auditoría 2026-05-30).
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _posicionesStream;

  /// flutter_map dispara `onMapReady` cuando el mapa terminó su primer layout
  /// y el TileLayer ya puede pedir tiles. Si encuadramos la cámara (fitCamera)
  /// ANTES de eso, el mapa mueve la vista pero NO carga los tiles → queda gris
  /// hasta que el usuario mueve a mano (auditoría 2026-06). Por eso diferimos
  /// el primer encuadre hasta que el mapa avise que está listo.
  bool _mapaListo = false;
  List<QueryDocumentSnapshot<Map<String, dynamic>>>? _fitPendiente;

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
    _posicionesStream = FirebaseFirestore.instance
        .collection(AppCollections.sitrackPosiciones)
        .snapshots();
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

  /// flutter_map → `onMapReady`: el mapa ya puede recibir comandos del
  /// controller y el TileLayer ya carga. Ejecuta el encuadre inicial que
  /// quedó pendiente (si los datos llegaron antes de que el mapa estuviera
  /// listo). Sin esto, el fit temprano dejaba el mapa gris hasta mover a mano.
  void _onMapaListo() {
    _mapaListo = true;
    final pendiente = _fitPendiente;
    if (pendiente != null) {
      _fitPendiente = null;
      _ajustarVistaATodaLaFlota(pendiente);
    }
  }

  /// Centra el mapa en la unidad elegida desde el panel lateral y la marca
  /// como seleccionada (para resaltar su marker).
  void _seleccionarUnidad(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    setState(() {
      _seleccionada = doc.id;
      // Si el admin eligió una unidad, quiere verla: reabrimos el panel
      // aunque lo hubiera colapsado.
      _detalleColapsado = false;
    });
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
      backgroundColor: context.colors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
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
    // Stream cacheado en initState (NO recrear acá — ver `_posicionesStream`).
    final stream = _posicionesStream;

    // AppOfflineBanner: si el stream tarda en emitir el primer evento,
    // muestra "Conexión lenta" arriba sin tapar el contenido.
    return AppOfflineBanner<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            // Skeleton con la forma del sidebar mientras carga — se lee
            // como "viene" en lugar de "trabado".
            return LayoutBuilder(
              builder: (lbCtx, constraints) {
                final c = lbCtx.colors;
                if (constraints.maxWidth < 720) {
                  return const Padding(
                    padding: EdgeInsets.only(top: AppSpacing.lg),
                    child: AppSkeletonList(count: 6, conAvatar: false),
                  );
                }
                return Row(
                  children: [
                    Container(
                      width: 320,
                      color: c.surface1,
                      child: const Padding(
                        padding: EdgeInsets.only(top: AppSpacing.lg),
                        child: AppSkeletonList(count: 8, conAvatar: false),
                      ),
                    ),
                    const AppHairline(vertical: true),
                    Expanded(child: ColoredBox(color: c.surface1)),
                  ],
                );
              },
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
            if (_mapaListo) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _ajustarVistaATodaLaFlota(visibles);
              });
            } else {
              // El mapa aún no terminó de inicializar: guardamos el encuadre
              // para que lo ejecute `_onMapaListo`. Hacerlo ahora movería la
              // cámara pero dejaría los tiles sin cargar (mapa gris).
              _fitPendiente = visibles;
            }
          }

          // Layout responsive:
          // - ≥1024: sidebar (320) + mapa + detalle (340). El detalle vive
          //   inline y reacciona a la selección.
          // - 720–1024: sidebar (320) + mapa; detalle como sheet.
          // - <720: mapa full + botón "Unidades" (sheet) + detalle sheet.
          return LayoutBuilder(
            builder: (lbCtx, constraints) {
              final w = constraints.maxWidth;
              final panelFijo = w >= 720;
              final detalleFijo = w >= 1024;

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
                // Con panel de detalle inline el tap selecciona (el panel
                // derecho se actualiza). Sin panel inline, abre el sheet.
                onMarkerTap: detalleFijo ? _seleccionarUnidad : _abrirDetalle,
                onFitFlota: () => _ajustarVistaATodaLaFlota(visibles),
                onPosicionCambiada: _persistirPosicion,
                onMapaListo: _onMapaListo,
                onAbrirPanel: panelFijo
                    ? null
                    : () => _abrirPanelMobile(visibles, ahora),
                // Toggle del panel de detalle: solo aplica en desktop ≥1024
                // (donde el panel es inline). Null en tablet/mobile.
                onToggleDetalle: detalleFijo
                    ? () => setState(
                        () => _detalleColapsado = !_detalleColapsado)
                    : null,
                detalleColapsado: _detalleColapsado,
              );

              if (!panelFijo) return mapa;

              final c = lbCtx.colors;
              return Row(
                children: [
                  SizedBox(
                    width: 320,
                    child: _PanelUnidades(
                      docs: visibles,
                      ahora: ahora,
                      seleccionada: _seleccionada,
                      onSeleccionar: _seleccionarUnidad,
                    ),
                  ),
                  AppHairline(vertical: true, color: c.border),
                  Expanded(child: mapa),
                  // Panel de detalle inline: solo desktop ≥1024 y si NO está
                  // colapsado (botón del mapa). Colapsado → el mapa se
                  // expande a todo el ancho restante.
                  if (detalleFijo && !_detalleColapsado) ...[
                    AppHairline(vertical: true, color: c.border),
                    SizedBox(
                      width: 340,
                      child: _PanelDetalle(
                        patente: _seleccionada,
                        ahora: ahora,
                        onAbrirMaps: _abrirMapsDesdePanel,
                      ),
                    ),
                  ],
                ],
              );
            },
          );
        },
      ),
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

  /// Abre Google Maps desde el panel inline de detalle. Reusa la misma
  /// lógica de launch que el sheet (`_DetalleSheet._abrirMaps`).
  Future<void> _abrirMapsDesdePanel(double lat, double lng) =>
      _DetalleSheet.abrirMaps(context, lat, lng);
}

// =============================================================================
// PANEL LATERAL — lista de unidades (de menor a mayor patente)
// =============================================================================

/// Panel con la lista de todas las unidades visibles, ordenadas por patente.
/// Tap en una → centra el mapa en ella. Estilo Núcleo: eyebrow + hero
/// "ACTIVAS · n/total", breakdown en cajitas mono, buscador, lista con
/// AppDot semántico + AppBadge sm de estado + AppHairline entre filas.
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
    final c = context.colors;

    // Filtro client-side por patente o chofer (la lista ya está en memoria).
    final f = _filtro.trim().toUpperCase();
    final filtrados = widget.docs.where((d) {
      // Filtro por texto (patente o chofer).
      if (f.isEmpty) return true;
      if (d.id.toUpperCase().contains(f)) return true;
      final data = d.data();
      final apellido = (data['driver_apellido'] ?? '').toString().toUpperCase();
      final nombre = (data['driver_nombre'] ?? '').toString().toUpperCase();
      return apellido.contains(f) || nombre.contains(f);
    }).toList();

    // Conteo por estado sobre TODAS las unidades visibles (no las filtradas
    // por búsqueda) para el hero del panel — patrón del prototipo (Flota).
    var enMarcha = 0, detenidas = 0, sinSenal = 0;
    for (final d in widget.docs) {
      final data = d.data();
      final ignition = data['ignition'] == true;
      final reportTs = (data['report_date'] as Timestamp?)?.toDate();
      final minStale = reportTs == null
          ? null
          : widget.ahora.difference(reportTs).inMinutes;
      if (minStale != null && minStale > 60) {
        sinSenal++;
      } else if (ignition) {
        enMarcha++;
      } else {
        detenidas++;
      }
    }
    final total = widget.docs.length;
    final activas = enMarcha; // "activas" = motor en marcha + reporte fresco.

    return Container(
      color: c.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero: eyebrow + hero number "activas / total" + breakdown.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Activas'),
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      '$activas',
                      style: AppType.h2.copyWith(
                        color: c.text,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('de $total', style: AppType.monoSm),
                  ],
                ),
                const SizedBox(height: AppSpacing.mdDense),
                Row(
                  children: [
                    _EstadoCajita(
                        valor: enMarcha, label: 'En ruta', color: c.brand),
                    const SizedBox(width: 4),
                    _EstadoCajita(
                        valor: detenidas,
                        label: 'Detenidas',
                        color: c.textMuted),
                    const SizedBox(width: 4),
                    _EstadoCajita(
                        valor: sinSenal, label: 'Sin señal', color: c.warning),
                  ],
                ),
              ],
            ),
          ),
          const AppHairline(),
          // Buscador por patente o chofer.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.md),
            child: SizedBox(
              height: 38,
              child: TextField(
                controller: _ctrl,
                textCapitalization: TextCapitalization.characters,
                style: AppType.label.copyWith(color: c.text),
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon:
                      Icon(Icons.search, size: 16, color: c.textMuted),
                  prefixIconConstraints: const BoxConstraints(
                      minWidth: 34, minHeight: 34),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          padding: EdgeInsets.zero,
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(),
                          icon: Icon(Icons.clear, size: 15, color: c.textMuted),
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _filtro = '');
                          },
                        ),
                  hintText: 'Buscar unidad…',
                  hintStyle: AppType.label.copyWith(color: c.textMuted),
                  filled: true,
                  fillColor: c.surface2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(color: c.border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(color: c.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    borderSide: BorderSide(color: c.borderFocus),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
          ),
          const AppHairline(),
          Expanded(
            child: filtrados.isEmpty
                ? AppEmptyState(
                    icon: Icons.local_shipping_outlined,
                    title: widget.docs.isEmpty
                        ? 'Sin unidades con posición'
                        : 'Sin coincidencias',
                    subtitle: widget.docs.isEmpty
                        ? 'Ninguna unidad reportó posición todavía.'
                        : _filtro.isNotEmpty
                            ? 'No hay unidades para "$_filtro".'
                            : 'No hay unidades en este estado.',
                  )
                : ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                    itemCount: filtrados.length,
                    separatorBuilder: (_, __) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xl),
                      child: AppHairline(color: c.border),
                    ),
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

/// Un item del panel: AppDot semántico (motor/frescura/drift) + patente
/// (mono) + AppBadge sm de estado + chofer + velocidad a la derecha.
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
    final c = context.colors;
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

    // Velocidad para la columna derecha (gps_speed preferido, igual que
    // el marker). Solo se muestra si el motor está ON y hay valor.
    final speedRaw = data['gps_speed'] ?? data['speed'];
    final speed = speedRaw is num ? speedRaw.toDouble() : null;
    final muestraVel = ignition && speed != null && speed > 0;

    // Etiqueta corta de estado (ON / IDLE / STP / TLR-style) — derivada de
    // los mismos datos que el color, sin inventar campos.
    final String estadoLabel;
    if (tieneDrift) {
      estadoLabel = 'DRIFT';
    } else if (minStale != null && minStale > 60) {
      estadoLabel = 'S/SEÑAL';
    } else if (ignition) {
      estadoLabel = muestraVel ? 'ON' : 'STP';
    } else {
      estadoLabel = 'IDLE';
    }

    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: seleccionada ? c.surface2 : null,
          border: Border(
            left: BorderSide(
              color: seleccionada ? c.brand : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: AppDot(color, size: 8, glow: seleccionada),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          doc.id,
                          style: AppType.mono.copyWith(
                            color: c.text,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      AppBadge(
                        text: estadoLabel,
                        color: color,
                        size: AppBadgeSize.sm,
                      ),
                    ],
                  ),
                  if (chofer.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      chofer,
                      style: AppType.bodySm.copyWith(color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            // Velocidad a la derecha (mono, tabular). "—" si no aplica.
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  muestraVel ? speed.toStringAsFixed(0) : '—',
                  style: AppType.mono.copyWith(
                    color: muestraVel ? c.text : c.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (muestraVel)
                  Text('km/h',
                      style: AppType.monoSm.copyWith(fontSize: 9)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Cajita del breakdown por estado en el hero del panel de flota (prototipo
/// Núcleo · Flota): número mono en color de estado + label corto, en una
/// celda surface2 con border hairline.
class _EstadoCajita extends StatelessWidget {
  final int valor;
  final String label;
  final Color color;
  const _EstadoCajita({
    required this.valor,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: c.border),
        ),
        child: Column(
          children: [
            Text(
              '$valor',
              style: AppType.mono.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 1),
            Text(
              label.toUpperCase(),
              style: AppType.monoSm.copyWith(fontSize: 8.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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

  /// flutter_map avisa que el mapa está listo (primer layout completo): el
  /// padre difiere acá el encuadre inicial para que los tiles carguen.
  final VoidCallback onMapaListo;

  /// Si no es null, muestra un botón arriba-izquierda para abrir el panel de
  /// unidades (mobile). En desktop el panel es fijo y esto es null.
  final VoidCallback? onAbrirPanel;

  /// Toggle del panel de detalle (columna derecha, desktop ≥1024). Si es
  /// null, no se muestra el botón (no aplica en tablet/mobile, donde el
  /// detalle abre como sheet). `detalleColapsado` elige ícono/label.
  final VoidCallback? onToggleDetalle;
  final bool detalleColapsado;

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
    required this.onMapaListo,
    required this.onAbrirPanel,
    required this.onToggleDetalle,
    required this.detalleColapsado,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Satélite Mapbox si hay token configurado; si no, cae a callejero
    // (Carto Voyager).
    final usarSatelite = satelital && MapConstants.tieneMapbox;
    return Stack(
      children: [
        // Ambient glow firma Núcleo detrás de los tiles (sutil, brand).
        if (!usarSatelite)
          AppAmbient(
            alignment: Alignment.center,
            sizeFactor: 0.9,
            intensity: 0.3,
            color: c.brand,
          ),
        FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: centroInicial,
            initialZoom: zoomInicial,
            minZoom: 4,
            maxZoom: 18,
            // El mapa avisa cuando completó su primer layout: recién ahí el
            // padre dispara el encuadre inicial. Si lo hiciera antes, mueve la
            // cámara pero el TileLayer no carga (mapa gris hasta mover a mano).
            onMapReady: onMapaListo,
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
                // Pre-cargar 2 anillos de tiles alrededor del viewport (default
                // 1): reduce las "partes faltantes" al panear (auditoría 2026-06).
                panBuffer: 2,
              )
            else
              TileLayer(
                urlTemplate: MapConstants.tileUrl,
                subdomains: MapConstants.tileSubdomains,
                userAgentPackageName: MapConstants.userAgent,
                panBuffer: 2,
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
                builder: (ctx, markers) {
                  final cc = ctx.colors;
                  return Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: cc.brand,
                      border: Border.all(color: cc.text, width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: cc.brand.withValues(alpha: 0.6),
                          blurRadius: 10,
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        AppFormatters.formatearMiles(markers.length),
                        style: AppType.mono.copyWith(
                          color: cc.brandFg,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(usarSatelite
                    ? MapConstants.attributionSatelite
                    : MapConstants.attribution),
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

        // Controles arriba-derecha: [ocultar/mostrar detalle] + satélite.
        Positioned(
          top: AppSpacing.md,
          right: AppSpacing.md,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Toggle del panel de detalle (solo desktop ≥1024). Colapsa
              // el panel derecho para ver el mapa más grande, o lo reabre
              // (Santiago 2026-06-10).
              if (onToggleDetalle != null) ...[
                _BotonMapa(
                  icono: detalleColapsado
                      ? Icons.chevron_left
                      : Icons.chevron_right,
                  label: detalleColapsado ? 'Detalle' : 'Ocultar',
                  onTap: onToggleDetalle!,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              // Toggle satélite / mapa.
              _BotonMapa(
                icono: satelital ? Icons.map_outlined : Icons.satellite_alt,
                label: satelital ? 'Mapa' : 'Satélite',
                onTap: onToggleSatelital,
              ),
            ],
          ),
        ),

        // Leyenda de colores (abajo-izquierda) — qué significa cada dot.
        const Positioned(
          left: AppSpacing.md,
          bottom: AppSpacing.md,
          child: AppMapLegend(
            items: [
              (label: 'En ruta', status: AppMarkerStatus.live),
              (label: 'Detenida', status: AppMarkerStatus.idle),
              (label: 'Drift', status: AppMarkerStatus.warning),
              (label: 'Sin señal', status: AppMarkerStatus.error),
            ],
          ),
        ),

        // FAB "centrar en toda la flota". Solo si hay markers visibles.
        if (docs.isNotEmpty)
          Positioned(
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: FloatingActionButton.small(
              heroTag: 'mapa_flota_fit',
              backgroundColor: c.brand,
              foregroundColor: c.brandFg,
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
      height: 60,
      // El conjunto es círculo (36) + etiqueta debajo. Con esta alineación el
      // CENTRO del círculo (a 18px del top, sobre un alto total de 60) queda
      // anclado a la posición GPS real y la patente cuelga debajo (pedido
      // Santiago 2026-06-01). -0.40 = 36/60 - 1 (18px de 60 mapeado a [-1,1]).
      // El alto es 60 (no 54) para dar aire al pill y evitar el overflow de
      // 2px en el bottom (círculo 36 + 2 + pill ≈ 56).
      alignment: const Alignment(0, -0.40),
      child: _MarkerVisual(
        patente: doc.id,
        color: color,
        icono: iconoMarker,
        rotacion: rotacionMarker,
        seleccionada: esSeleccionada,
        tieneDrift: tieneDrift,
        onTap: () => onMarkerTap(doc),
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

/// El visual de un marker individual: círculo de estado con ícono +
/// etiqueta de patente debajo. Estilo Núcleo: halo glow del brand cuando
/// está seleccionado, pill de patente con border hairline.
class _MarkerVisual extends StatelessWidget {
  final String patente;
  final Color color;
  final IconData icono;
  final double rotacion;
  final bool seleccionada;
  final bool tieneDrift;
  final VoidCallback onTap;

  const _MarkerVisual({
    required this.patente,
    required this.color,
    required this.icono,
    required this.rotacion,
    required this.seleccionada,
    required this.tieneDrift,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
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
                color: seleccionada ? c.brand : c.text,
                width: seleccionada ? 4 : (tieneDrift ? 3 : 2),
              ),
              boxShadow: [
                BoxShadow(
                  color: seleccionada
                      ? c.brand.withValues(alpha: 0.6)
                      : color.withValues(alpha: 0.5),
                  blurRadius: seleccionada ? 12 : 5,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Transform.rotate(
              angle: rotacion,
              child: Icon(
                icono,
                color: c.brandFg,
                size: tieneDrift ? 20 : 22,
              ),
            ),
          ),
          const SizedBox(height: 2),
          // Etiqueta con la patente debajo del marker — para identificar
          // cada unidad sin tener que tocarla. Pill cristal Núcleo.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: c.bg.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: seleccionada ? c.brand : c.border,
                width: seleccionada ? 1.5 : 1,
              ),
            ),
            child: Text(
              patente,
              maxLines: 1,
              style: AppType.monoSm.copyWith(
                color: c.text,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Botón flotante tipo "pill" sobre el mapa (toggle satélite / abrir panel).
/// Cristal escarchado Núcleo (mismo lenguaje que AppMapInfoPill).
class _BotonMapa extends StatelessWidget {
  final IconData icono;
  final String label;
  final VoidCallback onTap;
  const _BotonMapa(
      {required this.icono, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: AppMapInfoPill(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icono, size: 16, color: c.text),
              const SizedBox(width: AppSpacing.xs),
              Text(label,
                  style: AppType.monoSm.copyWith(
                      color: c.text, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// PANEL DE DETALLE INLINE (desktop ≥1024) — columna derecha
// =============================================================================

/// Panel derecho fijo (desktop) que muestra el detalle de la unidad
/// seleccionada. Si no hay ninguna seleccionada, muestra un empty state
/// invitando a elegir una. Cuando hay selección, escucha el doc en vivo
/// con el mismo stream que `_DetalleSheet`.
class _PanelDetalle extends StatelessWidget {
  final String? patente;
  final DateTime ahora;
  final Future<void> Function(double lat, double lng) onAbrirMaps;

  const _PanelDetalle({
    required this.patente,
    required this.ahora,
    required this.onAbrirMaps,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final p = patente;
    if (p == null) {
      return Container(
        color: c.surface1,
        child: const AppEmptyState(
          icon: Icons.touch_app_outlined,
          title: 'Sin unidad seleccionada',
          subtitle: 'Tocá un marker o una unidad de la lista para ver su '
              'detalle en vivo.',
        ),
      );
    }
    return Container(
      color: c.surface1,
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(AppCollections.sitrackPosiciones)
            .doc(p)
            .snapshots(),
        builder: (ctx, snap) {
          final data = snap.data?.data();
          if (data == null) {
            return const Padding(
              padding: EdgeInsets.only(top: AppSpacing.lg),
              child: AppSkeletonList(count: 4, conAvatar: false),
            );
          }
          return _DetalleContenido(
            patente: p,
            data: data,
            ahora: ahora,
            embedded: true,
            onAbrirMaps: onAbrirMaps,
          );
        },
      ),
    );
  }
}

// =============================================================================
// SHEET DE DETALLE (mobile / tablet)
// =============================================================================

class _DetalleSheet extends StatelessWidget {
  final String patente;

  const _DetalleSheet({required this.patente});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
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
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppRadius.xxl)),
              border: Border.all(color: c.border),
            ),
            child: Center(
                child: CircularProgressIndicator(color: c.brand)),
          );
        }
        return _DetalleContenido(
          patente: patente,
          data: data,
          ahora: DateTime.now(),
          embedded: false,
          onAbrirMaps: (lat, lng) => abrirMaps(context, lat, lng),
        );
      },
    );
  }

  /// Abre Google Maps en una ventana externa. Si el launch falla (raro
  /// pero pasa con browser desconfigurado o Android sin queries en
  /// manifest), notificamos al admin con SnackBar — antes fallaba
  /// silencioso y el botón parecía roto.
  ///
  /// Static + público para que tanto el sheet como el panel inline usen
  /// la misma implementación.
  static Future<void> abrirMaps(
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
}

/// Convierte heading en grados (0=N, 90=E, 180=S, 270=O) a sentido
/// cardinal de 8 direcciones (N, NE, E, SE, S, SO, O, NO).
String _rumboCardinal(double heading) {
  const cardinales = ['N', 'NE', 'E', 'SE', 'S', 'SO', 'O', 'NO'];
  // Normalizar a [0, 360) por si vienen valores fuera de rango.
  final h = ((heading % 360) + 360) % 360;
  // Cada cardinal cubre 45° centrado en su ángulo. +22.5 desplaza
  // los bordes para que 0..22.5 sea N, 22.5..67.5 sea NE, etc.
  final idx = ((h + 22.5) / 45).floor() % 8;
  return cardinales[idx];
}

/// Contenido del detalle de una unidad — compartido entre el sheet
/// (mobile/tablet) y el panel inline (desktop).
///
/// Estilo Núcleo: eyebrow "SELECCIONADA" + patente (h3) + chofer/modelo
/// (mono) + grilla de AppStat (velocidad / odómetro / combustible / ...) +
/// eyebrow "ÚLTIMOS EVENTOS" + timeline mono. Los datos que no existen en
/// SITRACK_POSICIONES / Volvo Connect se muestran como "—" (no se inventan).
class _DetalleContenido extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> data;
  final DateTime ahora;

  /// `true` cuando se renderiza como panel inline (sin handle de sheet,
  /// sin radius superior, scrolleable a alto completo). `false` = sheet.
  final bool embedded;

  final Future<void> Function(double lat, double lng) onAbrirMaps;

  const _DetalleContenido({
    required this.patente,
    required this.data,
    required this.ahora,
    required this.embedded,
    required this.onAbrirMaps,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

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

    final minStale =
        reportTs == null ? null : ahora.difference(reportTs).inMinutes;
    final estadoColor = _Mapa._colorMarker(
      ignition: ignition,
      minStale: minStale,
      tieneDrift: driftTipo.isNotEmpty,
    );

    final choferTexto = driverDni.isEmpty
        ? '— (sin identificar)'
        : [driverApellido, driverNombre]
            .where((s) => s.isNotEmpty)
            .join(' ')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .ifEmpty('DNI $driverDni');

    // KPIs en grilla 2×2 (estilo prototipo Flota). Solo campos REALES de
    // SITRACK_POSICIONES; los ausentes van como "—".
    final velStat = AppStat(
      label: 'Velocidad',
      value: speed == null ? '—' : speed.toStringAsFixed(0),
      unit: speed == null ? null : 'km/h',
      valueStyle: AppType.h4,
    );
    final odoStat = AppStat(
      label: 'Odómetro',
      value: odometer == null
          ? '—'
          : AppFormatters.formatearMiles(odometer.round()),
      unit: odometer == null ? null : 'km',
      valueStyle: AppType.h4,
    );
    final horStat = AppStat(
      label: 'Horómetro',
      value: hourmeter == null ? '—' : hourmeter.toStringAsFixed(1),
      unit: hourmeter == null ? null : 'h',
      valueStyle: AppType.h4,
    );
    final rumboStat = AppStat(
      label: 'Rumbo',
      value: enMovimiento ? _rumboCardinal(headingRaw) : '—',
      unit: enMovimiento ? '${headingRaw.toStringAsFixed(0)}°' : null,
      valueStyle: AppType.h4,
      accent: enMovimiento ? c.brand : null,
    );

    final timeline = _eventosTimeline(
      reportTs: reportTs,
      ignitionTs: ignitionTs,
      ignition: ignition,
      eventName: eventName,
      location: location,
    );

    final cuerpo = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Encabezado: eyebrow + patente + chofer/modelo + badge de estado.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.lg, AppSpacing.xl, AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(child: AppEyebrow('Seleccionada')),
                  _BadgeIgnicion(on: ignition),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                patente,
                style: AppType.h3.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                choferTexto,
                style: AppType.mono.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),

        if (driftTipo.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.lg),
            child: _DriftBanner(
              tipo: driftTipo,
              sitrackDni: driverDni,
              sitrackApellido: driverApellido,
              asignacionDni: asignacionDni,
              asignacionNombre: asignacionNombre,
            ),
          ),

        AppHairline(color: c.border),

        // Grilla 2×2 de KPIs reales.
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(child: _StatCell(stat: velStat, borderRight: true)),
              Expanded(child: _StatCell(stat: odoStat)),
            ],
          ),
        ),
        AppHairline(color: c.border),
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(child: _StatCell(stat: horStat, borderRight: true)),
              Expanded(child: _StatCell(stat: rumboStat)),
            ],
          ),
        ),
        AppHairline(color: c.border),

        // Telemetría Volvo Connect (combustible, AdBlue, autonomía).
        // Vive en el doc VEHICULOS — no en SITRACK_POSICIONES — porque
        // la pobla `vehiculo_manager.actualizarTelemetria` cuando el
        // admin entra a la pantalla de unidades. Solo aparece si hay
        // dato (las unidades sin Volvo Connect quedan sin estos campos).
        _TelemetriaVolvoFila(patente: patente),

        // Estado / frescura (mono).
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.md),
          child: Row(
            children: [
              AppDot(estadoColor, size: 7),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Último reporte · '
                  '${AppFormatters.formatearFechaHoraCorta(reportTs)}',
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),

        AppHairline(color: c.border),

        // Timeline de últimos eventos (mono).
        const Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.sm),
          child: AppEyebrow('Últimos eventos'),
        ),
        if (timeline.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.md),
            child: Text('— Sin eventos recientes.',
                style: AppType.monoSm.copyWith(color: c.textMuted)),
          )
        else
          for (final ev in timeline)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl, 6, AppSpacing.xl, 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 92,
                    child: Text(
                      ev.tiempo,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      ev.texto,
                      style: AppType.bodySm.copyWith(color: c.text),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

        const SizedBox(height: AppSpacing.lg),
        // Acciones.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
          child: Row(
            children: [
              if (!embedded)
                Expanded(
                  child: AppButton.ghost(
                    label: 'Cerrar',
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              if (lat != null && lng != null) ...[
                if (!embedded) const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: AppButton(
                    label: 'Ver en Maps',
                    icon: Icons.open_in_new,
                    expand: true,
                    onPressed: () => onAbrirMaps(lat, lng),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    if (embedded) {
      // Panel inline (columna derecha desktop): scrolleable a alto completo.
      return SingleChildScrollView(child: cuerpo);
    }

    // Sheet mobile/tablet: cristal con handle + radius superior + border
    // de color según ignición.
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        border: Border.all(
          color: ignition ? c.success.withValues(alpha: 0.4) : c.border,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: AppSpacing.sm),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.border,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          Flexible(child: SingleChildScrollView(child: cuerpo)),
        ],
      ),
    );
  }

  /// Construye el timeline de eventos a partir de los timestamps REALES del
  /// doc (SITRACK_POSICIONES no historiza, así que son los hitos del
  /// snapshot actual — no se inventa historial).
  List<({String tiempo, String texto})> _eventosTimeline({
    required DateTime? reportTs,
    required DateTime? ignitionTs,
    required bool ignition,
    required String eventName,
    required String location,
  }) {
    final eventos = <({String tiempo, String texto})>[];
    if (eventName.isNotEmpty) {
      eventos.add((
        tiempo: AppFormatters.formatearFechaHoraCorta(reportTs),
        texto: eventName,
      ));
    }
    if (ignitionTs != null) {
      eventos.add((
        tiempo: AppFormatters.formatearFechaHoraCorta(ignitionTs),
        texto: ignition ? 'Motor encendido' : 'Motor apagado',
      ));
    }
    if (location.isNotEmpty) {
      eventos.add((
        tiempo: AppFormatters.formatearFechaHoraCorta(reportTs),
        texto: location,
      ));
    }
    return eventos;
  }
}

/// Celda de un AppStat dentro de la grilla 2×2 del detalle, con un border
/// hairline a la derecha opcional (separa columnas).
class _StatCell extends StatelessWidget {
  final AppStat stat;
  final bool borderRight;
  const _StatCell({required this.stat, this.borderRight = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      decoration: BoxDecoration(
        border: borderRight
            ? Border(right: BorderSide(color: c.border))
            : null,
      ),
      child: stat,
    );
  }
}

class _BadgeIgnicion extends StatelessWidget {
  final bool on;

  const _BadgeIgnicion({required this.on});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppBadge(
      text: on ? 'EN MARCHA' : 'APAGADO',
      color: on ? c.success : c.textMuted,
      dot: true,
      size: AppBadgeSize.sm,
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
    final c = context.colors;
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.sm),
              child: AppEyebrow('Telemetría Volvo'),
            ),
            if (combustible != null)
              _FilaTelemetria(
                label: 'Combustible',
                valor: '${combustible.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.local_gas_station,
                color: _colorPorcentaje(combustible),
              ),
            if (adblue != null)
              _FilaTelemetria(
                label: 'AdBlue',
                valor: '${adblue.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.water_drop_outlined,
                color: _colorPorcentaje(adblue),
              ),
            if (autonomia != null)
              _FilaTelemetria(
                label: 'Autonomía',
                valor: '${autonomia.toStringAsFixed(0)} km',
                icono: Icons.timeline,
                color: c.textSecondary,
              ),
            const SizedBox(height: AppSpacing.sm),
            AppHairline(color: c.border),
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

/// Fila compacta de telemetría Volvo: ícono + label + valor mono a la
/// derecha. Estilo Núcleo.
class _FilaTelemetria extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icono;
  final Color color;
  const _FilaTelemetria({
    required this.label,
    required this.valor,
    required this.icono,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl, vertical: 4),
      child: Row(
        children: [
          Icon(icono, size: 16, color: color),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(label, style: AppType.label),
          ),
          Text(
            valor,
            style: AppType.mono.copyWith(color: c.text),
          ),
        ],
      ),
    );
  }
}

/// Banner naranja en el detalle del tractor cuando el chofer físico
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
    final c = context.colors;
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
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber, color: c.warning, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: AppType.label.copyWith(
                      color: c.warning, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  detalle,
                  style: AppType.bodySm.copyWith(color: c.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
