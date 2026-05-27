import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../constants/app_colors.dart';
import '../utils/formatters.dart';

/// Widgets reusables del patrón "click en el ítem para editarlo".
///
/// Origen: la pantalla de Personal del admin (`_DatoEditableTexto` y
/// `_DatoEditableEnum` privados en `admin_personal_lista_widgets.dart`).
/// Acá quedan como widgets PÚBLICOS para reusar en otras pantallas
/// (Flota, Gomería, etc.) que adopten el mismo patrón. La copia en
/// Personal sigue funcionando en paralelo — la consolidación final se
/// hará cuando esté validado el patrón en otras features.
///
/// Diseño común:
/// - `ListTile` con título chico arriba (etiqueta) + valor grande abajo.
/// - Tap abre un dialog modal específico al tipo de dato.
/// - Trailing icon (verde accent) indica editable; gris si solo-lectura.
/// - Callback `onSave(nuevoValor)` el caller se encarga de persistir.

/// Edita un texto libre con un dialog. Soporta formatters (solo dígitos,
/// uppercase, etc.) y conversiones automáticas (mayúsculas, lowercase).
class DatoEditableTexto extends StatelessWidget {
  final String etiqueta;
  final String valor;
  final ValueChanged<String> onSave;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputType? keyboardType;
  /// Si `true` (default), el dialog convierte el input a MAYÚSCULAS al
  /// guardar. Apagar para mail (lowercase) o dígitos puros.
  final bool aplicarMayusculas;
  /// Si `false`, el tile no es tappable y el icon trailing se atenua.
  final bool editable;

  const DatoEditableTexto({
    super.key,
    required this.etiqueta,
    required this.valor,
    required this.onSave,
    this.inputFormatters,
    this.keyboardType,
    this.aplicarMayusculas = true,
    this.editable = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        valor,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: Icon(
        Icons.edit_note,
        size: 22,
        color: editable ? AppColors.success : Colors.white24,
      ),
      onTap: editable ? () => _mostrarDialogo(context) : null,
    );
  }

  void _mostrarDialogo(BuildContext context) {
    // Pre-cargamos el valor actual y lo dejamos seleccionado completo
    // para que el admin pueda borrar todo con un Backspace o sobreescribir
    // tipeando directo (reemplaza la selección).
    final controller = TextEditingController(text: valor)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: valor.length,
      );

