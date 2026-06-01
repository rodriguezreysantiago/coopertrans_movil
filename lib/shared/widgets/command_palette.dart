import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/constants/app_constants.dart';
import '../../core/services/capabilities.dart';
import '../../core/services/prefs_service.dart';
import '../constants/app_colors.dart';

import '../../features/employees/screens/admin_personal_lista_screen.dart'
    show abrirDetalleChofer;
import '../../features/revisions/screens/admin_revisiones_screen.dart'
    show abrirDetalleRevision;
import '../../features/vehicles/screens/admin_vehiculos_lista_screen.dart'
    show abrirDetalleVehiculo;

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Palette de búsqueda global estilo VS Code.
///
/// Pensado como atajo del admin en desktop / Web: Ctrl+K abre este
/// dialog y le permite saltar al detalle de cualquier chofer o vehículo
/// sin tener que cambiar de sección y scrollear la lista.
///
/// La carga de datos es one-shot (`.get()`) en lugar de stream — el
/// palette es efímero, no necesita mantenerse sincronizado en tiempo
/// real. Esto evita listeners que se quedan colgados al cerrar.
///
/// Uso:
/// ```dart
/// CommandPalette.show(context);
/// ```
class CommandPalette {
  CommandPalette._();

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (_) => const _PaletteDialog(),
    );
  }
}

class _PaletteDialog extends StatefulWidget {
  const _PaletteDialog();

  @override
  State<_PaletteDialog> createState() => _PaletteDialogState();
}

