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
import '../models/punto_recorrido.dart';
import '../services/recorrido_service.dart';

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
/// UX (refactor Núcleo · jun 2026; detalle-en-acordeón Santiago 2026-06-10):
/// - Desktop/Tablet (≥720px): 2 columnas — sidebar de unidades (320) │ mapa.
///   El detalle de la unidad NO vive en un panel aparte: al tocar una
///   unidad (en la lista o su marker) la card se DESPLIEGA como acordeón
///   con todo su detalle adentro (`_ItemUnidad` → `_DetalleContenido` en
///   modo `enLista`). Una sola abierta a la vez. Así el mapa gana ancho.
/// - Mobile (<720px): mapa full + botón para abrir la lista (sheet, con la
///   misma card desplegable). Tap en un marker abre el detalle como sheet.
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

  /// Patente seleccionada (resalta su marker + centra el mapa + despliega
  /// su card en la lista lateral). null = ninguna.
  String? _seleccionada;

  // ── Recorrido histórico de UNA unidad (Santiago 2026-06-10) ──────────
  // Al elegir 24h/48h/rango en el dropdown de la unidad, consultamos
  // SITRACK_EVENTOS (vía RecorridoService) y dibujamos la trayectoria como
  // polyline en el mapa. Estado vive acá (lo dibuja `_Mapa`, lo dispara la
  // sección del acordeón). Solo un recorrido a la vez.
  List<PuntoRecorrido>? _recorrido;
  String? _recorridoPatente;

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
      // Al cambiar de unidad, limpiamos el recorrido de la anterior (es de
      // otra patente — no tiene sentido dejarlo encima).
      if (_recorridoPatente != null && _recorridoPatente != doc.id) {
        _limpiarRecorridoState();
      }
    });
    if (lat != null && lng != null) {
      _mapController.move(LatLng(lat, lng), 14);
    }
  }

  /// Nula los campos del recorrido (sin setState — llamar dentro de uno).
  void _limpiarRecorridoState() {
    _recorrido = null;
    _recorridoPatente = null;
  }

  /// Quita el recorrido del mapa (botón "Quitar" de la sección).
  void _limpiarRecorrido() => setState(_limpiarRecorridoState);

  /// Carga el recorrido de [patente] en `[desde, hasta)` desde SITRACK_EVENTOS
  /// y lo dibuja en el mapa, encuadrando la cámara al trayecto. Devuelve la
  /// cantidad de puntos (la sección lo usa para el feedback), o -1 si falló.
  /// Maneja el caso del índice todavía en construcción con un mensaje claro.
  Future<int> _cargarRecorrido(
      String patente, DateTime desde, DateTime hasta) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final pts = await RecorridoService.obtener(
          patente: patente, desde: desde, hasta: hasta);
      if (!mounted) return -1;
      setState(() {
        _recorrido = pts;
        _recorridoPatente = patente;
      });
      if (pts.length >= 2) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _ajustarVistaAlRecorrido(pts);
        });
      } else if (pts.length == 1) {
        _mapController.move(LatLng(pts.first.lat, pts.first.lng), 14);
      }
      return pts.length;
    } catch (e) {
      if (!mounted) return -1;
      // failed-precondition = el índice (asset_id, report_date) todavía no
      // terminó de construirse (recién deployado).
      final faltaIndice =
          e is FirebaseException && e.code == 'failed-precondition';
      messenger.showSnackBar(SnackBar(
        content: Text(faltaIndice
            ? 'El índice del recorrido se está creando. Probá de nuevo en '
                'unos minutos.'
            : 'No se pudo cargar el recorrido. Probá de nuevo.'),
      ));
      return -1;
    }
  }

  /// Encuadra la cámara al bounding box del recorrido (margen 60px).
  void _ajustarVistaAlRecorrido(List<PuntoRecorrido> pts) {
    final puntos = pts.map((p) => LatLng(p.lat, p.lng)).toList();
    if (puntos.length < 2) return;
    _mapController.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(puntos),
        padding: const EdgeInsets.all(60),
      ),
    );
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
          // No cerramos el sheet: la card se despliega inline acá mismo
          // (acordeón). Centramos el mapa detrás por si después cierra.
          onSeleccionar: _seleccionarUnidad,
          onAbrirMaps: _abrirMapsDesdePanel,
          recorrido: _RecorridoUI(
            patenteActiva: _recorridoPatente,
            onVer: _cargarRecorrido,
            onLimpiar: _limpiarRecorrido,
          ),
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

          // Layout responsive (Santiago 2026-06-10: el detalle dejó de ser
          // un panel derecho fijo y pasó a vivir DENTRO de la card de la
          // unidad, como acordeón — ver `_ItemUnidad`):
          // - ≥720: sidebar de unidades (320) + mapa. Tocar una unidad la
          //   despliega en la lista. Sin panel derecho.
          // - <720: mapa full + botón "Unidades" (sheet con la misma lista
          //   desplegable). Tap en marker abre el detalle como sheet.
          return LayoutBuilder(
            builder: (lbCtx, constraints) {
              final w = constraints.maxWidth;
              final panelFijo = w >= 720;

              final recorridoUI = _RecorridoUI(
                patenteActiva: _recorridoPatente,
                onVer: _cargarRecorrido,
                onLimpiar: _limpiarRecorrido,
              );

              final mapa = _Mapa(
                controller: _mapController,
                centroInicial: _centroInicial,
                zoomInicial: _zoomInicial,
                docs: visibles,
                ahora: ahora,
                satelital: _satelital,
                seleccionada: _seleccionada,
                recorrido: _recorrido,
                onToggleSatelital: () =>
                    setState(() => _satelital = !_satelital),
                // Con sidebar visible (≥720), el tap en un marker selecciona
                // y despliega la card en la lista. En mobile, abre el sheet.
                onMarkerTap: panelFijo ? _seleccionarUnidad : _abrirDetalle,
                onFitFlota: () => _ajustarVistaATodaLaFlota(visibles),
                onPosicionCambiada: _persistirPosicion,
                onMapaListo: _onMapaListo,
                onAbrirPanel: panelFijo
                    ? null
                    : () => _abrirPanelMobile(visibles, ahora),
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
                      onAbrirMaps: _abrirMapsDesdePanel,
                      recorrido: recorridoUI,
                    ),
                  ),
                  AppHairline(vertical: true, color: c.border),
                  Expanded(child: mapa),
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
  final Future<void> Function(double lat, double lng) onAbrirMaps;

  /// Controlador del recorrido histórico (lo usa la sección dentro de cada
  /// card desplegada).
  final _RecorridoUI recorrido;

  const _PanelUnidades({
    required this.docs,
    required this.ahora,
    required this.seleccionada,
    required this.onSeleccionar,
    required this.onAbrirMaps,
    required this.recorrido,
  });

  @override
  State<_PanelUnidades> createState() => _PanelUnidadesState();
}

