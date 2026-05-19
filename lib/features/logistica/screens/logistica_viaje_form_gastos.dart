// =============================================================================
// _SeccionGastos — gastos extraordinarios del tramo (peajes, lavado, etc.)
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
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
      final monto = AppFormatters.parsearMiles(montoCtrl.text)?.toDouble() ?? 0;
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
    return StatefulBuilder(builder: (sCtx, setStateDialog) {
      return AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('Agregar gasto'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: montoCtrl,
              decoration: const InputDecoration(
                labelText: 'Monto',
                prefixText: '\$ ',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [AppFormatters.inputMiles],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: detalleCtrl,
              decoration: const InputDecoration(
                labelText: 'Detalle (peaje, combustible, etc.)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            _BotonFecha(
              label: 'Fecha del gasto',
              fecha: fecha,
              onChanged: (d) {
                if (d != null) {
                  setStateDialog(() {
                    onFechaChange(d);
                  });
                }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Agregar'),
          ),
        ],
      );
    });
  }

  // (Implementacion legacy de _agregar con leak de controllers
  // eliminada 2026-05-17 — ver `_agregar` arriba con dispose correcto.)

  @override
  Widget build(BuildContext context) {
    final total = gastos.fold<double>(0, (a, g) => a + g.monto);
    final children = <Widget>[
      if (gastos.isEmpty)
        const Text(
          'Sin gastos cargados.',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        )
      else
        ...gastos.asMap().entries.map((entry) {
          final i = entry.key;
          final g = entry.value;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                const Icon(Icons.add_circle_outline,
                    size: 16, color: AppColors.accentGreen),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${g.detalle ?? 'Gasto'} '
                    '(${AppFormatters.formatearFecha(g.fecha)})',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '\$${AppFormatters.formatearMonto(g.monto)}',
                  style: const TextStyle(
                    color: AppColors.accentGreen,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      size: 18, color: Colors.white54),
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
        const Divider(color: Colors.white24, height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Total gastos del tramo',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            Text(
              '\$${AppFormatters.formatearMonto(total)}',
              style: const TextStyle(
                color: AppColors.accentGreen,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => _agregar(context),
        icon: const Icon(Icons.add, size: 18),
        label: const Text('AGREGAR GASTO'),
      ),
    ];
    if (enmarcadoComoSubseccion) {
      // Inline dentro de la card del tramo: solo título chico +
      // contenido. Sin card propia para no anidar.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SubseccionTitulo('GASTOS EXTRAORDINARIOS'),
          const SizedBox(height: 8),
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
