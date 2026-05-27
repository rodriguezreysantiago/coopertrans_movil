import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/app_logger.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../data/checklist_data.dart';

/// Checklist mensual del chofer (sobre tractor o batea/tolva).
///
/// El chofer responde BUE/REG/MAL para cada item. Si elige REG o MAL,
/// debe completar una observación. Al guardar, el documento se sube a
/// Firestore (con soporte offline: si no hay red, queda en cache local
/// y se sube cuando recupera conexión).
class UserChecklistFormScreen extends StatefulWidget {
  final String tipo; // "TRACTOR" o "BATEA"
  final String patente;

  const UserChecklistFormScreen({
    super.key,
    required this.tipo,
    required this.patente,
  });

  @override
  State<UserChecklistFormScreen> createState() =>
      _UserChecklistFormScreenState();
}

class _UserChecklistFormScreenState
    extends State<UserChecklistFormScreen> {
  final Map<String, String> _respuestas = {};
  final Map<String, String> _observaciones = {};

  /// Items que faltan contestar/justificar — para resaltarlos en rojo.
  List<String> _preguntasConError = [];
  bool _enviando = false;

  Map<String, List<String>> get _secciones => widget.tipo == 'TRACTOR'
      ? ChecklistData.itemsTractor
      : ChecklistData.itemsBatea;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: AppScaffold(
        title: 'Checklist ${widget.tipo}',
        body: Column(
          children: [
            _HeaderInfo(patente: widget.patente),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                children: [
                  const _AvisoObligatorio(),
                  const SizedBox(height: 20),
                  ..._secciones.entries.map(
                    (sec) => _Seccion(
                      titulo: sec.key,
                      items: sec.value,
                      respuestas: _respuestas,
                      observaciones: _observaciones,
                      preguntasConError: _preguntasConError,
                      onEstadoChange: (item, estado) =>
                          setState(() {
                        _respuestas[item] = estado;
                        _preguntasConError.remove(item);
                        // CRITICO (auditoria 2026-05-17): antes
                        // borrabamos la observacion al volver a BUE,
                        // pero eso perdia silenciosamente el texto que
                        // el chofer habia escrito si solo tocaba BUE
                        // por error y volvia a REG/MAL. Ahora la
                        // mantenemos siempre — si el estado final es
                        // BUE, el _validarYEnviar la ignora; si REG/MAL,
                        // queda lo que el chofer ya habia tipeado.
                      }),
                      onObservacion: (item, obs) {
                        _observaciones[item] = obs;
                        if (obs.trim().isNotEmpty) {
                          setState(() =>
                              _preguntasConError.remove(item));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
            _BotonEnviar(
              enviando: _enviando,
              onPressed: _validarYEnviar,
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // VALIDACIÓN Y ENVÍO
  // ---------------------------------------------------------------------------

  Future<void> _validarYEnviar() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    final faltantes = <String>[];
    for (final sec in _secciones.values) {
      for (final item in sec) {
        final respuesta = _respuestas[item];
        if (respuesta == null) {
          faltantes.add(item);
        } else if ((respuesta == 'REG' || respuesta == 'MAL') &&
            (_observaciones[item]?.trim().isEmpty ?? true)) {
          faltantes.add(item);
        }
      }
    }

    if (faltantes.isNotEmpty) {
      setState(() => _preguntasConError = faltantes);
      _notificarError(
        messenger,
        'Complete o justifique los puntos resaltados en rojo.',
      );
      return;
    }

    setState(() => _enviando = true);

    try {
      final now = DateTime.now();
      final payload = {
        'ANIO': now.year,
        'DNI': PrefsService.dni,
        'FECHA': FieldValue.serverTimestamp(),
        'MES': now.month,
        'NOMBRE': PrefsService.nombre.toUpperCase(),
        'DOMINIO': widget.patente,
        'TIPO': widget.tipo,
        'RESPUESTAS': _respuestas,
        'OBSERVACIONES': _observaciones,
        'SINCRONIZADO_LOCAL': true,
      };

      // Modo offline: timeout de 15s. Si no hay red, Firebase guarda
      // localmente y subirá el doc cuando recupere conexión. El timeout
      // anterior era 4s y disparaba false positives en redes 3G/4G
      // lentas (Bahía Blanca rural) — el chofer veía "se subirá
      // automáticamente" cuando el doc igual estaba sincronizando OK.
      await FirebaseFirestore.instance
          .collection(AppCollections.checklists)
          .add(payload)
          .timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw TimeoutException('OFFLINE_MODE');
        },
      );

      if (!mounted) return;
      AppFeedback.successOn(messenger, 'Registro sincronizado en la nube');
      navigator.pop();
    } catch (e, stack) {
      if (!mounted) return;
      if (e is TimeoutException && e.message == 'OFFLINE_MODE') {
        // Breadcrumb: si después aparece un error real, sirve de contexto.
        AppLogger.log(
          'CHECKLIST timeout offline-mode dni=${PrefsService.dni} '
          'patente=${widget.patente} tipo=${widget.tipo}',
        );
        AppFeedback.warningOn(messenger, 'Sin conexión. Guardado en el equipo, se subirá automáticamente.');
        navigator.pop();
      } else {
        // Reportar a Crashlytics con contexto: hasta hoy estos errores
        // se mostraban en pantalla y se perdían (sin reproducción).
        AppLogger.recordError(
          e,
          stack,
          reason: 'CHECKLIST guardar falló — '
              'dni=${PrefsService.dni} patente=${widget.patente} '
              'tipo=${widget.tipo}',
        );
        setState(() => _enviando = false);
        _notificarError(messenger, 'Error crítico al guardar: $e');
      }
    }
  }

  void _notificarError(
    ScaffoldMessengerState messenger,
    String mensaje,
  ) {
    AppFeedback.errorOn(messenger, mensaje);
  }
}

// =============================================================================
// HEADER (fijo arriba con la patente)
// =============================================================================

class _HeaderInfo extends StatelessWidget {
  final String patente;
  const _HeaderInfo({required this.patente});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(15),
        border: Border(
          bottom: BorderSide(color: AppColors.success.withAlpha(40)),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.tag, color: AppColors.success, size: 18),
          const SizedBox(width: 8),
          const Text('UNIDAD: ',
              style: TextStyle(color: Colors.white60, fontSize: 12)),
          Text(
            patente,
            style: const TextStyle(
              color: AppColors.success,
              fontWeight: FontWeight.bold,
              fontSize: 14,
              letterSpacing: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// AVISO INICIAL
// =============================================================================

class _AvisoObligatorio extends StatelessWidget {
  const _AvisoObligatorio();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.accentOrange.withAlpha(20),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentOrange.withAlpha(50)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline,
              color: AppColors.accentOrange, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Es obligatorio completar todos los puntos. Detalle cualquier novedad en el campo de texto.',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SECCIÓN DEL CHECKLIST
// =============================================================================

class _Seccion extends StatelessWidget {
  final String titulo;
  final List<String> items;
  final Map<String, String> respuestas;
  final Map<String, String> observaciones;
  final List<String> preguntasConError;
  final void Function(String item, String estado) onEstadoChange;
  final void Function(String item, String observacion) onObservacion;

  const _Seccion({
    required this.titulo,
    required this.items,
    required this.respuestas,
    required this.observaciones,
    required this.preguntasConError,
    required this.onEstadoChange,
    required this.onObservacion,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header de la sección
        Container(
          padding: const EdgeInsets.symmetric(
              vertical: 10, horizontal: 15),
          width: double.infinity,
          decoration: BoxDecoration(
            color:
                Theme.of(context).colorScheme.primary.withAlpha(30),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: Theme.of(context).colorScheme.primary.withAlpha(50),
            ),
          ),
          child: Text(
            titulo.toUpperCase(),
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 12),
        ...items.map(
          (item) => _ItemPregunta(
            item: item,
            respuesta: respuestas[item],
            observacion: observaciones[item],
            tieneError: preguntasConError.contains(item),
            onEstado: (estado) => onEstadoChange(item, estado),
            onObservacion: (obs) => onObservacion(item, obs),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

// =============================================================================
// ITEM DEL CHECKLIST
// =============================================================================

class _ItemPregunta extends StatefulWidget {
  final String item;
  final String? respuesta;
  final String? observacion;
  final bool tieneError;
  final void Function(String estado) onEstado;
  final void Function(String observacion) onObservacion;

  const _ItemPregunta({
    required this.item,
    required this.respuesta,
    required this.observacion,
    required this.tieneError,
    required this.onEstado,
    required this.onObservacion,
  });

  @override
  State<_ItemPregunta> createState() => _ItemPreguntaState();
}

class _ItemPreguntaState extends State<_ItemPregunta> {
  // Controller propio para preservar el texto cuando AnimatedSize esconde y
  // vuelve a mostrar el TextField (al alternar BUE↔REG/MAL). Antes era
  // uncontrolled: el texto seguía guardado en el Map del padre, pero al
  // re-aparecer el campo se veía VACÍO y confundía al chofer. Como
  // _ItemPregunta queda en la misma posición de la lista, Flutter conserva
  // este State al rebuild del padre → el controller sobrevive y reinserta
  // el texto correcto. Auditoría 2026-05-22.
  late TextEditingController _obsController;

  @override
  void initState() {
    super.initState();
    _obsController = TextEditingController(text: widget.observacion ?? '');
  }

  @override
  void dispose() {
    _obsController.dispose();
    super.dispose();
  }

  Color _colorEstado(String estado) {
    switch (estado) {
      case 'BUE':
        return AppColors.success;
      case 'REG':
        return AppColors.accentOrange;
      case 'MAL':
        return AppColors.accentRed;
      default:
        return Colors.white24;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mostrarObservacion =
        widget.respuesta == 'REG' || widget.respuesta == 'MAL';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: widget.tieneError
              ? AppColors.accentRed
              : Colors.white.withAlpha(15),
          width: widget.tieneError ? 2 : 1,
        ),
        boxShadow: widget.tieneError
            ? [
                BoxShadow(
                  color: AppColors.accentRed.withAlpha(50),
                  blurRadius: 8,
                  spreadRadius: 1,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.item,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 14),
          // Wrap en lugar de Row: si en pantalla angosta los 3 chips
          // no entran, se reacomodan en lugar de overflowing.
          Wrap(
            spacing: 12,
            runSpacing: 8,
            alignment: WrapAlignment.spaceEvenly,
            children: ['BUE', 'REG', 'MAL'].map((estado) {
              final seleccionado = widget.respuesta == estado;
              return ChoiceChip(
                label: SizedBox(
                  width: 50,
                  child: Center(
                    child: Text(
                      estado,
                      style: TextStyle(
                        color:
                            seleccionado ? Colors.black : Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                selected: seleccionado,
                selectedColor: _colorEstado(estado),
                backgroundColor: Colors.black26,
                side: BorderSide(
                  color: seleccionado
                      ? _colorEstado(estado)
                      : Colors.white24,
                ),
                onSelected: (_) => widget.onEstado(estado),
              );
            }).toList(),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: mostrarObservacion
                ? Padding(
                    padding: const EdgeInsets.only(top: 14),
                    child: TextField(
                      controller: _obsController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                      ),
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Explique la novedad encontrada...',
                        hintStyle: const TextStyle(color: Colors.white38),
                        filled: true,
                        fillColor: Colors.black.withAlpha(100),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                            color: _colorEstado(widget.respuesta!),
                          ),
                        ),
                      ),
                      onChanged: widget.onObservacion,
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BOTÓN ENVIAR (fijo abajo)
// =============================================================================

class _BotonEnviar extends StatelessWidget {
  final bool enviando;
  final VoidCallback onPressed;

  const _BotonEnviar({
    required this.enviando,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(100),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.green,
            minimumSize: const Size(double.infinity, 55),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
          onPressed: enviando ? null : onPressed,
          child: enviando
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2,
                  ),
                )
              : const Text(
                  'GUARDAR REGISTRO FINAL',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    letterSpacing: 1,
                  ),
                ),
        ),
      ),
    );
  }
}
