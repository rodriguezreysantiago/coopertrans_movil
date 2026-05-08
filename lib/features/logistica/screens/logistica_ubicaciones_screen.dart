import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_service.dart';

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
          Icon(Icons.place, color: color, size: 28),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ubicacion.nombre,
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
                const SizedBox(height: 2),
                Text(
                  ubicacion.etiquetaCompleta,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
                  ),
                ),
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

class _EditarUbicacionSheet extends StatelessWidget {
  final UbicacionLogistica ubicacion;
  const _EditarUbicacionSheet({required this.ubicacion});

  @override
  Widget build(BuildContext context) {
    Future<void> setCampo(String campo, dynamic valor) async {
      await LogisticaService.actualizarUbicacion(
        id: ubicacion.id,
        cambios: {campo: valor},
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
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
                    ubicacion.nombre,
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
                  valor: ubicacion.nombre,
                  onSave: (v) => setCampo('nombre', v),
                ),
                DatoEditableTexto(
                  etiqueta: 'Localidad',
                  valor: ubicacion.localidad,
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo('localidad', v.trim()),
                ),
                DatoEditableTexto(
                  etiqueta: 'Provincia',
                  valor: ubicacion.provincia,
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo('provincia', v.trim()),
                ),
                DatoEditableTexto(
                  etiqueta: 'Dirección (opcional)',
                  valor: ubicacion.direccion ?? '',
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'direccion',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                // lat/lng quedan para edición avanzada — no las exponemos
                // al operador común porque se ingresan típicamente por
                // pegar una coordenada de Google Maps. Cuando armemos el
                // mapa de planeamiento agregamos el picker.
              ],
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
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _localidadCtrl.dispose();
    _provinciaCtrl.dispose();
    _direccionCtrl.dispose();
    super.dispose();
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
