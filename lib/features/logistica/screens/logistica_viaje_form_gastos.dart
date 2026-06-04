// =============================================================================
// _SeccionGastos — gastos extraordinarios del tramo (peajes, lavado, etc.)
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — SOLO PRESENTACIÓN. Se preserva VERBATIM:
//   - `_agregar` (dialog + dispose de controllers + parser + cap 1.000.000).
//   - El confirm de eliminar (AppConfirmDialog) y el `removeAt(i)`.
//   - El callback `onChanged([...gastos, nuevo])`.
// Solo cambia el chrome a tokens (`context.colors`), mono para plata, y el
// dialog adopta la superficie surface2 + inputs Núcleo.
//
// Desde 2026-05-13 los gastos viven POR TRAMO, no por viaje (un viaje
// multi-tramo tiene peajes/lavados distintos por tramo). Cada `_TramoCard`
// incluye su `_SeccionGastos` inline (modo `enmarcadoComoSubseccion`).

part of 'logistica_viaje_form_screen.dart';

class _SeccionGastos extends StatelessWidget {
  final List<GastoViaje> gastos;
  final ValueChanged<List<GastoViaje>> onChanged;

  /// Si verdadero, el widget se renderea como sub-bloque inline (sin
  /// el chrome de `_SeccionCard` con título + ícono propios). Usado
  /// cuando la sección va ADENTRO de la card de un tramo — no
  /// queremos un card-dentro-de-card. Default `false` (compat con
  /// otros sitios que pudieran usar `_SeccionGastos` aislado).
  final bool enmarcadoComoSubseccion;

  const _SeccionGastos({
    required this.gastos,
    required this.onChanged,
    this.enmarcadoComoSubseccion = false,
  });

  Future<void> _agregar(BuildContext context) async {
    final montoCtrl = TextEditingController();
    final detalleCtrl = TextEditingController();
    DateTime fecha = DateTime.now();
    bool ok = false;
    try {
      ok = (await showDialog<bool>(
            context: context,
            builder: (dCtx) => _buildAgregarGastoDialog(
              dCtx, montoCtrl, detalleCtrl, fecha, (d) => fecha = d,
            ),
          )) ??
          false;
    } finally {
      // Dispose controllers SIEMPRE — auditoria 2026-05-17, antes leaks
      // de 2 controllers por dialog cancelado.
      montoCtrl.dispose();
      detalleCtrl.dispose();
    }
    if (ok) {
      final monto = AppFormatters.parsearMonto(montoCtrl.text) ?? 0;
      // NOTA: montoCtrl ya fue disposed arriba pero su .text es String
      // (no requiere el ctrl vivo). Lo mismo detalleCtrl.text abajo.
      if (monto <= 0) return;
      const capGasto = 1000000;
      if (monto > capGasto) {
        if (!context.mounted) return;
        AppFeedback.errorOn(
          ScaffoldMessenger.of(context),
          'Gasto excesivo (max ${AppFormatters.formatearMonto(capGasto)}).',
        );
        return;
      }
      final nuevo = GastoViaje(
        monto: monto,
        detalle: detalleCtrl.text.trim().isEmpty
            ? null
            : detalleCtrl.text.trim(),
        fecha: fecha,
      );
      onChanged([...gastos, nuevo]);
    }
  }

