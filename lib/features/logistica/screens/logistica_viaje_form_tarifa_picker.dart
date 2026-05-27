// =============================================================================
// TARIFA PICKER — modal sheet con buscador para elegir tarifa
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// Reemplazó al `DropdownButtonFormField` simple a partir del 2026-05-13.
// Con > 30 tarifas el dropdown se volvía impráctico (scroll infinito sin
// filtro). El sheet tiene buscador token-based contra empresa origen /
// destino, ubicación origen / destino, dador, producto.
//
// Componentes:
//   - _abrirSelectorTarifa  — helper para abrir el sheet desde un tap.
//   - _TarifaPickerSheet    — el sheet con buscador + lista filtrada.
//   - _ItemTarifaPicker     — un item del listado.

part of 'logistica_viaje_form_screen.dart';

/// Abre un modal sheet con buscador para elegir tarifa. Lo usa
/// `_TramoCard` cuando el operador toca el campo "Tarifa" del tramo.
/// El selector reemplazó al `DropdownButtonFormField` simple a partir
/// del 2026-05-13 — con > 30 tarifas el dropdown se volvía
/// impráctico (scroll infinito sin filtro).
///
/// Devuelve la tarifa elegida o `null` si el operador cerró el sheet
/// sin elegir.
Future<TarifaLogistica?> _abrirSelectorTarifa(
  BuildContext context, {
  required TarifaLogistica? tarifaActual,
}) {
  return showModalBottomSheet<TarifaLogistica>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.background,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _TarifaPickerSheet(tarifaActualId: tarifaActual?.id),
  );
}

/// Sheet con TextField de búsqueda + lista filtrada de tarifas
/// activas. El filtro es token-based (case-insensitive) contra
/// empresa origen / destino, ubicación origen / destino, dador.
/// Mismo patrón que la pantalla `LogisticaTarifasScreen`.
class _TarifaPickerSheet extends StatefulWidget {
  /// Si está seteado, el item correspondiente se marca con un check
  /// para que el operador sepa cuál ya tiene elegido.
  final String? tarifaActualId;
  const _TarifaPickerSheet({required this.tarifaActualId});

  @override
  State<_TarifaPickerSheet> createState() => _TarifaPickerSheetState();
}

class _TarifaPickerSheetState extends State<_TarifaPickerSheet> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<TarifaLogistica> _aplicarFiltro(List<TarifaLogistica> tarifas) {
    if (_filtro.trim().isEmpty) return tarifas;
    final f = _filtro.trim().toUpperCase();
    return tarifas.where((t) {
      return t.empresaOrigenNombre.toUpperCase().contains(f) ||
          t.empresaDestinoNombre.toUpperCase().contains(f) ||
          t.ubicacionOrigenEtiqueta.toUpperCase().contains(f) ||
          t.ubicacionDestinoEtiqueta.toUpperCase().contains(f) ||
          (t.dadorNombre?.toUpperCase().contains(f) ?? false) ||
          (t.producto?.toUpperCase().contains(f) ?? false);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // El sheet ocupa hasta ~80% de la pantalla. El `viewInsets` del
    // bottom evita que el teclado tape el campo de búsqueda en
    // mobile.
    final media = MediaQuery.of(context);
    final altoMax = media.size.height * 0.85;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: altoMax),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle visual del sheet.
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'ELEGIR TARIFA',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 1.4,
                  ),
                ),
              ),
            ),
            // Buscador.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Buscar por empresa, ubicación, dador, producto…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Limpiar búsqueda',
                          onPressed: () {
                            _ctrl.clear();
                            setState(() => _filtro = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
            // Lista de tarifas filtrada.
            Expanded(
              child: StreamBuilder<List<TarifaLogistica>>(
                stream: LogisticaService.streamTarifas(soloActivas: true),
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          'Error: ${snap.error}',
                          style: const TextStyle(color: AppColors.error),
                        ),
                      ),
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final filtradas = _aplicarFiltro(snap.data!);
                  if (filtradas.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _filtro.isEmpty
                              ? 'No hay tarifas activas cargadas.'
                              : 'Sin coincidencias con "$_filtro".',
                          style: const TextStyle(
                              color: Colors.white60, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, color: Colors.white12),
                    itemBuilder: (_, i) {
                      final t = filtradas[i];
                      final esActual = t.id == widget.tarifaActualId;
                      return _ItemTarifaPicker(
                        tarifa: t,
                        esActual: esActual,
                        onTap: () => Navigator.of(context).pop(t),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Item del listado de tarifas en el picker. Muestra la ruta + dador
/// + tarifas (real / chofer) + producto, con look compacto pero
/// legible. Si es la tarifa ya elegida actualmente, se marca con
/// un check verde.
class _ItemTarifaPicker extends StatelessWidget {
  final TarifaLogistica tarifa;
  final bool esActual;
  final VoidCallback onTap;

  const _ItemTarifaPicker({
    required this.tarifa,
    required this.esActual,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final origen = tarifa.origenDisplay;
    final destino = tarifa.destinoDisplay;
    final unidad = tarifa.unidadTarifa.etiqueta;
    final sufijo = tarifa.unidadTarifa.sufijoMonto;
    final montoReal = AppFormatters.formatearMonto(tarifa.tarifaReal);
    final montoChofer = AppFormatters.formatearMonto(tarifa.tarifaChofer);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '$origen → $destino',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$unidad · Vecchi \$ $montoReal$sufijo · Chofer \$ $montoChofer$sufijo',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (tarifa.dadorNombre?.isNotEmpty == true ||
                      tarifa.producto?.isNotEmpty == true) ...[
                    const SizedBox(height: 2),
                    Text(
                      [
                        if (tarifa.dadorNombre?.isNotEmpty == true)
                          'Dador: ${tarifa.dadorNombre}',
                        if (tarifa.producto?.isNotEmpty == true)
                          'Producto: ${tarifa.producto}',
                      ].join(' · '),
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (esActual)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.check_circle,
                    color: AppColors.success, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
