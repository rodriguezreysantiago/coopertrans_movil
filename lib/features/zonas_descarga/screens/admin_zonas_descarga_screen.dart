// lib/features/zonas_descarga/screens/admin_zonas_descarga_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — CRUD de geocercas en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream de zonas (`ZonasDescargaService.stream()`),
//   - el CRUD completo (`crear` / `editar` / `setActivo` / `eliminar` +
//     `slugDesdeNombre`) con sus diálogos de confirmación,
//   - el `_ZonaForm` entero: controllers, validators, parseo de vértices,
//     máquina del mapa (tap mueve centro / agrega vértice, deshacer,
//     limpiar, centrar, toggle satélite, debounce de rebuild) y `_guardar`,
//   - el `_MapaEditor` (FlutterMap + Circle/Polygon/Polyline/Marker layers),
//   - la navegación.
//
// Layout Núcleo:
//   ┌─ Hero: eyebrow ZONAS DE DESCARGA · hero number (n zonas) + nueva ──┐
//   ├─ Banner explicativo (AppCard accent info) ─────────────────────────┤
//   └─ Lista de zonas (AppCard por zona, dot estado + resumen geom mono) ┘
//
// Reglas duras: tokens (context.colors), números/coords en mono, faltante
// → "—", embedded (AppScaffold auto-detecta el shell), sin overflow.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/zona_descarga.dart';
import '../services/zonas_descarga_service.dart';

/// Pantalla admin para crear/editar zonas de descarga. El operador
/// define cada zona (YPF Añelo, otras plantas) con su geometría
/// (círculo o polígono). La CF `zonaDescargaPoller` las consume cada
/// 5 min para mantener la cola en vivo del módulo "Descargas".
class AdminZonasDescargaScreen extends StatelessWidget {
  const AdminZonasDescargaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Zonas de descarga',
      body: StreamBuilder<List<ZonaDescarga>>(
        stream: ZonasDescargaService.stream(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppSkeletonList(count: 4, conAvatar: false);
          }
          final zonas = snap.data ?? const <ZonaDescarga>[];
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              _Hero(
                total: zonas.length,
                activas: zonas.where((z) => z.activo).length,
                onNueva: () => _abrirForm(context, null),
              ),
              const SizedBox(height: AppSpacing.md),
              const _BannerExplicativo(),
              const SizedBox(height: AppSpacing.lg),
              if (zonas.isEmpty)
                const _EstadoVacio()
              else
                for (final z in zonas) _ZonaCard(zona: z),
            ],
          );
        },
      ),
    );
  }

  static void _abrirForm(BuildContext context, ZonaDescarga? z) {
    final c = context.colors;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: c.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => _ZonaForm(zonaExistente: z),
    );
  }
}

// =============================================================================
// HERO · eyebrow ZONAS DE DESCARGA · hero number (n zonas) + nueva
// =============================================================================

class _Hero extends StatelessWidget {
  final int total;
  final int activas;
  final VoidCallback onNueva;
  const _Hero({
    required this.total,
    required this.activas,
    required this.onNueva,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppEyebrow('ZONAS DE DESCARGA'),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$total',
                    style: AppType.h2.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      total == 0
                          ? 'sin zonas'
                          : (total == 1 ? 'zona' : 'zonas'),
                      style: AppType.monoSm,
                    ),
                  ),
                  if (total > 0) ...[
                    const SizedBox(width: 8),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '· $activas activa${activas == 1 ? "" : "s"}',
                        style: AppType.monoSm.copyWith(color: c.success),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            AppButton(
              label: 'Nueva zona',
              icon: Icons.add,
              size: AppButtonSize.sm,
              onPressed: onNueva,
            ),
          ],
        ),
      ],
    );
  }
}

class _BannerExplicativo extends StatelessWidget {
  const _BannerExplicativo();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      accent: c.info,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: c.info, size: 18),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Cada zona define un lugar de descarga (ej. YPF Añelo). El '
              'sistema detecta cuándo entra y sale cada unidad para armar '
              'la cola en vivo del módulo "Descargas". Definila como '
              'círculo (centro + radio) o polígono (puntos).',
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _EstadoVacio extends StatelessWidget {
  const _EstadoVacio();

  @override
  Widget build(BuildContext context) {
    return const AppEmptyState(
      icon: Icons.add_location_alt_outlined,
      title: 'Sin zonas cargadas',
      subtitle: 'Cargá la primera zona (YPF Añelo) para que el módulo '
          '"Descargas" empiece a detectar entradas y salidas.',
    );
  }
}

