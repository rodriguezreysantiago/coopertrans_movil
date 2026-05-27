import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../utils/fecha_input_formatter.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Diálogo de selección de fecha por **input directo** (`DD/MM/YYYY`),
/// pensado como reemplazo del `showDatePicker` nativo de Material.
///
/// Diferencias con `showDatePicker`:
/// - No hay calendario para scrollear mes a mes — se tipea directo.
/// - Validación on-the-fly (rechaza fechas imposibles).
/// - Footer compacto con título + campo + botones.
///
/// Devuelve un `DateTime?` (null si el usuario canceló).
///
/// Uso:
/// ```dart
/// final fecha = await pickFecha(
///   context,
///   initial: DateTime.tryParse(fechaActualString),
///   titulo: 'Vencimiento RTO',
/// );
/// if (fecha != null) {
///   // ...
/// }
/// ```
Future<DateTime?> pickFecha(
  BuildContext context, {
  DateTime? initial,
  String titulo = 'Seleccionar fecha',
  DateTime? minimo,
  DateTime? maximo,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => _FechaDialog(
      initial: initial,
      titulo: titulo,
      minimo: minimo ?? DateTime(2020),
      maximo: maximo ?? DateTime(2050),
    ),
  );
}

class _FechaDialog extends StatefulWidget {
  final DateTime? initial;
  final String titulo;
  final DateTime minimo;
  final DateTime maximo;

  const _FechaDialog({
    required this.initial,
    required this.titulo,
    required this.minimo,
    required this.maximo,
  });

  @override
  State<_FechaDialog> createState() => _FechaDialogState();
}

class _FechaDialogState extends State<_FechaDialog> {
  late final TextEditingController _ctrl;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(
      text: widget.initial != null ? _formatear(widget.initial!) : '',
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _formatear(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  /// Parsea el texto del input y devuelve un DateTime. Si la fecha es
  /// inválida (formato incompleto, mes 13, día 32 de febrero, fuera del
  /// rango permitido), setea `_error` y devuelve null.
  DateTime? _parsear() {
    final text = _ctrl.text.trim();
    if (text.length != 10) {
      setState(() => _error = 'Formato esperado: DD/MM/AAAA');
      return null;
    }
    final partes = text.split('/');
    if (partes.length != 3) {
      setState(() => _error = 'Formato inválido');
      return null;
    }
    final dia = int.tryParse(partes[0]);
    final mes = int.tryParse(partes[1]);
    final anio = int.tryParse(partes[2]);
    if (dia == null || mes == null || anio == null) {
      setState(() => _error = 'Solo números');
      return null;
    }
    if (mes < 1 || mes > 12) {
      setState(() => _error = 'Mes inválido');
      return null;
    }
    if (dia < 1 || dia > 31) {
      setState(() => _error = 'Día inválido');
      return null;
    }
    // DateTime hace rollover (32/feb pasaría a marzo); validamos
    // construyendo y comparando los componentes.
    final fecha = DateTime(anio, mes, dia);
    if (fecha.day != dia || fecha.month != mes || fecha.year != anio) {
      setState(() => _error = 'Esa fecha no existe');
      return null;
    }
    if (fecha.isBefore(widget.minimo)) {
      setState(() => _error = 'Fecha demasiado vieja');
      return null;
    }
    if (fecha.isAfter(widget.maximo)) {
      setState(() => _error = 'Fecha muy lejana');
      return null;
    }
    return fecha;
  }

  void _confirmar() {
    final fecha = _parsear();
    if (fecha == null) return;
    Navigator.pop(context, fecha);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: Colors.white.withAlpha(20)),
      ),
      title: Text(
        widget.titulo,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Ingresá la fecha en formato DD/MM/AAAA',
            style: TextStyle(color: Colors.white60, fontSize: 12),
          ),
          const SizedBox(height: AppSpacing.lg),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.success,
              fontWeight: FontWeight.bold,
              fontSize: 26,
              letterSpacing: 3,
            ),
            // FechaInputFormatter ya filtra todo lo que no sea dígito
            // y reformatea — no hace falta encadenar otro filtro de
            // dígitos antes (eso solo agrega rebotes en el cursor).
            inputFormatters: [FechaInputFormatter()],
            decoration: InputDecoration(
              hintText: 'DD/MM/AAAA',
              hintStyle: const TextStyle(
                color: Colors.white24,
                letterSpacing: 3,
                fontWeight: FontWeight.normal,
              ),
              filled: true,
              fillColor: Colors.black.withAlpha(80),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              errorText: _error,
              counterText: '',
            ),
            maxLength: 10,
            onChanged: (_) {
              if (_error != null) {
                setState(() => _error = null);
              }
            },
            onSubmitted: (_) => _confirmar(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'CANCELAR',
            style: TextStyle(color: Colors.white54),
          ),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            foregroundColor: Colors.white,
          ),
          onPressed: _confirmar,
          child: const Text(
            'CONFIRMAR',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