    String transform(String raw) {
      final t = raw.trim();
      return aplicarMayusculas ? t.toUpperCase() : t;
    }

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Editar $etiqueta'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: aplicarMayusculas
              ? TextCapitalization.characters
              : TextCapitalization.none,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Escriba aquí...',
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear, color: Colors.white54),
              tooltip: 'Vaciar campo',
              onPressed: () => controller.clear(),
            ),
          ),
          onSubmitted: (_) {
            onSave(transform(controller.text));
            Navigator.pop(dCtx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () {
              onSave(transform(controller.text));
              Navigator.pop(dCtx);
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// Edita un número entero con formato AR de miles (123.456.789) en el
/// input — el valor se guarda como `int` puro (sin puntos). Para km,
/// odómetros, contadores grandes.
class DatoEditableMiles extends StatelessWidget {
  final String etiqueta;
  /// Valor actual como número (puede ser int o double — solo se usa
  /// la parte entera para mostrar y editar).
  final num? valor;
  /// Sufijo opcional para el display (ej. "km", "$").
  final String? sufijo;
  /// Callback con el `int?` parseado (null si vacío).
  final ValueChanged<int?> onSave;
  final bool editable;

  const DatoEditableMiles({
    super.key,
    required this.etiqueta,
    required this.valor,
    required this.onSave,
    this.sufijo,
    this.editable = true,
  });

  String get _display {
    if (valor == null) return '—';
    final fmt = AppFormatters.formatearMiles(valor);
    return sufijo == null ? fmt : '$fmt $sufijo';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        _display,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: Icon(
        Icons.edit_note,
        size: 22,
        color: editable ? AppColors.success : Colors.white24,
      ),
      onTap: editable ? () => _mostrarDialogo(context) : null,
    );
  }

  void _mostrarDialogo(BuildContext context) {
    // Mostramos el valor formateado en el input y dejamos seleccionado.
    final inicial =
        valor == null ? '' : AppFormatters.formatearMiles(valor);
    final controller = TextEditingController(text: inicial)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: inicial.length,
      );

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Editar $etiqueta'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [AppFormatters.inputMiles],
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Ej. 200.000',
            suffixText: sufijo,
            suffixStyle: const TextStyle(color: Colors.white54),
          ),
          onSubmitted: (_) {
            onSave(AppFormatters.parsearMiles(controller.text));
            Navigator.pop(dCtx);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () {
              onSave(AppFormatters.parsearMiles(controller.text));
              Navigator.pop(dCtx);
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

/// Selector de una opción dentro de un set fijo (radio buttons en
/// dialog). Útil para enums tipo ROL, TIPO_VEHICULO, etc.
class DatoEditableEnum extends StatelessWidget {
  final String etiqueta;
  final String valorActual;
  /// Mapa `value → label visible` con todas las opciones válidas.
  final Map<String, String> opciones;
  final IconData icono;
  final ValueChanged<String> onSave;
  final bool editable;

  const DatoEditableEnum({
    super.key,
    required this.etiqueta,
    required this.valorActual,
    required this.opciones,
    required this.icono,
    required this.onSave,
    this.editable = true,
  });

  @override
  Widget build(BuildContext context) {
    final label = opciones[valorActual] ?? valorActual;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        label,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: Icon(
        icono,
        size: 20,
        color: editable ? AppColors.success : Colors.white24,
      ),
      onTap: editable ? () => _mostrarSelector(context) : null,
    );
  }

  void _mostrarSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Seleccionar ${etiqueta.toLowerCase()}'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: opciones.entries.map((e) {
              final esActual = e.key == valorActual;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  esActual
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color:
                      esActual ? AppColors.success : Colors.white38,
                  size: 18,
                ),
                title: Text(
                  e.value,
                  style: const TextStyle(fontSize: 13, color: Colors.white),
                ),
                onTap: () {
                  Navigator.pop(dCtx);
                  if (!esActual) onSave(e.key);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

/// Variante de `DatoEditableEnum` con opción "Otro..." al final que
/// permite escribir un valor nuevo. Útil para catálogos editables como
/// MODELO de vehículo (los pre-cargados son sugerencias, pero se puede
/// agregar uno nuevo si llega un modelo distinto).
///
/// El "Otro..." abre un input de texto con `aplicarMayusculas: true`.
class DatoEditableEnumExtensible extends StatelessWidget {
  final String etiqueta;
  final String valorActual;
  /// Lista de sugerencias (sin "Otro" — se agrega automáticamente).
  /// El display muestra el valor tal cual se ingresa, no se traduce.
  final List<String> sugerencias;
  final IconData icono;
  final ValueChanged<String> onSave;
  final bool editable;
  /// Hint para el input "Otro..." (ej. "Ej. R450").
  final String? hintOtro;

  const DatoEditableEnumExtensible({
    super.key,
    required this.etiqueta,
    required this.valorActual,
    required this.sugerencias,
    required this.icono,
    required this.onSave,
    this.editable = true,
    this.hintOtro,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        valorActual.isEmpty ? '—' : valorActual,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: Icon(
        icono,
        size: 20,
        color: editable ? AppColors.success : Colors.white24,
      ),
      onTap: editable ? () => _mostrarSelector(context) : null,
    );
  }

  void _mostrarSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Seleccionar ${etiqueta.toLowerCase()}'),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...sugerencias.map((s) {
                  final esActual = s == valorActual;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      esActual
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: esActual
                          ? AppColors.success
                          : Colors.white38,
                      size: 18,
                    ),
                    title: Text(
                      s,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.white),
                    ),
                    onTap: () {
                      Navigator.pop(dCtx);
                      if (!esActual) onSave(s);
                    },
                  );
                }),
                const Divider(color: Colors.white12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.add_circle_outline,
                      color: AppColors.success, size: 18),
                  title: const Text(
                    'Otro... (escribir nuevo)',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.success,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () {
                    Navigator.pop(dCtx);
                    _mostrarInputOtro(context);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _mostrarInputOtro(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Nuevo $etiqueta'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(hintText: hintOtro ?? 'Escriba aquí...'),
          onSubmitted: (v) {
            final t = v.trim().toUpperCase();
            Navigator.pop(dCtx);
            if (t.isNotEmpty) onSave(t);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = controller.text.trim().toUpperCase();
              Navigator.pop(dCtx);
              if (t.isNotEmpty) onSave(t);
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}