class _ZonaCard extends StatelessWidget {
  final ZonaDescarga zona;
  const _ZonaCard({required this.zona});

  String get _resumenGeom {
    if (zona.shape == ZonaShape.circulo) {
      if (zona.centro == null || zona.radioMts == null) return 'Sin centro';
      return '${zona.radioMts!.toStringAsFixed(0)} m radio · '
          '${zona.centro!.latitud.toStringAsFixed(5)}, '
          '${zona.centro!.longitud.toStringAsFixed(5)}';
    }
    return '${zona.vertices.length} puntos';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = zona.activo ? c.success : c.textMuted;
    final notas = (zona.notas ?? '').trim();
    return AppCard(
      tier: 2,
      onTap: () => AdminZonasDescargaScreen._abrirForm(context, zona),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Opacity(
        opacity: zona.activo ? 1.0 : 0.6,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppDot(color, size: 8, glow: zona.activo),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    zona.nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.h5,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppBadge(
                  text: zona.activo ? 'ACTIVA' : 'PAUSADA',
                  color: color,
                  dot: true,
                  size: AppBadgeSize.sm,
                ),
                Icon(Icons.chevron_right, size: 18, color: c.textMuted),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const AppHairline(),
            const SizedBox(height: AppSpacing.md),
            // Geometría + estadía en filas label/valor mono.
            _LineaMeta(
              label: zona.shape == ZonaShape.circulo ? 'Círculo' : 'Polígono',
              valor: _resumenGeom,
            ),
            const SizedBox(height: 4),
            _LineaMeta(
              label: 'Estadía mín.',
              valor: '${zona.estadiaMinMin} min',
            ),
            const SizedBox(height: 4),
            _LineaMeta(label: 'Slug', valor: zona.slug),
            if (notas.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                notas,
                style: AppType.bodySm
                    .copyWith(color: c.textMuted, fontStyle: FontStyle.italic),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AppButton.ghost(
                  label: zona.activo ? 'Pausar' : 'Reanudar',
                  icon: zona.activo
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                  size: AppButtonSize.sm,
                  onPressed: () =>
                      ZonasDescargaService.setActivo(zona.slug, !zona.activo),
                ),
                const SizedBox(width: AppSpacing.sm),
                AppButton.danger(
                  label: 'Eliminar',
                  icon: Icons.delete_outline,
                  size: AppButtonSize.sm,
                  glow: false,
                  onPressed: () => _confirmarBorrar(context, zona),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarBorrar(BuildContext context, ZonaDescarga z) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: c.surface2,
        title: const Text('Eliminar zona'),
        content: Text(
          'Vas a eliminar "${z.nombre}". La cola activa y el histórico '
          'no se borran pero quedan huérfanos. ¿Confirmás?',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton.danger(
            label: 'Eliminar',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) await ZonasDescargaService.eliminar(z.slug);
  }
}

/// Fila label (izq) / valor mono (der) para la meta de una zona.
class _LineaMeta extends StatelessWidget {
  final String label;
  final String valor;
  const _LineaMeta({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppType.bodySm.copyWith(color: c.textMuted)),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            valor,
            textAlign: TextAlign.right,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.monoSm.copyWith(color: c.textSecondary),
          ),
        ),
      ],
    );
  }
}

// ─── Form alta/edit ─────────────────────────────────────────────

class _ZonaForm extends StatefulWidget {
  final ZonaDescarga? zonaExistente;
  const _ZonaForm({this.zonaExistente});

  @override
  State<_ZonaForm> createState() => _ZonaFormState();
}

class _ZonaFormState extends State<_ZonaForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nombre;
  late final TextEditingController _lat;
  late final TextEditingController _lng;
  late final TextEditingController _radio;
  late final TextEditingController _verticesText;
  late final TextEditingController _estadia;
  late final TextEditingController _notas;
  late ZonaShape _shape;
  late bool _activo;
  bool _guardando = false;
  String? _error;