class _PaletteDialogState extends State<_PaletteDialog> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  // Cache one-shot de los items. La primera frame muestra "Cargando…",
  // el resto del tiempo el filtro es local (rápido, sin nuevo round-trip).
  List<_PaletteItem>? _items;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _cargar();
    // Damos foco al TextField al frame siguiente; antes el dialog
    // todavía no terminó de animar y el autofocus se pierde.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final db = FirebaseFirestore.instance;
      // Filtramos por capability del rol logueado: solo consultamos las
      // colecciones de las secciones que el rol tiene en el menú. Evita
      // lecturas de más, `permission-denied`, y que por Ctrl+K un rol abra
      // fichas de una sección que no le corresponde (ej. SEG_HIGIENE no ve
      // Flota ni Revisiones → no debe poder abrir esas fichas por el palette).
      final rol = PrefsService.rol;
      final verPersonal =
          Capabilities.can(rol, Capability.verListaPersonal);
      final verFlota = Capabilities.can(rol, Capability.verListaFlota);
      final verRevisiones =
          Capabilities.can(rol, Capability.verRevisiones);

      // Lanzamos en paralelo solo lo permitido (las requests arrancan al
      // asignarse; los await de abajo no agregan latencia).
      final empF =
          verPersonal ? db.collection(AppCollections.empleados).get() : null;
      final vehF =
          verFlota ? db.collection(AppCollections.vehiculos).get() : null;
      final revF =
          verRevisiones ? db.collection(AppCollections.revisiones).get() : null;

      const sinDocs = <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      final empDocs = empF == null ? sinDocs : (await empF).docs;
      final vehDocs = vehF == null ? sinDocs : (await vehF).docs;
      final revDocs = revF == null ? sinDocs : (await revF).docs;

      final items = <_PaletteItem>[];
      for (final doc in empDocs) {
        final data = doc.data();
        // Soft-delete: empleados dados de baja no aparecen en Ctrl+K.
        if (!AppActivo.esActivo(data)) continue;
        items.add(_PaletteItem(
          tipo: _PaletteTipo.chofer,
          id: doc.id,
          titulo: (data['NOMBRE'] ?? doc.id).toString(),
          subtitulo:
              'DNI ${doc.id} · ${(data['ROL'] ?? 'USUARIO').toString()}',
          icon: Icons.person,
          data: data,
        ));
      }
      for (final doc in vehDocs) {
        final data = doc.data();
        // Soft-delete: vehiculos dados de baja no aparecen en Ctrl+K.
        if (!AppActivo.esActivo(data)) continue;
        final marca = (data['MARCA'] ?? '').toString();
        final modelo = (data['MODELO'] ?? '').toString();
        items.add(_PaletteItem(
          tipo: _PaletteTipo.vehiculo,
          id: doc.id,
          titulo: doc.id, // patente
          subtitulo: '$marca $modelo'.trim().isEmpty
              ? 'Sin datos'
              : '$marca $modelo',
          icon: Icons.local_shipping,
          data: data,
        ));
      }
      for (final doc in revDocs) {
        final data = doc.data();
        final esCambioEquipo = data['tipo_solicitud'] == 'CAMBIO_EQUIPO';
        final solicitante =
            (data['nombre_usuario'] ?? data['dni'] ?? 'N/A').toString();
        final etiqueta = esCambioEquipo
            ? 'Cambio de ${data['campo'] == 'SOLICITUD_ENGANCHE' ? 'enganche' : 'unidad'}'
            : (data['etiqueta'] ?? 'Documento').toString();
        items.add(_PaletteItem(
          tipo: _PaletteTipo.revision,
          id: doc.id,
          titulo: '$etiqueta — $solicitante',
          subtitulo: esCambioEquipo
              ? 'Solicita: ${data['patente'] ?? '—'}'
              : 'Documento del chofer',
          icon: esCambioEquipo ? Icons.swap_horiz : Icons.fact_check,
          data: data,
        ));
      }
      if (!mounted) return;
      setState(() => _items = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  /// Filtra los items con un matching simple case-insensitive.
  /// El usuario tipea "juan" y matchea contra título y subtítulo.
  List<_PaletteItem> _filtrados() {
    final items = _items ?? const <_PaletteItem>[];
    if (_query.isEmpty) return items.take(20).toList();
    final q = _query.toUpperCase();
    return items.where((it) {
      final hay = '${it.titulo} ${it.subtitulo} ${it.id}'.toUpperCase();
      return hay.contains(q);
    }).take(50).toList();
  }

  void _abrir(_PaletteItem item) {
    Navigator.of(context).pop(); // cerrar palette primero
    switch (item.tipo) {
      case _PaletteTipo.chofer:
        abrirDetalleChofer(context, item.id);
        break;
      case _PaletteTipo.vehiculo:
        abrirDetalleVehiculo(context, item.id, item.data);
        break;
      case _PaletteTipo.revision:
        abrirDetalleRevision(context, item.id, item.data);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtrados = _filtrados();

    return Dialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: Colors.white.withAlpha(25)),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 80),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Input
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Buscar chofer, vehículo o trámite…',
                  prefixIcon: const Icon(Icons.search,
                      color: AppColors.success),
                  filled: true,
                  fillColor: Colors.black.withAlpha(80),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _query = v.trim()),
                onSubmitted: (_) {
                  if (filtrados.isNotEmpty) _abrir(filtrados.first);
                },
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            // Resultados
            Expanded(
              child: _items == null && _loadError == null
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: AppColors.success))
                  : _loadError != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Text(
                              'No se pudieron cargar los datos:\n$_loadError',
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: AppColors.error),
                            ),
                          ),
                        )
                      : filtrados.isEmpty
                          ? const Center(
                              child: Text(
                                'Sin resultados',
                                style: TextStyle(color: Colors.white38),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: filtrados.length,
                              itemBuilder: (ctx, i) {
                                final it = filtrados[i];
                                return _ItemTile(item: it, onTap: _abrir);
                              },
                            ),
            ),
            // Footer con hint
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withAlpha(40),
                border: Border(
                  top: BorderSide(color: Colors.white.withAlpha(15)),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.keyboard_return,
                      size: 14, color: Colors.white54),
                  const SizedBox(width: 6),
                  Text('Enter para abrir',
                      style:
                          AppType.eyebrow.copyWith(color: Colors.white54)),
                  const SizedBox(width: AppSpacing.lg),
                  const Icon(Icons.keyboard_alt_outlined,
                      size: 14, color: Colors.white54),
                  const SizedBox(width: 6),
                  Text('Esc para cerrar',
                      style:
                          AppType.eyebrow.copyWith(color: Colors.white54)),
                  const Spacer(),
                  Text(
                    '${filtrados.length} resultado${filtrados.length == 1 ? '' : 's'}',
                    style: AppType.eyebrow.copyWith(color: AppColors.success, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  final _PaletteItem item;
  final void Function(_PaletteItem) onTap;

  const _ItemTile({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(item.icon, color: AppColors.success, size: 20),
      title: Text(
        item.titulo,
        style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        item.subtitulo,
        style: AppType.eyebrow.copyWith(color: Colors.white54),
      ),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white.withAlpha(15),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          item.tipo.label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
      ),
      onTap: () => onTap(item),
    );
  }
}

enum _PaletteTipo {
  chofer('CHOFER'),
  vehiculo('UNIDAD'),
  revision('TRÁMITE');

  final String label;
  const _PaletteTipo(this.label);
}

class _PaletteItem {
  final _PaletteTipo tipo;
  final String id;
  final String titulo;
  final String subtitulo;
  final IconData icon;
  final Map<String, dynamic> data;

  const _PaletteItem({
    required this.tipo,
    required this.id,
    required this.titulo,
    required this.subtitulo,
    required this.icon,
    required this.data,
  });
}

/// Atajo de teclado que abre [CommandPalette] al presionar Ctrl+K
/// (Cmd+K en macOS).
///
/// Se monta envolviendo el body del shell. Solo se activa cuando hay
/// foco dentro del subárbol — el dialog interno bloquea más eventos
/// hasta que se cierra.
class CommandPaletteShortcut extends StatelessWidget {
  final Widget child;
  const CommandPaletteShortcut({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            () => CommandPalette.show(context),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true):
            () => CommandPalette.show(context),
      },
      child: Focus(
        autofocus: true,
        child: child,
      ),
    );
  }
}
