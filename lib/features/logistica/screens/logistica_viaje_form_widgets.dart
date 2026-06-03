// =============================================================================
// WIDGETS COMUNES del form (card, fecha, resumen tarifa, botones guardar)
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — SOLO PRESENTACIÓN. Acá viven las primitivas
// visuales reusadas por todas las secciones del form. La lógica (callbacks,
// DatePicker, parsers de plata) queda intacta; solo cambia el chrome a
// tokens (`context.colors`), bento (AppCard tier 2 + AppEyebrow), hairlines
// y mono para números.
//
// Componentes (reusados por todas las secciones):
//   - _SeccionCard       — contenedor bento (AppCard tier 2) con eyebrow + dot.
//   - _SubseccionTitulo  — eyebrow chico para sub-bloques dentro de una card.
//   - _BotonFecha        — card tappeable con DatePicker para campos de fecha.
//   - _ResumenTarifa     — chip con info de la tarifa elegida (tarifa + dador).
//   - _BotonesGuardar    — par CANCELAR / GUARDAR (AppButton) al pie del form.
//   - _Linea             — primitiva label (izq) / valor (der), mono opcional.
//   - _PillSelector      — pill seleccionable (reemplaza ChoiceChip).
//   - _inputDecoration   — InputDecoration Núcleo para los TextField del form.

part of 'logistica_viaje_form_screen.dart';

/// Tarjeta de sección Núcleo: AppCard tier 2 con eyebrow (+ dot opcional)
/// y contenido. Reemplaza al contenedor `Container` con bordes en blanco
/// translúcido del sistema anterior.
class _SeccionCard extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final List<Widget> children;
  final Widget? trailing;

  /// Punto de color semántico opcional a la izquierda del eyebrow (ej.
  /// ámbar para "adelanto", verde para "resumen"). Si es null, el eyebrow
  /// va en su tinta muted por defecto.
  final Color? accentDot;

  const _SeccionCard({
    required this.titulo,
    required this.icono,
    required this.children,
    this.trailing,
    this.accentDot,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ] else ...[
                Icon(icono, color: c.textMuted, size: 16),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: AppEyebrow(titulo, color: accentDot),
              ),
              if (trailing != null) trailing!,
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

/// Eyebrow chico para sub-bloques DENTRO de una card (CARGA / DESCARGA /
/// GASTOS / PAGO AL CHOFER). Es el gesto Núcleo para separar secciones sin
/// anidar cards.
class _SubseccionTitulo extends StatelessWidget {
  final String texto;
  const _SubseccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return AppEyebrow(texto);
  }
}

