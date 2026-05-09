import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../models/empresa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_service.dart';
import '../widgets/acciones_navegacion_sheet.dart';
import '../widgets/mini_mapa_thumbnail.dart';
import '../widgets/ubicacion_map_picker.dart';

/// ABM de ubicaciones físicas (puntos de carga / descarga). Reusable
/// entre tarifas: una misma ubicación puede ser origen de una tarifa y
/// destino de otra.
class LogisticaUbicacionesScreen extends StatelessWidget {
  const LogisticaUbicacionesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Ubicaciones',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.accentTeal,
          onPressed: () => _abrirAlta(ctx),
          icon: const Icon(Icons.add),
          label: const Text('NUEVA UBICACIÓN'),
        ),
      ),
      body: StreamBuilder<List<UbicacionLogistica>>(
        stream: LogisticaService.streamUbicaciones(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return AppEmptyState(
              icon: Icons.error_outline,
              title: 'Error cargando la lista',
              subtitle: snap.error.toString(),
            );
          }
          final items = snap.data ?? const [];
          if (items.isEmpty) {
            return const AppEmptyState(
              icon: Icons.place_outlined,
              title: 'Sin ubicaciones cargadas',
              subtitle: 'Tocá + para agregar la primera (silos, plantas, '
                  'puertos, fábricas).',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _CardUbicacion(ubicacion: items[i]),
          );
        },
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
    final color =
        ubicacion.activa ? AppColors.accentTeal : Colors.white24;
    return AppCard(
      onTap: () => _abrirEdicion(context),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          // Thumbnail del mapa si tiene coords; sino ícono genérico.
          if (ubicacion.lat != null && ubicacion.lng != null)
            MiniMapaThumbnail(
              lat: ubicacion.lat!,
              lng: ubicacion.lng!,
              size: 56,
            )
          else
            Icon(Icons.place, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ubicacion.nombre,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        ubicacion.activa ? Colors.white : Colors.white38,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    decoration: ubicacion.activa
                        ? TextDecoration.none
                        : TextDecoration.lineThrough,
                  ),
                ),
                if (ubicacion.empresaNombres.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      const Icon(Icons.business_outlined,
                          color: AppColors.accentBlue, size: 12),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          ubicacion.etiquetaEmpresas,
                          style: const TextStyle(
                            color: AppColors.accentBlue,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
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
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
                if (ubicacion.lat != null && ubicacion.lng != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(Icons.my_location,
                          color: AppColors.accentTeal, size: 12),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${ubicacion.lat!.toStringAsFixed(4)}, '
                          '${ubicacion.lng!.toStringAsFixed(4)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.accentTeal,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => AccionesNavegacionSheet.abrir(
                          context,
                          lat: ubicacion.lat!,
                          lng: ubicacion.lng!,
                          label: ubicacion.nombre,
                        ),
                        child: const Padding(
                          padding: EdgeInsets.all(2),
                          child: Icon(
                            Icons.navigation_outlined,
                            color: AppColors.accentBlue,
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
          Switch(
            value: ubicacion.activa,
            onChanged: (v) => LogisticaService.actualizarUbicacion(
              id: ubicacion.id,
              cambios: {'activa': v},
            ),
            activeTrackColor: AppColors.accentTeal,
          ),
        ],
      ),
    );
  }

  Future<void> _abrirEdicion(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) => _EditarUbicacionSheet(ubicacion: ubicacion),
    );
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
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.place, color: AppColors.accentTeal),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _ubicacion.nombre,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                DatoEditableTexto(
                  etiqueta: 'Nombre / Alias',
                  valor: _ubicacion.nombre,
                  onSave: (v) => _setCampo('nombre', v),
                ),
                // Empresas que USAN esta ubicación. Una ubicación
                // puede tener varias (ej. Puerto de Quequén = CARGILL
                // + BUNGE + COFCO). Tap → bottom sheet con multi-select.
                _MultiEmpresaUbicacion(
                  empresaIds: _ubicacion.empresaIds,
                  empresaNombres: _ubicacion.empresaNombres,
                  onCambio: (ids, nombres) async {
                    await LogisticaService.setEmpresasDeUbicacion(
                      id: _ubicacion.id,
                      empresaIds: ids,
                      empresaNombres: nombres,
                    );
                    if (mounted) {
                      setState(() {
                        _ubicacion = UbicacionLogistica(
                          id: _ubicacion.id,
                          nombre: _ubicacion.nombre,
                          localidad: _ubicacion.localidad,
                          provincia: _ubicacion.provincia,
                          direccion: _ubicacion.direccion,
                          lat: _ubicacion.lat,
                          lng: _ubicacion.lng,
                          empresaIds: ids,
                          empresaNombres: nombres,
                          activa: _ubicacion.activa,
                        );
                      });
                    }
                  },
                ),
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
                const SizedBox(height: 16),
                _FilaCoords(
                  lat: _ubicacion.lat,
                  lng: _ubicacion.lng,
                  onElegirEnMapa: _abrirPicker,
                  onLatManual: (v) => _setCampo('lat', v),
                  onLngManual: (v) => _setCampo('lng', v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
    final tieneCoords = lat != null && lng != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.my_location,
                  color: AppColors.accentTeal, size: 18),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'COORDENADAS GEOGRÁFICAS',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (tieneCoords)
                Text(
                  '${lat!.toStringAsFixed(5)}, ${lng!.toStringAsFixed(5)}',
                  style: const TextStyle(
                    color: AppColors.accentTeal,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
            ],
          ),
          if (!tieneCoords) ...[
            const SizedBox(height: 6),
            const Text(
              'Sin coordenadas. Elegí un punto en el mapa para que '
              'aparezca en el mapa de tarifas y se calcule la distancia.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: onElegirEnMapa,
            icon: const Icon(Icons.map_outlined),
            label: Text(tieneCoords ? 'CAMBIAR EN MAPA' : 'ELEGIR EN MAPA'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentTeal,
              side: const BorderSide(color: AppColors.accentTeal),
            ),
          ),
        ],
      ),
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
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: const Text('Nueva ubicación'),
      content: SizedBox(
        width: 400,
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
              const SizedBox(height: 8),
              // Empresas que USAN esta ubicación. Multi-select —
              // una misma ubicación física la pueden compartir varias
              // empresas (ej. Puerto de Quequén = CARGILL + BUNGE +
              // COFCO). Opcional: si se deja vacío, queda sin
              // asociar y el operador la edita después.
              _MultiEmpresaUbicacion(
                empresaIds: _empresas.map((e) => e.id).toList(),
                empresaNombres: _empresas.map((e) => e.nombre).toList(),
                onCambio: (ids, nombres) {
                  setState(() {
                    _empresas
                      ..clear()
                      ..addAll(
                        ids.asMap().entries.map(
                          (entry) => EmpresaLogistica(
                            id: entry.value,
                            nombre: nombres[entry.key],
                            tipo: TipoEmpresaLogistica.cliente,
                          ),
                        ),
                      );
                  });
                },
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _localidadCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Localidad *',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _provinciaCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Provincia *',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _direccionCtrl,
                decoration: const InputDecoration(
                  labelText: 'Dirección (opcional)',
                ),
              ),
              const SizedBox(height: 14),
              // Bloque coords: 2 TextFields + botón "Elegir en mapa".
              // El picker autocompleta lat/lng y, si están vacíos,
              // localidad/provincia/dirección via reverse geocoding.
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'COORDENADAS (OPCIONAL)',
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
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
                        const SizedBox(width: 8),
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
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _abrirPicker,
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('ELEGIR EN MAPA'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.accentTeal,
                        side: const BorderSide(color: AppColors.accentTeal),
                      ),
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: const TextStyle(color: AppColors.accentRed)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('GUARDAR'),
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

// =============================================================================
// MULTI-SELECTOR DE EMPRESAS — una ubicación física puede ser usada
// por varias empresas (ej. Puerto de Quequén = CARGILL + BUNGE +
// COFCO). Muestra chips con cada empresa asociada + botón "+" para
// abrir un bottom sheet con buscador y multi-select (checkboxes).
// =============================================================================

class _MultiEmpresaUbicacion extends StatelessWidget {
  final List<String> empresaIds;
  final List<String> empresaNombres;
  final void Function(List<String> ids, List<String> nombres) onCambio;

  const _MultiEmpresaUbicacion({
    required this.empresaIds,
    required this.empresaNombres,
    required this.onCambio,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.business_outlined,
                  color: AppColors.accentBlue, size: 16),
              SizedBox(width: 6),
              Text(
                'EMPRESAS QUE USAN ESTA UBICACIÓN',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (empresaNombres.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'Sin empresas asignadas',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(empresaIds.length, (i) {
                final nombre = i < empresaNombres.length
                    ? empresaNombres[i]
                    : empresaIds[i];
                return Chip(
                  label: Text(
                    nombre,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  backgroundColor:
                      AppColors.accentBlue.withValues(alpha: 0.25),
                  side: BorderSide(
                    color: AppColors.accentBlue.withValues(alpha: 0.6),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  deleteIconColor: Colors.white70,
                  onDeleted: () {
                    final newIds = List<String>.from(empresaIds);
                    final newNombres = List<String>.from(empresaNombres);
                    newIds.removeAt(i);
                    newNombres.removeAt(i);
                    onCambio(newIds, newNombres);
                  },
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                );
              }),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final res = await _abrirMultiSelect(context, empresaIds);
              if (res == null) return;
              onCambio(res.ids, res.nombres);
            },
            icon: const Icon(Icons.add, size: 16),
            label: Text(
              empresaIds.isEmpty
                  ? 'AGREGAR EMPRESA'
                  : 'EDITAR EMPRESAS',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentBlue,
              side: const BorderSide(color: AppColors.accentBlue),
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

class _MultiEmpresaResultado {
  final List<String> ids;
  final List<String> nombres;
  const _MultiEmpresaResultado(this.ids, this.nombres);
}

Future<_MultiEmpresaResultado?> _abrirMultiSelect(
  BuildContext context,
  List<String> seleccionadosIniciales,
) {
  return showModalBottomSheet<_MultiEmpresaResultado>(
    context: context,
    backgroundColor: AppColors.background,
    isScrollControlled: true,
    builder: (_) =>
        _BottomSheetMultiEmpresa(seleccionadosIniciales: seleccionadosIniciales),
  );
}

class _BottomSheetMultiEmpresa extends StatefulWidget {
  final List<String> seleccionadosIniciales;
  const _BottomSheetMultiEmpresa({
    required this.seleccionadosIniciales,
  });

  @override
  State<_BottomSheetMultiEmpresa> createState() =>
      _BottomSheetMultiEmpresaState();
}

class _BottomSheetMultiEmpresaState extends State<_BottomSheetMultiEmpresa> {
  String _filtro = '';
  late Set<String> _seleccionados;

  @override
  void initState() {
    super.initState();
    _seleccionados = widget.seleccionadosIniciales.toSet();
  }

  void _confirmar(List<EmpresaLogistica> todasLasEmpresas) {
    // Mantener orden estable: usar el orden alfabético de
    // todasLasEmpresas filtrado por seleccionados, así si el operador
    // re-abre el sheet la lista no se reordena raro.
    final ids = <String>[];
    final nombres = <String>[];
    for (final e in todasLasEmpresas) {
      if (_seleccionados.contains(e.id)) {
        ids.add(e.id);
        nombres.add(e.nombre);
      }
    }
    Navigator.pop(context, _MultiEmpresaResultado(ids, nombres));
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Row(
              children: [
                Icon(Icons.business_outlined, color: AppColors.accentBlue),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Empresas que usan esta ubicación',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: TextField(
              autofocus: true,
              onChanged: (v) => setState(() => _filtro = v),
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Buscar empresa...',
                prefixIcon: Icon(Icons.search, color: Colors.white54),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<EmpresaLogistica>>(
              stream: LogisticaService.streamEmpresas(soloActivas: true),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting &&
                    !snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return AppEmptyState(
                    icon: Icons.error_outline,
                    title: 'Error',
                    subtitle: snap.error.toString(),
                  );
                }
                final all = snap.data ?? const <EmpresaLogistica>[];
                final f = _filtro.trim().toUpperCase();
                final items = f.isEmpty
                    ? all
                    : all
                        .where((e) =>
                            e.nombre.toUpperCase().contains(f) ||
                            (e.apodo ?? '').toUpperCase().contains(f))
                        .toList();
                if (items.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.business_outlined,
                    title: 'Sin empresas',
                    subtitle:
                        'Cargá una empresa primero desde el catálogo.',
                  );
                }
                return Column(
                  children: [
                    Expanded(
                      child: ListView.separated(
                        controller: controller,
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                        itemCount: items.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 4),
                        itemBuilder: (_, i) {
                          final e = items[i];
                          final marcada = _seleccionados.contains(e.id);
                          return AppCard(
                            onTap: () {
                              setState(() {
                                if (marcada) {
                                  _seleccionados.remove(e.id);
                                } else {
                                  _seleccionados.add(e.id);
                                }
                              });
                            },
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                Checkbox(
                                  value: marcada,
                                  onChanged: (v) {
                                    setState(() {
                                      if (v == true) {
                                        _seleccionados.add(e.id);
                                      } else {
                                        _seleccionados.remove(e.id);
                                      }
                                    });
                                  },
                                  activeColor: AppColors.accentBlue,
                                ),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        e.etiquetaPrincipal,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (e.etiquetaSecundaria != null)
                                        Text(
                                          e.etiquetaSecundaria!,
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                Text(
                                  e.tipo.etiqueta,
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 10,
                                  ),
                                ),
                                const SizedBox(width: 8),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      color: Colors.black26,
                      child: Row(
                        children: [
                          Expanded(
                            child: TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('CANCELAR'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: () => _confirmar(all),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppColors.accentBlue,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 12),
                              ),
                              child: Text(
                                _seleccionados.isEmpty
                                    ? 'GUARDAR (SIN EMPRESAS)'
                                    : 'GUARDAR ${_seleccionados.length}',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