class _PanelUnidadesState extends State<_PanelUnidades> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  /// Patente desplegada (acordeón). Estado LOCAL del panel — así la
  /// instancia del sheet mobile maneja su propia expansión. Se inicializa
  /// y se sincroniza con `widget.seleccionada` (ej. al tocar un marker).
  String? _expandida;

  final _scroll = ScrollController();

  /// Key de la card desplegada — para traerla a la vista al expandir.
  final _keyExpandida = GlobalKey();

  @override
  void initState() {
    super.initState();
    _expandida = widget.seleccionada;
  }

  @override
  void didUpdateWidget(_PanelUnidades old) {
    super.didUpdateWidget(old);
    // Selección externa (tap en un marker del mapa) → desplegar esa card
    // y traerla a la vista.
    if (widget.seleccionada != old.seleccionada &&
        widget.seleccionada != null) {
      _expandida = widget.seleccionada;
      _focarExpandida();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Toca una card: toggle del acordeón. Al expandir, selecciona (centra el
  /// mapa + resalta el marker) y la trae a la vista; al colapsar solo cierra.
  void _onTapItem(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final expandir = _expandida != doc.id;
    setState(() => _expandida = expandir ? doc.id : null);
    if (expandir) {
      widget.onSeleccionar(doc);
      _focarExpandida();
    }
  }

  /// Lleva la card desplegada cerca del tope de la lista (si está construida
  /// en el viewport; si está lejos, no scrollea — degradación silenciosa).
  void _focarExpandida() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keyExpandida.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.02,
          duration: const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
        );
      }
    });
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

    // Conteo de "activas" (motor en marcha + reporte fresco ≤60 min) sobre
    // TODAS las unidades visibles (no las filtradas por búsqueda), para el
    // hero del panel. El breakdown En ruta/Detenidas/Sin señal se quitó
    // (Santiago 2026-06-10) — quedó solo este número.
    var activas = 0;
    for (final d in widget.docs) {
      final data = d.data();
      final ignition = data['ignition'] == true;
      final reportTs = (data['report_date'] as Timestamp?)?.toDate();
      final minStale = reportTs == null
          ? null
          : widget.ahora.difference(reportTs).inMinutes;
      final esStale = minStale != null && minStale > 60;
      if (!esStale && ignition) activas++;
    }
    final total = widget.docs.length;

    return Container(
      color: c.surface1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Hero: eyebrow + número "activas / total" (motor en marcha +
          // reporte fresco, sobre el total con posición).
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
              ],
            ),
          ),
          const AppHairline(),
          // Buscador por patente o chofer.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.md),
            child: SizedBox(
              // 40, no 38: el InputDecorator (isDense + ícono + borde) mide
              // ~39px, así que con 38 desbordaba 1px abajo ("RenderFlex
              // overflowed by 1.00 pixels") y como el panel se reconstruye en
              // cada tick del stream de posiciones, se re-disparaba en ráfaga.
              height: 40,
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
                    controller: _scroll,
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
                      final expandida = d.id == _expandida;
                      return _ItemUnidad(
                        key: expandida ? _keyExpandida : null,
                        doc: d,
                        ahora: widget.ahora,
                        expandida: expandida,
                        onTap: () => _onTapItem(d),
                        onAbrirMaps: widget.onAbrirMaps,
                        recorrido: widget.recorrido,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Un item del panel — AHORA ACORDEÓN (Santiago 2026-06-10): la fila
/// resumen (AppDot + patente + AppBadge de estado + chofer + velocidad +
/// chevron) es tappeable; al desplegarse muestra DEBAJO el detalle completo
/// (`_DetalleContenido` en modo `enLista`). El detalle reemplazó al panel
/// derecho fijo. Solo una card abierta a la vez.
class _ItemUnidad extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final DateTime ahora;
  final bool expandida;
  final VoidCallback onTap;
  final Future<void> Function(double lat, double lng) onAbrirMaps;
  final _RecorridoUI recorrido;

  const _ItemUnidad({
    super.key,
    required this.doc,
    required this.ahora,
    required this.expandida,
    required this.onTap,
    required this.onAbrirMaps,
    required this.recorrido,
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

    // Fila resumen tappeable (el detalle se despliega DEBAJO al expandir).
    final fila = InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: AppDot(color, size: 8, glow: expandida),
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
            const SizedBox(width: AppSpacing.sm),
            // Chevron de acordeón.
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                expandida ? Icons.expand_less : Icons.expand_more,
                size: 18,
                color: c.textMuted,
              ),
            ),
          ],
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: expandida ? c.surface2 : null,
        border: Border(
          left: BorderSide(
            color: expandida ? c.brand : Colors.transparent,
            width: 2,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          fila,
          // Detalle desplegado: reusa `_DetalleContenido` sin encabezado
          // (la fila de arriba ya muestra patente/chofer/estado) ni botón
          // Cerrar; el scroll lo maneja el ListView del panel.
          if (expandida)
            _DetalleContenido(
              patente: doc.id,
              data: data,
              ahora: ahora,
              enLista: true,
              onAbrirMaps: onAbrirMaps,
              recorrido: recorrido,
            ),
        ],
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

  /// Puntos del recorrido histórico a dibujar como polyline (null = ninguno).
  final List<PuntoRecorrido>? recorrido;

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

  const _Mapa({
    required this.controller,
    required this.centroInicial,
    required this.zoomInicial,
    required this.docs,
    required this.ahora,
    required this.satelital,
    required this.seleccionada,
    this.recorrido,
    required this.onToggleSatelital,
    required this.onMarkerTap,
    required this.onFitFlota,
    required this.onPosicionCambiada,
    required this.onMapaListo,
    required this.onAbrirPanel,
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
            // Recorrido histórico (polyline) — sobre los tiles y DEBAJO de
            // los markers de unidades, que quedan visibles encima.
            if (recorrido != null && recorrido!.length >= 2)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points:
                        recorrido!.map((p) => LatLng(p.lat, p.lng)).toList(),
                    color: c.brand,
                    strokeWidth: 4,
                  ),
                ],
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
            // Extremos del recorrido (inicio verde / fin rojo), encima de todo.
            if (recorrido != null && recorrido!.isNotEmpty)
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(recorrido!.first.lat, recorrido!.first.lng),
                    width: 64,
                    height: 40,
                    alignment: const Alignment(0, -0.6),
                    child: const _MarkerExtremo(esInicio: true),
                  ),
                  if (recorrido!.length >= 2)
                    Marker(
                      point: LatLng(recorrido!.last.lat, recorrido!.last.lng),
                      width: 64,
                      height: 40,
                      alignment: const Alignment(0, -0.6),
                      child: const _MarkerExtremo(esInicio: false),
                    ),
                ],
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
          enLista: false,
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

  /// `true` cuando se renderiza DENTRO de la card de la lista (acordeón):
  /// sin encabezado de patente/chofer (la card ya lo muestra), sin botón
  /// Cerrar y SIN wrapper de scroll (lo scrollea el ListView del panel).
  /// `false` = sheet (mobile/tablet) con handle + encabezado + Cerrar.
  final bool enLista;

  final Future<void> Function(double lat, double lng) onAbrirMaps;

  /// Controlador del recorrido histórico. Solo lo pasa el acordeón de la
  /// lista (`enLista`); el sheet de tap-marker lo deja null (no muestra la
  /// sección, porque el mapa quedaría tapado por el sheet).
  final _RecorridoUI? recorrido;

  const _DetalleContenido({
    required this.patente,
    required this.data,
    required this.ahora,
    required this.enLista,
    required this.onAbrirMaps,
    this.recorrido,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    final ignition = data['ignition'] == true;
    final speed = (data['speed'] as num?)?.toDouble();
    final odometer = (data['odometer'] as num?)?.toDouble();
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
        // Encabezado (solo en el sheet — en la lista la card de arriba ya
        // muestra patente/chofer/estado, sería redundante).
        if (!enLista)
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

        // Grilla de KPIs: Velocidad | Odómetro. (Horómetro y Rumbo se
        // quitaron — Santiago 2026-06-10: ocupaban lugar sin aportar.)
        IntrinsicHeight(
          child: Row(
            children: [
              Expanded(child: _StatCell(stat: velStat, borderRight: true)),
              Expanded(child: _StatCell(stat: odoStat)),
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

        // Recorrido histórico (solo en el acordeón de la lista): botones
        // 24h/48h + rango personalizado; dibuja la trayectoria en el mapa.
        if (recorrido != null)
          _SeccionRecorrido(patente: patente, ctrl: recorrido!),
        const SizedBox(height: AppSpacing.lg),
        // Acciones.
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, 0, AppSpacing.xl, AppSpacing.xl),
          child: Row(
            children: [
              if (!enLista)
                Expanded(
                  child: AppButton.ghost(
                    label: 'Cerrar',
                    expand: true,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              if (lat != null && lng != null) ...[
                if (!enLista) const SizedBox(width: AppSpacing.md),
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

    if (enLista) {
      // Dentro de la card del ListView (acordeón): devolvemos el cuerpo
      // crudo; el scroll lo maneja la lista del panel.
      return cuerpo;
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

// =============================================================================
// RECORRIDO HISTÓRICO — controlador + sección del acordeón + markers extremo
// =============================================================================

/// Bundle que baja por la cadena panel→item→detalle hasta `_SeccionRecorrido`.
/// `patenteActiva` = la unidad cuyo recorrido está dibujado en el mapa AHORA
/// (fuente de verdad del screen), para que la sección sepa mostrar "Quitar".
class _RecorridoUI {
  final String? patenteActiva;

  /// Carga + dibuja el recorrido. Devuelve la cantidad de puntos (o -1 si
  /// falló) para que la sección dé feedback sin depender del rebuild del
  /// screen (clave en el sheet mobile, que no se reconstruye con setState).
  final Future<int> Function(String patente, DateTime desde, DateTime hasta)
      onVer;
  final VoidCallback onLimpiar;

  const _RecorridoUI({
    required this.patenteActiva,
    required this.onVer,
    required this.onLimpiar,
  });
}

/// Sección "RECORRIDO" dentro del acordeón de una unidad: accesos rápidos
/// 24h/48h + rango personalizado (fecha+hora desde/hasta) que disparan el
/// dibujo de la trayectoria en el mapa. Estado de carga LOCAL (anda también
/// dentro del sheet mobile).
class _SeccionRecorrido extends StatefulWidget {
  final String patente;
  final _RecorridoUI ctrl;
  const _SeccionRecorrido({required this.patente, required this.ctrl});

  @override
  State<_SeccionRecorrido> createState() => _SeccionRecorridoState();
}

class _SeccionRecorridoState extends State<_SeccionRecorrido> {
  bool _modoRango = false;
  DateTime? _desde;
  DateTime? _hasta;
  bool _cargando = false;
  int? _ultimoConteo; // resultado del último pedido (null = no pidió)

  bool get _activo => widget.ctrl.patenteActiva == widget.patente;

  Future<void> _pedir(DateTime desde, DateTime hasta) async {
    setState(() => _cargando = true);
    final n = await widget.ctrl.onVer(widget.patente, desde, hasta);
    if (!mounted) return;
    setState(() {
      _cargando = false;
      if (n >= 0) _ultimoConteo = n;
    });
  }

  void _rapido(int horas) {
    final ahora = DateTime.now();
    _pedir(ahora.subtract(Duration(hours: horas)), ahora);
  }

  Future<void> _elegir({required bool esDesde}) async {
    final base = (esDesde ? _desde : _hasta) ?? DateTime.now();
    final fecha = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(2026, 5, 13), // arranque del histórico Sitrack
      lastDate: DateTime.now(),
    );
    if (fecha == null || !mounted) return;
    final hora = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(base),
    );
    if (!mounted) return;
    final dt = DateTime(
        fecha.year, fecha.month, fecha.day, hora?.hour ?? 0, hora?.minute ?? 0);
    setState(() {
      if (esDesde) {
        _desde = dt;
      } else {
        _hasta = dt;
      }
    });
  }

  void _verRango() {
    final d = _desde, h = _hasta;
    final messenger = ScaffoldMessenger.of(context);
    if (d == null || h == null) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Elegí fecha/hora de inicio y de fin.')));
      return;
    }
    if (!h.isAfter(d)) {
      messenger.showSnackBar(const SnackBar(
          content:
              Text('La fecha de fin tiene que ser posterior al inicio.')));
      return;
    }
    _pedir(d, h);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppHairline(color: c.border),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl, AppSpacing.md, AppSpacing.xl, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppEyebrow('Recorrido'),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _BotonRango(label: 'Últimas 24 h', onTap: () => _rapido(24)),
                  _BotonRango(label: 'Últimas 48 h', onTap: () => _rapido(48)),
                  _BotonRango(
                    label: 'Rango…',
                    activo: _modoRango,
                    onTap: () => setState(() => _modoRango = !_modoRango),
                  ),
                ],
              ),
              if (_modoRango) ...[
                const SizedBox(height: AppSpacing.sm),
                _CampoFechaHora(
                  label: 'Desde',
                  valor: _desde,
                  onTap: () => _elegir(esDesde: true),
                ),
                const SizedBox(height: 6),
                _CampoFechaHora(
                  label: 'Hasta',
                  valor: _hasta,
                  onTap: () => _elegir(esDesde: false),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppButton.primary(
                  label: 'Ver recorrido',
                  icon: Icons.timeline,
                  size: AppButtonSize.sm,
                  onPressed: _verRango,
                ),
              ],
              const SizedBox(height: AppSpacing.sm),
              if (_cargando)
                Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.brand),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text('Buscando movimientos…',
                        style:
                            AppType.monoSm.copyWith(color: c.textSecondary)),
                  ],
                )
              else if (_ultimoConteo != null || _activo) ...[
                Text(
                  _ultimoConteo == null
                      ? 'Recorrido en el mapa.'
                      : _ultimoConteo == 0
                          ? 'Sin movimientos en ese rango.'
                          : '$_ultimoConteo puntos en el mapa.',
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
                if (_activo) ...[
                  const SizedBox(height: 6),
                  _BotonRango(
                    label: 'Quitar del mapa',
                    icono: Icons.close,
                    onTap: () {
                      widget.ctrl.onLimpiar();
                      setState(() => _ultimoConteo = null);
                    },
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// Pill chico de rango (24h/48h/rango/quitar). Mismo lenguaje que los chips
/// del resto: inactivo = borde; activo = tinte brand.
class _BotonRango extends StatelessWidget {
  final String label;
  final IconData? icono;
  final bool activo;
  final VoidCallback onTap;
  const _BotonRango({
    required this.label,
    required this.onTap,
    this.icono,
    this.activo = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = activo ? c.brand : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? c.brand.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
              color: activo ? c.brand.withValues(alpha: 0.5) : c.borderStrong),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icono != null) ...[
              Icon(icono, size: 13, color: fg),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: AppType.label
                    .copyWith(color: fg, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

/// Campo tappeable "Desde/Hasta: <fecha hora>" que abre date + time picker.
class _CampoFechaHora extends StatelessWidget {
  final String label;
  final DateTime? valor;
  final VoidCallback onTap;
  const _CampoFechaHora({
    required this.label,
    required this.valor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Text('$label:', style: AppType.label.copyWith(color: c.textMuted)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                valor == null
                    ? 'Elegir…'
                    : AppFormatters.formatearFechaHoraCorta(valor),
                style: AppType.mono
                    .copyWith(color: valor == null ? c.textMuted : c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.event, size: 15, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Marker de extremo del recorrido: dot (inicio verde / fin rojo) + pill.
class _MarkerExtremo extends StatelessWidget {
  final bool esInicio;
  const _MarkerExtremo({required this.esInicio});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = esInicio ? c.success : c.error;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: c.text, width: 2),
            boxShadow: [
              BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 5),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            color: c.bg.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: color.withValues(alpha: 0.6)),
          ),
          child: Text(
            esInicio ? 'Inicio' : 'Fin',
            style: AppType.monoSm.copyWith(
                color: c.text, fontSize: 9, fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }
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
