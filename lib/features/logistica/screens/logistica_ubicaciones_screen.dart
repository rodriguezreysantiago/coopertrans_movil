// lib/features/logistica/screens/logistica_ubicaciones_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — ABM de ubicaciones en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream `LogisticaService.streamUbicaciones`, el filtro token-based
//     (`_aplicarFiltro`), el alta (`_AltaUbicacionDialog` +
//     `crearUbicacion`), la edición inline (sheet + `actualizarUbicacion`),
//     la eliminación con check de referencias server-side,
//   - TODA la lógica de mapa: `UbicacionMapPicker.abrir`, el reverse
//     geocoding/autocompletar, el parseo de links de Google Maps
//     (`GoogleMapsUrlParser`), `AccionesNavegacionSheet`, `MiniMapaThumbnail`,
//   - las validaciones de lat/lng (rango, 0/0 océano, parseable) y los
//     atajos de teclado (`KeyboardShortcutsScope`).
//
// Material en formularios: los TextField del alta (lat/lng, nombre, etc.),
// los `DatoEditable*` del sheet y el dialog de "pegar link" siguen siendo
// Material reskineado por el theme — NO se tocan para no romper la lógica
// de persistencia/geo. Lo que cambió es la superficie: buscador Núcleo
// (AppInput), cards re-skineadas a tokens (AppCard tier-1 + coords mono +
// AppBadge), FAB brand, bloque de coordenadas a tokens.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/empresa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_service.dart';
import '../utils/google_maps_url.dart';
import '../widgets/acciones_navegacion_sheet.dart';
import '../widgets/mini_mapa_thumbnail.dart';
import '../widgets/ubicacion_map_picker.dart';

/// ABM de ubicaciones físicas (puntos de carga / descarga). Reusable
/// entre tarifas: una misma ubicación puede ser origen de una tarifa y
/// destino de otra.
class LogisticaUbicacionesScreen extends StatefulWidget {
  const LogisticaUbicacionesScreen({super.key});

  @override
  State<LogisticaUbicacionesScreen> createState() =>
      _LogisticaUbicacionesScreenState();
}