  // ─── Mini mapa interactivo ─────────────────────────────────────
  /// Controller del mapa para reposicionar la cámara cuando el usuario
  /// pega coords nuevas o cambia de shape.
  final MapController _mapController = MapController();
  /// Toggle entre mapa callejero (default) y satelital (mejor para ver
  /// playas de carga, silos, accesos a plantas — donde el callejero no
  /// tiene detalle).
  bool _vistaSatelital = false;
  /// Si el usuario está editando los TextField y queremos evitar
  /// re-renderear el mapa con cada keystroke (jank), debounceamos.
  Timer? _debounceRebuild;

  bool get _esEdicion => widget.zonaExistente != null;

  /// Lee los TextField y devuelve el centro actual del círculo si
  /// ambos lat/lng son numbers válidos.
  LatLng? get _centroFromText {
    final lat = double.tryParse(_lat.text.trim());
    final lng = double.tryParse(_lng.text.trim());
    if (lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  /// Lee el TextField del radio, mínimo 50m.
  double get _radioFromText {
    final r = double.tryParse(_radio.text.trim()) ?? 200;
    return r.clamp(50, 10000).toDouble();
  }

  /// Parsea el TextField de vértices a una lista LatLng.
  List<LatLng> get _verticesFromText {
    return _parsearVertices(_verticesText.text)
        .map((p) => LatLng(p.latitud, p.longitud))
        .toList();
  }

  /// Centro inicial del mapa: el centro de la zona si edita, o el
  /// primer vértice si polígono, o Bahía Blanca como fallback.
  LatLng get _centroInicialMapa {
    if (_centroFromText != null) return _centroFromText!;
    if (_verticesFromText.isNotEmpty) return _verticesFromText.first;
    return MapConstants.defaultCenter;
  }

  /// Zoom inicial: 15 si hay centro (suficiente para una planta),
  /// 12 si es Bahía Blanca (más alejado).
  double get _zoomInicialMapa =>
      (_centroFromText != null || _verticesFromText.isNotEmpty) ? 15.5 : 11;

  @override
  void initState() {
    super.initState();
    final z = widget.zonaExistente;
    _nombre = TextEditingController(text: z?.nombre ?? '');
    _lat = TextEditingController(
        text: z?.centro?.latitud.toStringAsFixed(6) ?? '');
    _lng = TextEditingController(
        text: z?.centro?.longitud.toStringAsFixed(6) ?? '');
    _radio = TextEditingController(text: z?.radioMts?.toStringAsFixed(0) ?? '200');
    _verticesText = TextEditingController(
      text: (z?.vertices ?? [])
          .map((v) =>
              '${v.latitud.toStringAsFixed(6)}, ${v.longitud.toStringAsFixed(6)}')
          .join('\n'),
    );
    _estadia = TextEditingController(text: (z?.estadiaMinMin ?? 5).toString());
    _notas = TextEditingController(text: z?.notas ?? '');
    _shape = z?.shape ?? ZonaShape.circulo;
    _activo = z?.activo ?? true;

    // Listeners debounceados para refrescar la previsualización del
    // mapa cuando el usuario edita los TextField a mano (sin spammear
    // setState con cada keystroke).
    for (final c in [_lat, _lng, _radio, _verticesText]) {
      c.addListener(_debounceMapaRebuild);
    }
  }

  void _debounceMapaRebuild() {
    _debounceRebuild?.cancel();
    _debounceRebuild = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _debounceRebuild?.cancel();
    _mapController.dispose();
    for (final c in [_nombre, _lat, _lng, _radio, _verticesText, _estadia, _notas]) {
      c.dispose();
    }
    super.dispose();
  }

  // ─── Acciones del mapa ─────────────────────────────────────────

  /// Tap del usuario en el mapa: en modo círculo mueve el centro, en
  /// modo polígono agrega un vértice al final de la lista.
  void _onMapTap(LatLng punto) {
    setState(() {
      if (_shape == ZonaShape.circulo) {
        _lat.text = punto.latitude.toStringAsFixed(6);
        _lng.text = punto.longitude.toStringAsFixed(6);
      } else {
        final actual = _verticesText.text.trim();
        final nueva =
            '${punto.latitude.toStringAsFixed(6)}, ${punto.longitude.toStringAsFixed(6)}';
        _verticesText.text =
            actual.isEmpty ? nueva : '$actual\n$nueva';
      }
    });
  }

  /// Quita el último vértice del polígono.
  void _deshacerUltimoVertice() {
    final lineas = _verticesText.text
        .split('\n')
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (lineas.isEmpty) return;
    lineas.removeLast();
    setState(() => _verticesText.text = lineas.join('\n'));
  }

  /// Limpia todos los vértices del polígono (con confirmación).
  Future<void> _limpiarVertices() async {
    if (_verticesFromText.isEmpty) return;
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: c.surface2,
        title: const Text('Limpiar vértices'),
        content: Text(
          'Vas a borrar los ${_verticesFromText.length} puntos del polígono. '
          '¿Confirmás?',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.pop(context, false),
          ),
          AppButton.danger(
            label: 'Limpiar',
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (ok == true) setState(() => _verticesText.text = '');
  }

  /// Centra el mapa en el centro del círculo o en el centroide del
  /// polígono. Útil cuando el usuario perdió de vista la zona.
  void _centrarMapaEnZona() {
    if (_shape == ZonaShape.circulo && _centroFromText != null) {
      _mapController.move(_centroFromText!, 15.5);
    } else if (_shape == ZonaShape.poligono && _verticesFromText.isNotEmpty) {
      final pts = _verticesFromText;
      if (pts.length == 1) {
        _mapController.move(pts.first, 15.5);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(pts),
            padding: const EdgeInsets.all(40),
          ),
        );
      }
    }
  }

  Future<void> _guardar() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _guardando = true);
    try {
      LatLngPunto? centro;
      double? radio;
      List<LatLngPunto> vertices = const [];
      if (_shape == ZonaShape.circulo) {
        centro = LatLngPunto(
            double.parse(_lat.text.trim()),
            double.parse(_lng.text.trim()));
        radio = double.parse(_radio.text.trim());
      } else {
        vertices = _parsearVertices(_verticesText.text);
      }
      final z = ZonaDescarga(
        slug: _esEdicion
            ? widget.zonaExistente!.slug
            : ZonasDescargaService.slugDesdeNombre(_nombre.text.trim()),
        nombre: _nombre.text.trim(),
        shape: _shape,
        centro: centro,
        radioMts: radio,
        vertices: vertices,
        estadiaMinMin: int.parse(_estadia.text.trim()),
        activo: _activo,
        notas: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
      );
      if (_esEdicion) {
        await ZonasDescargaService.editar(z);
      } else {
        await ZonasDescargaService.crear(z);
      }
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = e.toString().replaceAll('Exception: ', '');
        });
      }
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// Normaliza los "menos" tipográficos (U+2212 −, U+2013 –, U+2014 —) que
  /// traen Google Maps / Wikipedia al copiar coordenadas: `double.tryParse`
  /// solo acepta el guión ASCII y descartaba esos vértices EN SILENCIO —
  /// polígonos guardados con vértices faltantes (auditoría 2026-06-12).
  static String _normalizarMenos(String s) =>
      s.replaceAll(RegExp(r'[−–—]'), '-');

  /// Parsea líneas "lat, lng" (separadores: coma, espacio o tab).
  /// Tolera "−38.35274, −68.71163" y formatos con/sin signos.
  List<LatLngPunto> _parsearVertices(String texto) {
    final out = <LatLngPunto>[];
    for (final ln in _normalizarMenos(texto).split('\n')) {
      final t = ln.trim();
      if (t.isEmpty) continue;
      // Reemplazar separadores y dividir
      final partes =
          t.replaceAll(RegExp(r'[,;\s]+'), ' ').split(' ').where((s) => s.isNotEmpty).toList();
      if (partes.length < 2) continue;
      final lat = double.tryParse(partes[0]);
      final lng = double.tryParse(partes[1]);
      if (lat != null && lng != null) out.add(LatLngPunto(lat, lng));
    }
    return out;
  }

  /// Cantidad de líneas no vacías que NO se pudieron leer como coordenada.
  /// Lo usa el validator para avisar en vez de descartar en silencio (el
  /// operador creía guardar la geocerca completa y le faltaban vértices).
  int _lineasNoParseadas(String texto) {
    var malas = 0;
    for (final ln in _normalizarMenos(texto).split('\n')) {
      final t = ln.trim();
      if (t.isEmpty) continue;
      final partes =
          t.replaceAll(RegExp(r'[,;\s]+'), ' ').split(' ').where((s) => s.isNotEmpty).toList();
      if (partes.length < 2 ||
          double.tryParse(partes[0]) == null ||
          double.tryParse(partes[1]) == null) {
        malas++;
      }
    }
    return malas;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppEyebrow(_esEdicion ? 'EDITAR ZONA' : 'NUEVA ZONA'),
                        const SizedBox(height: 4),
                        Text(
                          _esEdicion
                              ? widget.zonaExistente!.nombre
                              : 'Geocerca de descarga',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.h5,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: c.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              TextFormField(
                controller: _nombre,
                style: AppType.body.copyWith(color: c.text),
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej. YPF Añelo',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                readOnly: _esEdicion, // slug no se cambia
              ),
              const SizedBox(height: AppSpacing.lg),
              SegmentedButton<ZonaShape>(
                segments: const [
                  ButtonSegment(
                      value: ZonaShape.circulo,
                      label: Text('Círculo'),
                      icon: Icon(Icons.circle_outlined)),
                  ButtonSegment(
                      value: ZonaShape.poligono,
                      label: Text('Polígono'),
                      icon: Icon(Icons.timeline)),
                ],
                selected: {_shape},
                onSelectionChanged: (s) => setState(() => _shape = s.first),
              ),
              const SizedBox(height: AppSpacing.lg),
              // Mini mapa interactivo. En modo círculo, tap mueve el
              // centro y se puede ajustar el radio con slider. En modo
              // polígono, cada tap agrega un vértice. Permite dibujar
              // sin tipear lat/lng a mano.
              _MapaEditor(
                shape: _shape,
                mapController: _mapController,
                centroInicial: _centroInicialMapa,
                zoomInicial: _zoomInicialMapa,
                centroCirculo: _centroFromText,
                radioMts: _radioFromText,
                vertices: _verticesFromText,
                vistaSatelital: _vistaSatelital,
                onTap: _onMapTap,
                onToggleSatelital: () =>
                    setState(() => _vistaSatelital = !_vistaSatelital),
                onCentrar: _centrarMapaEnZona,
                onDeshacerVertice:
                    _shape == ZonaShape.poligono ? _deshacerUltimoVertice : null,
                onLimpiarVertices:
                    _shape == ZonaShape.poligono ? _limpiarVertices : null,
              ),
              const SizedBox(height: AppSpacing.lg),
              if (_shape == ZonaShape.circulo) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lat,
                        style: AppType.mono.copyWith(color: c.text),
                        decoration: const InputDecoration(
                          labelText: 'Latitud',
                          hintText: '-38.352740',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d\-\.]'))
                        ],
                        validator: (v) =>
                            double.tryParse(v?.trim() ?? '') == null
                                ? 'Inválido'
                                : null,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: TextFormField(
                        controller: _lng,
                        style: AppType.mono.copyWith(color: c.text),
                        decoration: const InputDecoration(
                          labelText: 'Longitud',
                          hintText: '-68.711630',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d\-\.]'))
                        ],
                        validator: (v) =>
                            double.tryParse(v?.trim() ?? '') == null
                                ? 'Inválido'
                                : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.lg),
                TextFormField(
                  controller: _radio,
                  style: AppType.mono.copyWith(color: c.text),
                  decoration: const InputDecoration(
                    labelText: 'Radio (metros)',
                    hintText: '200',
                    helperText: 'Típico para zona de descarga: 100-500 m',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    final n = int.tryParse(v?.trim() ?? '');
                    if (n == null || n <= 0) return 'Radio > 0';
                    if (n > 10000) return 'Máx 10 km';
                    return null;
                  },
                ),
                // Slider para ajustar el radio sin tipear. Va de 50m
                // (chico, casi punto) a 3000m (cubre una planta grande
                // como YPF). Si se necesita > 3 km, usar el input.
                Slider(
                  value: _radioFromText.clamp(50, 3000).toDouble(),
                  min: 50,
                  max: 3000,
                  divisions: 59, // 50m de paso
                  label: '${_radioFromText.round()} m',
                  activeColor: c.brand,
                  onChanged: (v) {
                    setState(() => _radio.text = v.round().toString());
                  },
                ),
              ] else ...[
                TextFormField(
                  controller: _verticesText,
                  style: AppType.mono.copyWith(color: c.text),
                  decoration: const InputDecoration(
                    labelText: 'Vértices (lat, lng — uno por línea)',
                    hintText:
                        '-38.352740, -68.711630\n-38.353500, -68.710800\n-38.354100, -68.712200',
                    helperText: 'Mínimo 3 puntos. Orden en sentido horario o '
                        'antihorario, NO mezclados.',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 6,
                  validator: (v) {
                    final pts = _parsearVertices(v ?? '');
                    if (pts.length < 3) return 'Mínimo 3 puntos';
                    final malas = _lineasNoParseadas(v ?? '');
                    if (malas > 0) {
                      return '$malas línea(s) no se pudieron leer como '
                          'coordenada — revisá el formato';
                    }
                    return null;
                  },
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _estadia,
                style: AppType.body.copyWith(color: c.text),
                decoration: const InputDecoration(
                  labelText: 'Estadía mínima (minutos)',
                  helperText:
                      'Filtra unidades que solo pasaron. 5 min default.',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n < 1 || n > 240) {
                    return 'Entre 1 y 240';
                  }
                  return null;
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              TextFormField(
                controller: _notas,
                style: AppType.body.copyWith(color: c.text),
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: AppSpacing.lg),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                activeThumbColor: c.brand,
                title: Text('Zona activa',
                    style: AppType.body.copyWith(color: c.text)),
                subtitle: Text(
                  'Si está pausada, el sistema no detecta entradas ni salidas '
                  'pero la configuración queda guardada.',
                  style: AppType.bodySm.copyWith(color: c.textMuted),
                ),
                value: _activo,
                onChanged: (v) => setState(() => _activo = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _error!,
                  style: AppType.bodySm.copyWith(color: c.error),
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: _esEdicion ? 'Guardar cambios' : 'Crear zona',
                icon: Icons.save,
                isLoading: _guardando,
                expand: true,
                onPressed: _guardando ? null : _guardar,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Mini mapa editor ───────────────────────────────────────────
//
// Mapa interactivo arriba del form para dibujar la zona en lugar de
// tipear coordenadas. Soporta los dos shapes:
//
// - Círculo: muestra el círculo coloreado con su radio real en metros
//   (CircleLayer con useRadiusInMeter: true). Tap mueve el centro.
//   El slider/input numérico del form ajusta el radio en vivo.
//
// - Polígono: cada tap agrega un vértice. Muestra el polígono cerrado
//   relleno (PolygonLayer) + markers numerados por vértice. Botones
//   "deshacer" y "limpiar" para corregir.
//
// Toggle vista callejera ↔ satelital: las plantas industriales se
// reconocen mejor en satélite (silos, playas, accesos). Si no hay
// token Mapbox, el toggle queda oculto.

class _MapaEditor extends StatelessWidget {
  final ZonaShape shape;
  final MapController mapController;
  final LatLng centroInicial;
  final double zoomInicial;
  final LatLng? centroCirculo;
  final double radioMts;
  final List<LatLng> vertices;
  final bool vistaSatelital;
  final ValueChanged<LatLng> onTap;
  final VoidCallback onToggleSatelital;
  final VoidCallback onCentrar;
  final VoidCallback? onDeshacerVertice;
  final Future<void> Function()? onLimpiarVertices;

  const _MapaEditor({
    required this.shape,
    required this.mapController,
    required this.centroInicial,
    required this.zoomInicial,
    required this.centroCirculo,
    required this.radioMts,
    required this.vertices,
    required this.vistaSatelital,
    required this.onTap,
    required this.onToggleSatelital,
    required this.onCentrar,
    this.onDeshacerVertice,
    this.onLimpiarVertices,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Helper de uso — texto chico arriba del mapa, distinto según
        // el shape activo. Le dice al usuario QUÉ hace el tap.
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.sm),
          child: Row(
            children: [
              Icon(Icons.touch_app, size: 14, color: c.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  shape == ZonaShape.circulo
                      ? 'Tocá el mapa para ubicar el centro · ajustá el radio con el slider'
                      : 'Cada toque agrega un vértice · mínimo 3 puntos',
                  style: AppType.bodySm.copyWith(color: c.textMuted),
                ),
              ),
              if (shape == ZonaShape.poligono && vertices.isNotEmpty)
                Text(
                  '${vertices.length} pts',
                  style: AppType.monoSm.copyWith(color: c.brand),
                ),
            ],
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          child: SizedBox(
            height: 300,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: mapController,
                  options: MapOptions(
                    initialCenter: centroInicial,
                    initialZoom: zoomInicial,
                    minZoom: 4,
                    maxZoom: 19,
                    onTap: (_, latLng) => onTap(latLng),
                  ),
                  children: [
                    if (vistaSatelital && MapConstants.tieneMapbox)
                      TileLayer(
                        urlTemplate: MapConstants.tileSatelliteUrl,
                        userAgentPackageName: MapConstants.userAgent,
                        maxNativeZoom: 19,
                      )
                    else
                      TileLayer(
                        urlTemplate: MapConstants.tileUrl,
                        subdomains: MapConstants.tileSubdomains,
                        userAgentPackageName: MapConstants.userAgent,
                      ),
                    // Polígono relleno semi-transparente — los vértices
                    // van por separado en MarkerLayer.
                    if (shape == ZonaShape.poligono && vertices.length >= 3)
                      PolygonLayer(
                        polygons: [
                          Polygon(
                            points: vertices,
                            color: c.brand.withValues(alpha: 0.20),
                            borderColor: c.brand,
                            borderStrokeWidth: 2.5,
                          ),
                        ],
                      ),
                    // Si todavía no hay 3 puntos, dibujamos la línea
                    // tentativa que une los que hay (1 o 2 puntos).
                    if (shape == ZonaShape.poligono && vertices.length == 2)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: vertices,
                            color: c.brand,
                            strokeWidth: 2,
                          ),
                        ],
                      ),
                    // Círculo con radio real en metros (CircleMarker
                    // con useRadiusInMeter: true escala con el zoom).
                    if (shape == ZonaShape.circulo && centroCirculo != null)
                      CircleLayer(
                        circles: [
                          CircleMarker(
                            point: centroCirculo!,
                            radius: radioMts,
                            useRadiusInMeter: true,
                            color: c.brand.withValues(alpha: 0.20),
                            borderColor: c.brand,
                            borderStrokeWidth: 2.5,
                          ),
                        ],
                      ),
                    // Markers: punto central del círculo o números
                    // de cada vértice del polígono.
                    MarkerLayer(
                      markers: [
                        if (shape == ZonaShape.circulo && centroCirculo != null)
                          Marker(
                            point: centroCirculo!,
                            width: 24,
                            height: 24,
                            child: Icon(
                              Icons.place,
                              color: c.brand,
                              size: 24,
                              shadows: const [
                                Shadow(color: Colors.black54, blurRadius: 4),
                              ],
                            ),
                          ),
                        if (shape == ZonaShape.poligono)
                          ...vertices.asMap().entries.map((e) {
                            return Marker(
                              point: e.value,
                              width: 28,
                              height: 28,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: c.brand,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: c.text, width: 2),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  '${e.key + 1}',
                                  style: AppType.monoSm.copyWith(
                                    color: c.brandFg,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            );
                          }),
                      ],
                    ),
                  ],
                ),
                // Botones flotantes — esquina superior derecha
                Positioned(
                  top: AppSpacing.sm,
                  right: AppSpacing.sm,
                  child: Column(
                    children: [
                      if (MapConstants.tieneMapbox)
                        _BotonMapa(
                          icon: vistaSatelital
                              ? Icons.map_outlined
                              : Icons.satellite_alt,
                          tooltip:
                              vistaSatelital ? 'Vista mapa' : 'Vista satélite',
                          onPressed: onToggleSatelital,
                        ),
                      const SizedBox(height: 4),
                      _BotonMapa(
                        icon: Icons.center_focus_strong,
                        tooltip: 'Centrar en la zona',
                        onPressed: onCentrar,
                      ),
                    ],
                  ),
                ),
                // Botones para polígono — esquina inferior izquierda
                if (shape == ZonaShape.poligono && vertices.isNotEmpty)
                  Positioned(
                    bottom: AppSpacing.sm,
                    left: AppSpacing.sm,
                    child: Row(
                      children: [
                        _BotonMapa(
                          icon: Icons.undo,
                          tooltip: 'Deshacer último punto',
                          onPressed: onDeshacerVertice,
                        ),
                        const SizedBox(width: 4),
                        _BotonMapa(
                          icon: Icons.delete_sweep,
                          tooltip: 'Limpiar todos los puntos',
                          onPressed: () => onLimpiarVertices?.call(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Botón circular semi-transparente para acciones del mini mapa.
/// Más compacto que un FAB normal y consistente entre acciones.
class _BotonMapa extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _BotonMapa({
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.surface2.withValues(alpha: 0.92),
      shape: CircleBorder(side: BorderSide(color: c.border)),
      child: IconButton(
        icon: Icon(icon, size: 18, color: c.text),
        tooltip: tooltip,
        constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
