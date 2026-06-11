// =============================================================================
// TARIFA PICKER — modal sheet con buscador para elegir tarifa
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — SOLO PRESENTACIÓN. Se preserva VERBATIM:
//   - `_abrirSelectorTarifa` (showModalBottomSheet<TarifaLogistica>).
//   - `_aplicarFiltro` (filtro token-based contra TODOS los campos).
//   - El StreamBuilder `LogisticaService.streamTarifas(soloActivas: true)`.
//   - `onTap: () => Navigator.pop(t)` (selección de la tarifa).
//   - `_ItemTarifaPicker` (lógica dador/ruta).
// Solo cambia el chrome del sheet (surface, handle, buscador, items) a tokens.
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
    backgroundColor: context.colors.surface1,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
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
    final c = context.colors;
    // El sheet ocupa hasta ~85% de la pantalla. El `viewInsets` del
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
              margin: const EdgeInsets.only(
                  top: AppSpacing.sm, bottom: AppSpacing.xs),
              decoration: BoxDecoration(
                color: c.border,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppEyebrow('Elegir tarifa'),
              ),
            ),
            // Buscador.
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                style: AppType.body.copyWith(color: c.text),
                decoration: _inputDecoration(
                  context,
                  hintText: 'Buscar por empresa, ubicación, dador, producto…',
                  prefixIcon: Icon(Icons.search, size: 18, color: c.textMuted),
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: Icon(Icons.close, size: 18, color: c.textMuted),
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
                stream: LogisticaService.streamTarifas(activa: true),
                builder: (ctx, snap) {
                  if (snap.hasError) {
                    return AppErrorState(
                      title: 'No se pudieron cargar las tarifas',
                      subtitle: snap.error.toString(),
                    );
                  }
                  if (!snap.hasData) {
                    return const AppSkeletonList(count: 6, conAvatar: false);
                  }
                  final filtradas = _aplicarFiltro(snap.data!);
                  if (filtradas.isEmpty) {
                    return AppEmptyState(
                      icon: Icons.local_offer_outlined,
                      title: _filtro.isEmpty
                          ? 'Sin tarifas activas'
                          : 'Sin coincidencias',
                      subtitle: _filtro.isEmpty
                          ? 'Cargá una tarifa desde el catálogo Tarifas.'
                          : 'Probá con otro texto.',
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xl),
                    itemCount: filtradas.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.xs),
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

/// Item del listado de tarifas en el picker. Muestra **dador** (empresa
/// que paga la tarifa) como línea principal y **alias origen → destino**
/// como subtítulo. Sin precios, sin unidad, sin producto — esos datos
/// los ve el operador en el resumen del tramo después de elegir.
///
/// Si la tarifa no tiene dador (campo nullable), la ruta pasa a ser la
/// línea principal sin subtítulo, así el item nunca queda "huérfano".
///
/// El filtro del picker sigue buscando contra TODOS los campos (incluso
/// los que no se muestran), así seguís pudiendo encontrar tarifas por
/// producto, unidad, empresa origen, etc.
///
/// Decisión 2026-05-28: antes el item tenía 3 líneas (ruta + precios +
/// dador/producto) y se saturaba visualmente al recorrer una lista
/// de 30+ tarifas. Se simplificó por pedido del operador.
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
    final c = context.colors;
    final dador = tarifa.dadorNombre?.trim();
    final tieneDador = dador != null && dador.isNotEmpty;
    final ruta = '${tarifa.origenDisplay} → ${tarifa.destinoDisplay}';
    return AppCard(
      tier: 1,
      onTap: onTap,
      accent: esActual ? c.brand : null,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.local_offer_outlined, size: 18, color: c.brandSoft),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tieneDador ? dador : ruta,
                  style: AppType.body.copyWith(
                    color: c.text,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (tieneDador) ...[
                  const SizedBox(height: 2),
                  Text(
                    ruta,
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          if (esActual)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: Icon(Icons.check_circle, color: c.success, size: 20),
            ),
        ],
      ),
    );
  }
}
