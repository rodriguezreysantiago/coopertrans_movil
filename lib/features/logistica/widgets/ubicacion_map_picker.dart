// Bottom sheet para elegir un punto geográfico sobre OpenStreetMap.
//
// Flujo:
//   1. Operador toca "Elegir en mapa" en el form de ubicación.
//   2. Se abre este sheet con el mapa centrado (en el punto actual si
//      existía, o en Bahía Blanca como default — base operativa de
//      Vecchi).
//   3. Operador puede:
//      - Buscar por texto (Nominatim) → la lista de resultados centra
//        el mapa al elegir.
//      - Mover el mapa → el crosshair central marca el punto.
//      - Tocar "Confirmar" → al volver, el caller recibe lat/lng +
//        localidad/provincia/dirección del reverse geocoding.
//
// Decisión: crosshair fijo (no marker arrastrable). Más simple
// visualmente y evita confusiones de gesture (el mapa se mueve
// debajo del crosshair, el centro siempre es el punto).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../services/logistica_geo_utils.dart';

class UbicacionMapPickerResultado {
  final LatLng punto;
  final String? localidad;
  final String? provincia;
  final String? direccion;

  const UbicacionMapPickerResultado({
    required this.punto,
    this.localidad,
    this.provincia,
    this.direccion,
  });
}

class UbicacionMapPicker extends StatefulWidget {
  final LatLng? puntoInicial;
  final String? hintBusqueda;

  const UbicacionMapPicker({
    super.key,
    this.puntoInicial,
    this.hintBusqueda,
  });

  /// Helper para abrir el picker como bottom sheet y devolver el
  /// resultado. Devuelve null si el operador cancela.
  static Future<UbicacionMapPickerResultado?> abrir(
    BuildContext context, {
    LatLng? puntoInicial,
    String? hintBusqueda,
  }) {
    return showModalBottomSheet<UbicacionMapPickerResultado>(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) => UbicacionMapPicker(
        puntoInicial: puntoInicial,
        hintBusqueda: hintBusqueda,
      ),
    );
  }

  @override
  State<UbicacionMapPicker> createState() => _UbicacionMapPickerState();
}

class _UbicacionMapPickerState extends State<UbicacionMapPicker> {
  // Default: Bahía Blanca, base operativa de Vecchi. Si el operador
  // está editando una ubicación que ya tenía coords, arrancamos ahí.
  static const _defaultBahiaBlanca = LatLng(-38.7167, -62.2667);

  late final MapController _mapCtl;
  late LatLng _puntoCentral;
  final _busquedaCtl = TextEditingController();
  Timer? _debounce;
  List<GeoLugar> _resultados = const [];
  bool _buscando = false;
  bool _confirmando = false;
  String? _errorBusqueda;

  @override
  void initState() {
    super.initState();
    _mapCtl = MapController();
    _puntoCentral = widget.puntoInicial ?? _defaultBahiaBlanca;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _busquedaCtl.dispose();
    _mapCtl.dispose();
    super.dispose();
  }

  void _onCambioBusqueda(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() {
        _resultados = const [];
        _errorBusqueda = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      setState(() {
        _buscando = true;
        _errorBusqueda = null;
      });
      try {
        final hits = await LogisticaGeoUtils.buscar(q);
        if (!mounted) return;
        setState(() {
          _resultados = hits;
          _buscando = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _resultados = const [];
          _buscando = false;
          _errorBusqueda = 'No pude buscar (sin red?). Probá de nuevo.';
        });
      }
    });
  }

  void _seleccionarResultado(GeoLugar lugar) {
    FocusScope.of(context).unfocus();
    setState(() {
      _puntoCentral = lugar.punto;
      _resultados = const [];
      _busquedaCtl.text = lugar.displayName.split(',').take(2).join(',').trim();
    });
    _mapCtl.move(lugar.punto, 13);
  }

  Future<void> _confirmar() async {
    setState(() => _confirmando = true);
    GeoLugar? reverso;
    try {
      reverso = await LogisticaGeoUtils.reverso(_puntoCentral);
    } catch (_) {
      // Best-effort: si reverse falla (sin red), devolvemos solo
      // las coords. El operador puede llenar localidad/provincia
      // a mano.
      reverso = null;
    }
    if (!mounted) return;
    Navigator.pop(
      context,
      UbicacionMapPickerResultado(
        punto: _puntoCentral,
        localidad: reverso?.localidad,
        provincia: reverso?.provincia,
        direccion: reverso?.direccion,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.95,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (ctx, scrollController) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header con título
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Icon(Icons.map_outlined, color: AppColors.accentBlue),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Elegir punto en el mapa',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Buscador + sugerencias
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _busquedaCtl,
              onChanged: _onCambioBusqueda,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                isDense: true,
                hintText: widget.hintBusqueda ?? 'Buscar lugar (ej. Tres Arroyos)',
                hintStyle: const TextStyle(color: Colors.white38),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                suffixIcon: _buscando
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accentBlue,
                          ),
                        ),
                      )
                    : (_busquedaCtl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close, color: Colors.white54),
                            onPressed: () {
                              _busquedaCtl.clear();
                              setState(() => _resultados = const []);
                            },
                          )
                        : null),
                filled: true,
                fillColor: Colors.white10,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_errorBusqueda != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                _errorBusqueda!,
                style: const TextStyle(color: AppColors.accentRed, fontSize: 12),
              ),
            ),
          if (_resultados.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              decoration: BoxDecoration(
                color: Colors.white10,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _resultados.length,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  color: Colors.white12,
                ),
                itemBuilder: (_, i) {
                  final r = _resultados[i];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined,
                        color: Colors.white54, size: 18),
                    title: Text(
                      r.displayName,
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => _seleccionarResultado(r),
                  );
                },
              ),
            ),
          const SizedBox(height: 8),
          // Mapa con crosshair fijo
          Expanded(
            child: Stack(
              alignment: Alignment.center,
              children: [
                FlutterMap(
                  mapController: _mapCtl,
                  options: MapOptions(
                    initialCenter: _puntoCentral,
                    initialZoom: widget.puntoInicial != null ? 13 : 6,
                    minZoom: 4,
                    maxZoom: 18,
                    onPositionChanged: (pos, _) {
                      // Capturar el centro continuamente para que el
                      // confirmar use el punto donde quedó el mapa.
                      _puntoCentral = pos.center;
                    },
                  ),
                  children: [
                    TileLayer(
                      urlTemplate: MapConstants.tileUrl,
                      subdomains: MapConstants.tileSubdomains,
                      userAgentPackageName: MapConstants.userAgent,
                      maxZoom: 19,
                    ),
                  ],
                ),
                // Crosshair central
                IgnorePointer(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.accentBlue.withValues(alpha: 0.2),
                          border: Border.all(
                            color: AppColors.accentBlue,
                            width: 2,
                          ),
                        ),
                      ),
                      // Espacio igual a la mitad de la altura del pin
                      // para alinear con la base del marker visual.
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Footer con coords actuales + botones
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            color: Colors.black26,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Builder(builder: (_) {
                  return Text(
                    'Punto seleccionado: '
                    '${_puntoCentral.latitude.toStringAsFixed(5)}, '
                    '${_puntoCentral.longitude.toStringAsFixed(5)}',
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                    textAlign: TextAlign.center,
                  );
                }),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: _confirmando
                            ? null
                            : () => Navigator.pop(context),
                        child: const Text('CANCELAR'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _confirmando ? null : _confirmar,
                        icon: _confirmando
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.check),
                        label: const Text('CONFIRMAR'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.accentBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
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