class _LogisticaUbicacionesScreenState
    extends State<LogisticaUbicacionesScreen> {
  /// Filtro de búsqueda — se aplica client-side sobre el resultado
  /// del stream (no hay índices Firestore para LIKE/contains). Como
  /// son ~50-200 ubicaciones max, el filtrado en memoria es
  /// instantáneo. Match por nombre, localidad, provincia y dirección
  /// (todo case-insensitive).
  String _filtro = '';
  final FocusNode _buscarFocus = FocusNode();
  late final TextEditingController _buscarCtrl;

  @override
  void initState() {
    super.initState();
    _buscarCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _buscarCtrl.dispose();
    _buscarFocus.dispose();
    super.dispose();
  }

  /// Filtra la lista por el texto tipeado. Tokeniza por espacios y
  /// exige que TODOS los tokens estén presentes en algún campo de la
  /// ubicación — permite buscar "puerto bahia" y matchear "Puerto
  /// Galván — Bahía Blanca".
  List<UbicacionLogistica> _aplicarFiltro(List<UbicacionLogistica> items) {
    final q = _filtro.trim().toLowerCase();
    if (q.isEmpty) return items;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return items.where((u) {
      final hay = [
        u.nombre,
        u.localidad,
        u.provincia,
        u.direccion ?? '',
        u.empresaNombres.join(' '),
      ].join(' ').toLowerCase();
      for (final t in tokens) {
        if (!hay.contains(t)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Ubicaciones',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.brand,
          foregroundColor: AppColors.surface0,
          onPressed: () => _abrirAlta(ctx),
          icon: const Icon(Icons.add),
          label: const Text('NUEVA UBICACIÓN'),
        ),
      ),
      body: KeyboardShortcutsScope(
        onNuevo: () => _abrirAlta(context),
        buscarFocusNode: _buscarFocus,
        child: Column(
          children: [
            // Buscador Núcleo (misma lógica de filtro token-based).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
              child: AppInput(
                controller: _buscarCtrl,
                focusNode: _buscarFocus,
                hint: 'Buscar por nombre, localidad, empresa…',
                icon: Icons.search,
                onChanged: (v) => setState(() => _filtro = v),
                trailingAction: _filtro.isEmpty ? null : 'Limpiar',
                onTrailingTap: _filtro.isEmpty
                    ? null
                    : () {
                        _buscarCtrl.clear();
                        setState(() => _filtro = '');
                      },
              ),
            ),
            Expanded(
              child: StreamBuilder<List<UbicacionLogistica>>(
                stream: LogisticaService.streamUbicaciones(),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const AppSkeletonList(count: 8, conAvatar: false);
                  }
                  if (snap.hasError) {
                    return AppErrorState(
                      title: 'Error cargando la lista',
                      subtitle: snap.error.toString(),
                    );
                  }
                  final items = snap.data ?? const [];
                  if (items.isEmpty) {
                    return const AppEmptyState(
                      icon: Icons.place_outlined,
                      title: 'Sin ubicaciones cargadas',
                      subtitle:
                          'Tocá + para agregar la primera (silos, plantas, '
                          'puertos, fábricas).',
                    );
                  }
                  final filtrados = _aplicarFiltro(items);
                  if (filtrados.isEmpty) {
                    return AppEmptyState(
                      icon: Icons.search_off,
                      title: 'Sin resultados',
                      subtitle:
                          'Ninguna ubicación coincide con "$_filtro". Probá '
                          'con otra palabra o limpiá el filtro.',
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 90),
                    itemCount: filtrados.length,
                    itemBuilder: (_, i) =>
                        _CardUbicacion(ubicacion: filtrados[i]),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _abrirAlta(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const _AltaUbicacionDialog(),
    );
  }
}

class _CardUbicacion extends StatelessWidget {
  final UbicacionLogistica ubicacion;
  const _CardUbicacion({required this.ubicacion});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activa = ubicacion.activa;
    final accent = activa ? c.brand : c.textMuted;
    final tieneCoords = ubicacion.lat != null && ubicacion.lng != null;

    return AppCard(
      tier: 1,
      accent: accent,
      onTap: () => _abrirEdicion(context),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          // Thumbnail del mapa si tiene coords; sino ícono genérico.
          if (tieneCoords)
            MiniMapaThumbnail(
              lat: ubicacion.lat!,
              lng: ubicacion.lng!,
              size: 56,
            )
          else
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: c.surface3,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(Icons.place_outlined, color: accent, size: 24),
            ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ubicacion.nombre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: activa ? c.text : c.textMuted,
                    fontWeight: FontWeight.w700,
                    decoration: activa
                        ? TextDecoration.none
                        : TextDecoration.lineThrough,
                  ),
                ),
                if (ubicacion.empresaNombres.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(Icons.business_outlined, color: c.textMuted, size: 12),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          ubicacion.etiquetaEmpresas,
                          style: AppType.monoSm.copyWith(color: c.textSecondary),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  ubicacion.etiquetaCompleta,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodySm.copyWith(color: c.textMuted),
                ),
                if (tieneCoords) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Icon(Icons.my_location, color: c.brand, size: 12),
                      const SizedBox(width: AppSpacing.xs),
                      Flexible(
                        child: Text(
                          '${ubicacion.lat!.toStringAsFixed(4)}, '
                          '${ubicacion.lng!.toStringAsFixed(4)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.monoSm.copyWith(color: c.textSecondary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      InkWell(
                        onTap: () => AccionesNavegacionSheet.abrir(
                          context,
                          lat: ubicacion.lat!,
                          lng: ubicacion.lng!,
                          label: ubicacion.nombre,
                        ),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.navigation_outlined,
                            color: c.brand,
                            size: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Botón eliminar directo desde la card. Antes había un
          // Switch activa/inactiva acá, pero el operador NO usa el
          // estado inactivo (Santiago 2026-05-12): si no usa más la
          // ubicación, la borra. El check de referencias en tarifas
          // del service evita borrar algo que esté en uso.
          IconButton(
            icon: Icon(Icons.delete_outline, color: c.error, size: 18),
            tooltip: 'Eliminar ubicación',
            onPressed: () => _confirmarEliminar(context),
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Future<void> _abrirEdicion(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: context.colors.surface2,
      isScrollControlled: true,
      builder: (_) => _EditarUbicacionSheet(ubicacion: ubicacion),
    );
  }

  /// Confirma con AlertDialog + llama al service. Si la ubicación
  /// está en uso por alguna tarifa, el service tira StateError con
  /// mensaje accionable que mostramos en SnackBar.
  Future<void> _confirmarEliminar(BuildContext context) async {
    final c = context.colors;
    final messenger = ScaffoldMessenger.of(context);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: dCtx.colors.surface2,
        title: const Text('¿Eliminar ubicación?'),
        content: Text(
          '${ubicacion.nombre}\n\n'
          'Esta acción no se puede deshacer. Si la ubicación está usada '
          'por alguna tarifa, no se va a poder borrar.',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.of(dCtx).pop(false),
          ),
          AppButton.danger(
            label: 'Eliminar',
            onPressed: () => Navigator.of(dCtx).pop(true),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await LogisticaService.eliminarUbicacion(ubicacion.id);
      AppFeedback.successOn(messenger, 'Ubicación eliminada.');
    } on StateError catch (e) {
      AppFeedback.errorOn(messenger, e.message);
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar la ubicación. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

// =============================================================================
// EDICIÓN INLINE
// =============================================================================

class _EditarUbicacionSheet extends StatefulWidget {
  final UbicacionLogistica ubicacion;
  const _EditarUbicacionSheet({required this.ubicacion});

  @override
  State<_EditarUbicacionSheet> createState() => _EditarUbicacionSheetState();
}

class _EditarUbicacionSheetState extends State<_EditarUbicacionSheet> {
  late UbicacionLogistica _ubicacion;

  @override
  void initState() {
    super.initState();
    _ubicacion = widget.ubicacion;
  }

  Future<void> _setCampo(String campo, dynamic valor) async {
    await LogisticaService.actualizarUbicacion(
      id: _ubicacion.id,
      cambios: {campo: valor},
    );
    // Refrescar la copia local inmediatamente — sin esto, el sheet
    // sigue mostrando el valor viejo hasta que el stream emita la
    // versión actualizada y se rebuilde el padre. En celus lentos el
    // delay es perceptible y al user le parece que "no se guardó".
    if (!mounted) return;
    setState(() {
      switch (campo) {
        case 'nombre':
          _ubicacion = _ubicacion.copyWith(nombre: valor as String);
          break;
        case 'localidad':
          _ubicacion = _ubicacion.copyWith(localidad: valor as String);
          break;
        case 'provincia':
          _ubicacion = _ubicacion.copyWith(provincia: valor as String);
          break;
        case 'direccion':
          _ubicacion = _ubicacion.copyWith(direccion: valor as String?);
          break;
        case 'activa':
          _ubicacion = _ubicacion.copyWith(activa: valor as bool);
          break;
        // lat/lng se actualizan vía _abrirPicker (lógica propia que
        // ya hace setState con coords + reverse geocoding).
      }
    });
  }

  Future<void> _abrirPicker() async {
    final res = await UbicacionMapPicker.abrir(
      context,
      puntoInicial: (_ubicacion.lat != null && _ubicacion.lng != null)
          ? LatLng(_ubicacion.lat!, _ubicacion.lng!)
          : null,
      hintBusqueda: _ubicacion.localidad,
    );
    if (res == null) return;
    // Aplicar lat/lng + autocompletar localidad/provincia/dirección
    // si vienen del reverse geocoding y los campos actuales están
    // vacíos. Si el operador ya cargó datos, NO los pisamos —
    // respeta el control manual.
    final cambios = <String, dynamic>{
      'lat': res.punto.latitude,
      'lng': res.punto.longitude,
    };
    if (_ubicacion.localidad.isEmpty && (res.localidad ?? '').isNotEmpty) {
      cambios['localidad'] = res.localidad;
    }
    if (_ubicacion.provincia.isEmpty && (res.provincia ?? '').isNotEmpty) {
      cambios['provincia'] = res.provincia;
    }
    if ((_ubicacion.direccion ?? '').isEmpty &&
        (res.direccion ?? '').isNotEmpty) {
      cambios['direccion'] = res.direccion;
    }
    await LogisticaService.actualizarUbicacion(
      id: _ubicacion.id,
      cambios: cambios,
    );
    // Refrescar localmente para que el sheet vea las coords nuevas
    // sin esperar al stream.
    if (mounted) {
      setState(() {
        _ubicacion = UbicacionLogistica(
          id: _ubicacion.id,
          nombre: _ubicacion.nombre,
          localidad: cambios['localidad'] ?? _ubicacion.localidad,
          provincia: cambios['provincia'] ?? _ubicacion.provincia,
          direccion: cambios['direccion'] ?? _ubicacion.direccion,
          lat: res.punto.latitude,
          lng: res.punto.longitude,
          activa: _ubicacion.activa,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(Icons.place_outlined, size: 16, color: c.brand),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    _ubicacion.nombre,
                    style: AppType.h5.copyWith(color: c.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
              children: [
                DatoEditableTexto(
                  etiqueta: 'Nombre / Alias',
                  valor: _ubicacion.nombre,
                  onSave: (v) => _setCampo('nombre', v),
                ),
                // [removido 2026-05-12] Sección "EMPRESAS QUE USAN
                // ESTA UBICACIÓN" eliminada por decisión de Santiago.
                // La asociación N:M empresa↔ubicación se gestiona
                // SOLO desde el sheet de empresa ("UBICACIONES DE
                // ESTA EMPRESA"), porque conceptualmente operás
                // primero por empresa (Cargill carga en X, Y, Z)
                // y no por ubicación. El campo `empresa_ids` del
                // doc UBICACION sigue persistiéndose desde el
                // service de empresa — el binding es bidireccional
                // a nivel de datos aunque la UI lo edite por un
                // solo lado.
                DatoEditableTexto(
                  etiqueta: 'Localidad',
                  valor: _ubicacion.localidad,
                  aplicarMayusculas: false,
                  onSave: (v) => _setCampo('localidad', v.trim()),
                ),
                DatoEditableTexto(
                  etiqueta: 'Provincia',
                  valor: _ubicacion.provincia,
                  aplicarMayusculas: false,
                  onSave: (v) => _setCampo('provincia', v.trim()),
                ),
                DatoEditableTexto(
                  etiqueta: 'Dirección (opcional)',
                  valor: _ubicacion.direccion ?? '',
                  aplicarMayusculas: false,
                  onSave: (v) => _setCampo(
                    'direccion',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                _FilaCoords(
                  lat: _ubicacion.lat,
                  lng: _ubicacion.lng,
                  onElegirEnMapa: _abrirPicker,
                  onLatManual: (v) => _setCampo('lat', v),
                  onLngManual: (v) => _setCampo('lng', v),
                ),
                const SizedBox(height: AppSpacing.xl),
                // Botón de eliminación con check de referencias en
                // tarifas. Si la ubicación está en uso, el service
                // tira StateError con un mensaje accionable que
                // mostramos al operador.
                AppButton.danger(
                  label: 'Eliminar ubicación',
                  icon: Icons.delete_outline,
                  full: true,
                  onPressed: _eliminar,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Confirma con el operador + elimina la ubicación si no está en
  /// uso. Si está usada por tarifas, el service tira un StateError con
  /// mensaje claro y lo mostramos en SnackBar.
  Future<void> _eliminar() async {
    final c = context.colors;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: dCtx.colors.surface2,
        title: const Text('¿Eliminar ubicación?'),
        content: Text(
          '${_ubicacion.nombre}\n\n'
          'Esta acción no se puede deshacer. Si la ubicación está usada '
          'por alguna tarifa, no se va a poder borrar.',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.of(dCtx).pop(false),
          ),
          AppButton.danger(
            label: 'Eliminar',
            onPressed: () => Navigator.of(dCtx).pop(true),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await LogisticaService.eliminarUbicacion(_ubicacion.id);
      if (!mounted) return;
      navigator.pop(); // Cerrar el bottom sheet.
      AppFeedback.successOn(messenger, 'Ubicación eliminada.');
    } on StateError catch (e) {
      if (!mounted) return;
      AppFeedback.errorOn(messenger, e.message);
    } catch (e, s) {
      if (!mounted) return;
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar la ubicación. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

/// Fila visual de coordenadas con botón "Elegir en mapa" + edición
/// manual lat/lng. Reusable entre alta y edición.
class _FilaCoords extends StatelessWidget {
  final double? lat;
  final double? lng;
  final VoidCallback onElegirEnMapa;
  final ValueChanged<double?>? onLatManual;
  final ValueChanged<double?>? onLngManual;

  const _FilaCoords({
    required this.lat,
    required this.lng,
    required this.onElegirEnMapa,
    this.onLatManual,
    this.onLngManual,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tieneCoords = lat != null && lng != null;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.my_location, color: c.brand, size: 16),
              const SizedBox(width: AppSpacing.sm),
              const Expanded(
                child: AppEyebrow('Coordenadas geográficas'),
              ),
              if (tieneCoords)
                Text(
                  '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
            ],
          ),
          if (!tieneCoords) ...[
            const SizedBox(height: 6),
            Text(
              'Sin coordenadas. Elegí un punto en el mapa para que '
              'aparezca en el mapa de tarifas y se calcule la distancia.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            label: tieneCoords ? 'Cambiar en mapa' : 'Elegir en mapa',
            icon: Icons.map_outlined,
            size: AppButtonSize.sm,
            full: true,
            onPressed: onElegirEnMapa,
          ),
          // Alternativa rápida: pegar el link de Google Maps. Lo
          // parseamos al toque y aplicamos las coords. Atajo útil
          // cuando el operador ya buscó el lugar en Google Maps
          // (más rápido que volver a buscarlo en el picker).
          if (onLatManual != null && onLngManual != null) ...[
            const SizedBox(height: 6),
            AppButton.ghost(
              label: 'Pegar link de Google Maps',
              icon: Icons.link,
              size: AppButtonSize.sm,
              full: true,
              onPressed: () => _pegarLinkGoogleMaps(context),
            ),
          ],
        ],
      ),
    );
  }

  /// Diálogo que pide pegar un link / coords de Google Maps y, si
  /// puede parsear lat/lng, los aplica. Soporta varios formatos —
  /// ver `GoogleMapsUrlParser` para el detalle.
  Future<void> _pegarLinkGoogleMaps(BuildContext context) async {
    final ctrl = TextEditingController();
    final messenger = ScaffoldMessenger.of(context);
    final ({double lat, double lng})? result;
    try {
      result = await showDialog<({double lat, double lng})?>(
        context: context,
        builder: (dCtx) {
          final c = dCtx.colors;
          return AlertDialog(
            backgroundColor: c.surface2,
            title: const Text('Pegar link de Google Maps'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Pegá el link completo de Google Maps o las coordenadas:',
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Ej. "https://www.google.com/maps/place/.../@-38.71,-62.27,15z" '
                  'o "-38.71, -62.27".',
                  style: AppType.eyebrow.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                    hintText: 'Pegá acá…',
                  ),
                ),
              ],
            ),
            actions: [
              AppButton.ghost(
                label: 'Cancelar',
                onPressed: () => Navigator.of(dCtx).pop(null),
              ),
              AppButton.primary(
                label: 'Aplicar',
                onPressed: () {
                  final input = ctrl.text;
                  if (GoogleMapsUrlParser.esShortUrl(input)) {
                    // Las short URLs requerirían un HTTP request para
                    // expandirlas — no vale la pena el flow, mejor que el
                    // operador la abra en el browser primero.
                    Navigator.of(dCtx).pop(null);
                    AppFeedback.warningOn(
                      messenger,
                      'Es un link acortado (goo.gl). Abrilo en el browser '
                      'para que se expanda, después copiá el link largo de '
                      'la barra de direcciones y pegalo acá.',
                    );
                    return;
                  }
                  final coords = GoogleMapsUrlParser.extraer(input);
                  Navigator.of(dCtx).pop(coords);
                },
              ),
            ],
          );
        },
      );
    } finally {
      ctrl.dispose();
    }
    if (result == null) return;
    onLatManual?.call(result.lat);
    onLngManual?.call(result.lng);
    AppFeedback.successOn(
      messenger,
      'Coordenadas aplicadas: ${result.lat.toStringAsFixed(5)}, '
      '${result.lng.toStringAsFixed(5)}.',
    );
  }
}

// =============================================================================
// ALTA
// =============================================================================

class _AltaUbicacionDialog extends StatefulWidget {
  const _AltaUbicacionDialog();

  @override
  State<_AltaUbicacionDialog> createState() => _AltaUbicacionDialogState();
}

class _AltaUbicacionDialogState extends State<_AltaUbicacionDialog> {
  final _nombreCtrl = TextEditingController();
  final _localidadCtrl = TextEditingController();
  final _provinciaCtrl = TextEditingController();
  final _direccionCtrl = TextEditingController();
  final _latCtrl = TextEditingController();
  final _lngCtrl = TextEditingController();
  // Empresas que usan esta ubicación (M:N). Lista vacía permitida —
  // el operador puede asociar después desde la edición inline.
  final List<EmpresaLogistica> _empresas = [];
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _localidadCtrl.dispose();
    _provinciaCtrl.dispose();
    _direccionCtrl.dispose();
    _latCtrl.dispose();
    _lngCtrl.dispose();
    super.dispose();
  }

  Future<void> _abrirPicker() async {
    final latActual = double.tryParse(_latCtrl.text.trim());
    final lngActual = double.tryParse(_lngCtrl.text.trim());
    final res = await UbicacionMapPicker.abrir(
      context,
      puntoInicial: (latActual != null && lngActual != null)
          ? LatLng(latActual, lngActual)
          : null,
      hintBusqueda: _localidadCtrl.text.trim().isEmpty
          ? null
          : _localidadCtrl.text.trim(),
    );
    if (res == null) return;
    setState(() {
      _latCtrl.text = res.punto.latitude.toStringAsFixed(6);
      _lngCtrl.text = res.punto.longitude.toStringAsFixed(6);
      // Autocompletar campos del form si el operador no los llenó
      // todavía. Si ya tipeaba algo, NO pisamos.
      if (_localidadCtrl.text.trim().isEmpty &&
          (res.localidad ?? '').isNotEmpty) {
        _localidadCtrl.text = res.localidad!;
      }
      if (_provinciaCtrl.text.trim().isEmpty &&
          (res.provincia ?? '').isNotEmpty) {
        _provinciaCtrl.text = res.provincia!;
      }
      if (_direccionCtrl.text.trim().isEmpty &&
          (res.direccion ?? '').isNotEmpty) {
        _direccionCtrl.text = res.direccion!;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface2,
      title: const Text('Nueva ubicación'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 400.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nombreCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Nombre / Alias *',
                  hintText: 'Ej. ACOPIO LARTIRIGOYEN — TRES ARROYOS',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              // [removido 2026-05-12] Selector de empresas removido
              // del alta de ubicación — la asociación N:M se gestiona
              // SOLO desde el sheet de empresa ("UBICACIONES DE ESTA
              // EMPRESA"). Se da de alta la ubicación sola y después
              // el operador entra a las empresas que la usan y la
              // marca ahí.
              TextField(
                controller: _localidadCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Localidad *',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _provinciaCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Provincia *',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextField(
                controller: _direccionCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dirección (opcional)',
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              // Bloque coords: 2 TextFields + botón "Elegir en mapa".
              // El picker autocompleta lat/lng y, si están vacíos,
              // localidad/provincia/dirección via reverse geocoding.
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.surface1,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const AppEyebrow('Coordenadas (opcional)'),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _latCtrl,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true, signed: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.\-]')),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Latitud',
                              hintText: '-38.7167',
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: TextField(
                            controller: _lngCtrl,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true, signed: true),
                            inputFormatters: [
                              FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.\-]')),
                            ],
                            decoration: const InputDecoration(
                              labelText: 'Longitud',
                              hintText: '-62.2667',
                              isDense: true,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    AppButton.secondary(
                      label: 'Elegir en mapa',
                      icon: Icons.map_outlined,
                      size: AppButtonSize.sm,
                      full: true,
                      onPressed: _abrirPicker,
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Text(
                  _error!,
                  style: AppType.bodySm.copyWith(color: c.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: _guardando ? null : () => Navigator.pop(context),
        ),
        AppButton.primary(
          label: 'Guardar',
          loading: _guardando,
          onPressed: _guardando ? null : _guardar,
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    final nombre = _nombreCtrl.text.trim();
    final localidad = _localidadCtrl.text.trim();
    final provincia = _provinciaCtrl.text.trim();
    if (nombre.isEmpty || localidad.isEmpty || provincia.isEmpty) {
      setState(() => _error = 'Nombre, localidad y provincia son obligatorios.');
      return;
    }
    // Lat/lng son opcionales pero si están deben ser parseables y
    // dentro de rangos válidos. Si uno está y el otro no, error.
    final latStr = _latCtrl.text.trim();
    final lngStr = _lngCtrl.text.trim();
    double? lat;
    double? lng;
    if (latStr.isNotEmpty || lngStr.isNotEmpty) {
      lat = double.tryParse(latStr);
      lng = double.tryParse(lngStr);
      if (lat == null || lng == null) {
        setState(() => _error =
            'Latitud y longitud deben ser números (formato -38.7167).');
        return;
      }
      if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        setState(() => _error =
            'Latitud entre -90 y 90, longitud entre -180 y 180.');
        return;
      }
      // CRITICO (auditoria 2026-05-17): lat=0, lng=0 cae en el oceano
      // Atlantico (Golfo de Guinea). Default cuando el operador entra
      // al picker pero no mueve el pin, o tipea "0" como placeholder.
      // Si no tenes coordenadas, dejar AMBOS campos vacios (ya esta
      // soportado arriba con `coordsVacias`).
      if (lat == 0 && lng == 0) {
        setState(() => _error =
            'Coordenadas 0,0 invalidas (cae en oceano). '
            'Si no tenes coordenadas, deja ambos campos vacios.');
        return;
      }
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await LogisticaService.crearUbicacion(
        nombre: nombre,
        localidad: localidad,
        provincia: provincia,
        direccion: _direccionCtrl.text.trim().isEmpty
            ? null
            : _direccionCtrl.text.trim(),
        lat: lat,
        lng: lng,
        empresaIds: _empresas.map((e) => e.id).toList(),
        empresaNombres: _empresas.map((e) => e.nombre).toList(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _guardando = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Z][a-z]+: '), '');
      });
    }
  }
}