/// Campo de fecha: card tappeable que abre el DatePicker. Conserva
/// VERBATIM la lógica de `_pick` (rango ±2 años, `onChanged`). Solo cambia
/// el chrome a tokens.
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
    final c = context.colors;
    final tieneFecha = fecha != null;
    return InkWell(
      onTap: () => _pick(context),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(Icons.event_outlined, size: 18, color: c.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppEyebrow(label),
                  const SizedBox(height: 2),
                  Text(
                    tieneFecha
                        ? AppFormatters.formatearFecha(fecha!)
                        : 'Sin asignar',
                    style: (tieneFecha ? AppType.mono : AppType.body).copyWith(
                      color: tieneFecha ? c.text : c.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

/// Resumen de la tarifa elegida (debajo del campo Tarifa del tramo). Si la
/// tarifa todavía no tiene monto cargado, avisa en ámbar — el viaje se
/// puede crear igual (los cálculos dan 0 hasta que se edite la tarifa).
class _ResumenTarifa extends StatelessWidget {
  final TarifaLogistica t;
  const _ResumenTarifa({required this.t});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sinMonto = t.tarifaReal == 0 || t.tarifaChofer == 0;
    final acento = sinMonto ? c.warning : c.success;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${t.empresaOrigenNombre} → ${t.empresaDestinoNombre}',
            style: AppType.bodySm.copyWith(color: c.textSecondary),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Vecchi: \$${AppFormatters.formatearMonto(t.tarifaReal)}'
            '${t.unidadTarifa.sufijoMonto}  ·  '
            'Chofer: \$${AppFormatters.formatearMonto(t.tarifaChofer)}'
            '${t.unidadTarifa.sufijoMonto}',
            style: AppType.mono.copyWith(
              color: acento,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (sinMonto) ...[
            const SizedBox(height: AppSpacing.xs),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_outlined, size: 14, color: c.warning),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Tarifa pendiente de definir — actualizá la tarifa '
                    'y volvé a guardar el viaje cuando sepas el monto.',
                    style: AppType.bodySm.copyWith(color: c.warning),
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

/// Par de botones al pie del form: CANCELAR (secundario) + GUARDAR
/// (primario). El estado `guardando` deshabilita ambos y muestra el spinner
/// en el primario (vía `isLoading` de AppButton).
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
          child: AppButton.secondary(
            label: 'Cancelar',
            expand: true,
            onPressed: guardando ? null : onCancelar,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          flex: 2,
          child: AppButton.primary(
            label: 'Guardar',
            icon: Icons.save_outlined,
            expand: true,
            isLoading: guardando,
            onPressed: guardando ? null : onGuardar,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// PRIMITIVA DE LÍNEA · label (izq) / valor (der) — Núcleo
// =============================================================================
//
// Misma primitiva que el viaje_detalle ya migrado: label en tinta secundaria,
// valor a la derecha (mono opcional para plata/números). `highlight` lo pinta
// en verde (totales), `sub` lo atenúa (sub-líneas de cálculo).

class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final bool highlight;
  final bool sub;
  final bool mono;

  const _Linea({
    required this.label,
    required this.valor,
    this.highlight = false,
    this.sub = false,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final labelStyle = AppType.bodySm.copyWith(
      color: sub ? c.textMuted : c.textSecondary,
    );
    final valBase = mono ? AppType.mono : AppType.body;
    final valStyle = valBase.copyWith(
      color: highlight ? c.success : (sub ? c.textMuted : c.text),
      fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 5,
            child: Text(label, style: labelStyle),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 5,
            child: Text(
              valor,
              style: valStyle,
              textAlign: TextAlign.right,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PILL SELECTOR — reemplaza ChoiceChip; activo = tinte brand + borde
// =============================================================================
//
// Mismo gesto que el tarifa_form ya migrado. La carga semántica (ámbar para
// "monto fijo") se pasa por `acento`; default brand.

class _PillSelector extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;
  final Color? acento;

  const _PillSelector({
    required this.label,
    required this.seleccionado,
    required this.onTap,
    this.acento,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final col = acento ?? c.brand;
    final fg = seleccionado ? col : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: seleccionado ? col.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: seleccionado ? col.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.label.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// INPUT DECORATION NÚCLEO — superficie surface3, border hairline, focus brand
// =============================================================================
//
// InputDecoration común para los TextField reskineados del form (mismo gesto
// que el tarifa_form ya migrado). NO migramos los TextField a AppInput porque
// muchos llevan inputFormatters/maxLength/validators propios que hay que
// preservar VERBATIM; solo cambiamos su decoración a tokens.

InputDecoration _inputDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
  String? helperText,
  String? prefixText,
  String? suffixText,
  TextStyle? prefixStyle,
  Widget? prefixIcon,
  Widget? suffixIcon,
}) {
  final c = context.colors;
  OutlineInputBorder border(Color col) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide(color: col),
      );
  return InputDecoration(
    labelText: labelText,
    labelStyle: AppType.bodySm.copyWith(color: c.textMuted),
    floatingLabelStyle: AppType.bodySm.copyWith(color: c.brand),
    hintText: hintText,
    hintStyle: AppType.body.copyWith(color: c.textPlaceholder),
    helperText: helperText,
    helperStyle: AppType.monoSm.copyWith(color: c.textMuted),
    helperMaxLines: 3,
    prefixText: prefixText,
    prefixStyle: prefixStyle ?? AppType.mono.copyWith(color: c.textSecondary),
    suffixText: suffixText,
    suffixStyle: AppType.monoSm.copyWith(color: c.textMuted),
    prefixIcon: prefixIcon,
    suffixIcon: suffixIcon,
    isDense: true,
    filled: true,
    fillColor: c.surface3,
    contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md, vertical: AppSpacing.md),
    border: border(c.border),
    enabledBorder: border(c.border),
    focusedBorder: border(c.borderFocus),
    disabledBorder: border(c.border),
  );
}