  Widget _buildAgregarGastoDialog(
    BuildContext dCtx,
    TextEditingController montoCtrl,
    TextEditingController detalleCtrl,
    DateTime fecha,
    void Function(DateTime) onFechaChange,
  ) {
    final c = dCtx.colors;
    return StatefulBuilder(builder: (sCtx, setStateDialog) {
      return AlertDialog(
        backgroundColor: c.surface2,
        title: Text('Agregar gasto', style: AppType.h5.copyWith(color: c.text)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              style: AppType.mono.copyWith(color: c.text, fontWeight: FontWeight.w600),
              decoration: _inputDecoration(
                dCtx,
                labelText: 'Monto',
                prefixText: '\$ ',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AppFormatters.inputMilesDecimal],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: detalleCtrl,
              style: AppType.body.copyWith(color: c.text),
              decoration: _inputDecoration(
                dCtx,
                labelText: 'Detalle (peaje, combustible, etc.)',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            _BotonFecha(
              label: 'Fecha del gasto',
              fecha: fecha,
              onChanged: (d) {
                if (d != null) {
                  setStateDialog(() {
                    // `fecha` es el parámetro sobre el que cierra el
                    // StatefulBuilder → reasignarlo refresca el botón.
                    // `onFechaChange` propaga a `_agregar` para el guardado.
                    // (Antes solo se llamaba onFechaChange y el botón nunca
                    // reflejaba la fecha elegida — bug audit 2026-06-04.)
                    fecha = d;
                    onFechaChange(d);
                  });
                }
              },
            ),
          ],
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.of(dCtx).pop(false),
          ),
          AppButton.primary(
            label: 'Agregar',
            onPressed: () => Navigator.of(dCtx).pop(true),
          ),
        ],
      );
    });
  }

  // (Implementacion legacy de _agregar con leak de controllers
  // eliminada 2026-05-17 — ver `_agregar` arriba con dispose correcto.)

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = gastos.fold<double>(0, (a, g) => a + g.monto);
    final children = <Widget>[
      if (gastos.isEmpty)
        Text(
          'Sin gastos cargados.',
          style: AppType.bodySm.copyWith(color: c.textMuted),
        )
      else
        ...gastos.asMap().entries.map((entry) {
          final i = entry.key;
          final g = entry.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.add_circle_outline, size: 15, color: c.brandSoft),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '${g.detalle ?? 'Gasto'} '
                    '(${AppFormatters.formatearFecha(g.fecha)})',
                    style: AppType.bodySm.copyWith(color: c.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '\$ ${AppFormatters.formatearMonto(g.monto)}',
                  style: AppType.mono.copyWith(
                    color: c.brandSoft,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline, size: 18, color: c.textMuted),
                  tooltip: 'Eliminar gasto',
                  onPressed: () async {
                    // Confirm (auditoria 2026-05-17): antes el delete era
                    // instantáneo y el operador perdia el gasto sin chance
                    // de deshacer. Importante porque los gastos cargan
                    // monto + fecha + detalle, no es trivial re-cargar.
                    final ok = await AppConfirmDialog.show(
                      context,
                      title: '¿Eliminar gasto?',
                      message:
                          '${g.detalle ?? 'Gasto'} de '
                          '\$${AppFormatters.formatearMonto(g.monto)} '
                          '(${AppFormatters.formatearFecha(g.fecha)}).',
                      confirmLabel: 'ELIMINAR',
                      destructive: true,
                      icon: Icons.delete_outline,
                    );
                    if (ok != true) return;
                    final nueva = List<GastoViaje>.from(gastos)..removeAt(i);
                    onChanged(nueva);
                  },
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          );
        }),
      if (gastos.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.sm),
        const AppHairline(),
        const SizedBox(height: AppSpacing.sm),
        _Linea(
          label: 'Total gastos del tramo',
          valor: '\$ ${AppFormatters.formatearMonto(total)}',
          highlight: true,
          mono: true,
        ),
      ],
      const SizedBox(height: AppSpacing.sm),
      AppButton.secondary(
        label: 'Agregar gasto',
        icon: Icons.add,
        size: AppButtonSize.sm,
        expand: true,
        onPressed: () => _agregar(context),
      ),
    ];
    if (enmarcadoComoSubseccion) {
      // Inline dentro de la card del tramo: solo título chico +
      // contenido. Sin card propia para no anidar.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubseccionTitulo('GASTOS EXTRAORDINARIOS'),
          const SizedBox(height: AppSpacing.sm),
          ...children,
        ],
      );
    }
    // Compat — si en algún lugar se usa standalone, queda como antes.
    return _SeccionCard(
      titulo: 'GASTOS EXTRAORDINARIOS',
      icono: Icons.receipt_long_outlined,
      children: children,
    );
  }
}
