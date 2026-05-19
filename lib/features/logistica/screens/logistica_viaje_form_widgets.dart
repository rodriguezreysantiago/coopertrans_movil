// =============================================================================
// WIDGETS COMUNES del form (card, fecha, resumen tarifa, botones guardar)
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// Componentes (reusados por todas las secciones):
//   - _SeccionCard       — contenedor visual con título + ícono + children.
//   - _SubseccionTitulo  — título chico (caps, espaciado) para sub-bloques.
//   - _BotonFecha        — InkWell con DatePicker para campos de fecha.
//   - _ResumenTarifa     — chip con info de la tarifa elegida (tarifa + dador).
//   - _BotonesGuardar    — par de botones CANCELAR / GUARDAR al pie del form.

part of 'logistica_viaje_form_screen.dart';

class _SeccionCard extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final List<Widget> children;
  final Widget? trailing;

  const _SeccionCard({
    required this.titulo,
    required this.icono,
    required this.children,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withAlpha(20)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icono, color: AppColors.accentBlue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _SubseccionTitulo extends StatelessWidget {
  final String texto;
  const _SubseccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      style: const TextStyle(
        color: Colors.white60,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 1.2,
      ),
    );
  }
}

class _BotonFecha extends StatelessWidget {
  final String label;
  final DateTime? fecha;
  final ValueChanged<DateTime?> onChanged;

  const _BotonFecha({
    required this.label,
    required this.fecha,
    required this.onChanged,
  });

  Future<void> _pick(BuildContext context) async {
    final hoy = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: fecha ?? hoy,
      firstDate: DateTime(hoy.year - 2),
      lastDate: DateTime(hoy.year + 2),
    );
    if (d != null) onChanged(d);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
        ),
        child: Text(
          fecha == null ? 'Sin asignar' : AppFormatters.formatearFecha(fecha!),
          style: const TextStyle(color: Colors.white),
        ),
      ),
    );
  }
}

class _ResumenTarifa extends StatelessWidget {
  final TarifaLogistica t;
  const _ResumenTarifa({required this.t});

  @override
  Widget build(BuildContext context) {
    // Si la tarifa todavía no tiene monto cargado (caso típico:
    // operador armó la tarifa con $0 porque no se sabía y la va a
    // editar después), avisamos en ámbar — el viaje se puede crear
    // igual, los cálculos van a dar 0 y se actualizan cuando se
    // edite la tarifa + se vuelva a guardar el viaje.
    final sinMonto = t.tarifaReal == 0 || t.tarifaChofer == 0;
    final color = sinMonto ? AppColors.accentAmber : AppColors.accentGreen;
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            'Vecchi: \$${AppFormatters.formatearMonto(t.tarifaReal)}'
            '${t.unidadTarifa.sufijoMonto}  ·  '
            'Chofer: \$${AppFormatters.formatearMonto(t.tarifaChofer)}'
            '${t.unidadTarifa.sufijoMonto}',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (sinMonto) ...[
            const SizedBox(height: 4),
            const Row(
              children: [
                Icon(Icons.warning_amber_outlined,
                    size: 14, color: AppColors.accentAmber),
                SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Tarifa pendiente de definir — actualizá la tarifa '
                    'y volvé a guardar el viaje cuando sepas el monto.',
                    style: TextStyle(
                      color: AppColors.accentAmber,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _BotonesGuardar extends StatelessWidget {
  final bool guardando;
  final VoidCallback onGuardar;
  final VoidCallback onCancelar;

  const _BotonesGuardar({
    required this.guardando,
    required this.onGuardar,
    required this.onCancelar,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: guardando ? null : onCancelar,
            child: const Text('CANCELAR'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: guardando ? null : onGuardar,
            child: guardando
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child:
                        CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Text('GUARDAR'),
          ),
        ),
      ],
    );
  }
}
