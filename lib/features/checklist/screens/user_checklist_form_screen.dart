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

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Checklist mensual del chofer (sobre tractor o batea/tolva).
///
/// El chofer responde BUE/REG/MAL para cada item. Si elige REG o MAL,
/// debe completar una observación. Al guardar, el documento se sube a
/// Firestore (con soporte offline: si no hay red, queda en cache local
/// y se sube cuando recupera conexión).
///
/// REFACTOR NÚCLEO · jun 2026 — solo el árbol de widgets. Es del CHOFER:
/// va full-screen (AppScaffold con fondo). El estado del form
/// (`_respuestas` / `_observaciones` / `_preguntasConError`), la
/// validación, el guardado con timeout offline, los `TextEditingController`
/// de observación (preservados en `_ItemPreguntaState`) y la navegación
/// quedaron INTACTOS.
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
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                children: [
                  const _AvisoObligatorio(),
                  const SizedBox(height: AppSpacing.xl),
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
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(bottom: BorderSide(color: c.border)),
      ),
      child: Row(
        children: [
          const AppEyebrow('Unidad'),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              patente,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.mono.copyWith(
                color: c.brand,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
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
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: c.textMuted, size: 18),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Es obligatorio completar todos los puntos. Detallá cualquier '
              'novedad en el campo de texto.',
              style: AppType.bodySm.copyWith(color: c.textSecondary),
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
        // Header de la sección — eyebrow Núcleo.
        Padding(
          padding: const EdgeInsets.only(
              left: AppSpacing.xs, bottom: AppSpacing.md),
          child: AppEyebrow(titulo),
        ),
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
        const SizedBox(height: AppSpacing.xl),
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

  Color _colorEstado(BuildContext context, String estado) {
    final c = context.colors;
    switch (estado) {
      case 'BUE':
        return c.success;
      case 'REG':
        return c.warning;
      case 'MAL':
        return c.error;
      default:
        return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final mostrarObservacion =
        widget.respuesta == 'REG' || widget.respuesta == 'MAL';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      margin: const EdgeInsets.only(bottom: AppSpacing.mdDense),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(
          color: widget.tieneError ? c.error : c.border,
          width: widget.tieneError ? 1.5 : 1,
        ),
        boxShadow: widget.tieneError
            ? [
                BoxShadow(
                  color: c.error.withValues(alpha: 0.2),
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
            style: AppType.body.copyWith(
              color: c.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          // Segmented control de 3 estados (BUE/REG/MAL). Mantiene el
          // callback `onEstado` por estado — solo cambia el visual.
          Row(
            children: [
              for (final estado in const ['BUE', 'REG', 'MAL']) ...[
                Expanded(
                  child: _ChipEstado(
                    estado: estado,
                    seleccionado: widget.respuesta == estado,
                    color: _colorEstado(context, estado),
                    onTap: () => widget.onEstado(estado),
                  ),
                ),
                if (estado != 'MAL') const SizedBox(width: AppSpacing.sm),
              ],
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            child: mostrarObservacion
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.md),
                    child: TextField(
                      controller: _obsController,
                      style: AppType.body.copyWith(color: c.text),
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Explicá la novedad encontrada…',
                        hintStyle:
                            AppType.body.copyWith(color: c.textPlaceholder),
                        filled: true,
                        fillColor: c.surface1,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md, vertical: AppSpacing.sm),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          borderSide: BorderSide(color: c.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          borderSide: BorderSide(color: c.border),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          borderSide: BorderSide(
                            color: _colorEstado(context, widget.respuesta!),
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

/// Botón de estado del checklist (BUE/REG/MAL). Seleccionado: relleno con
/// el color de estado y texto sobre el fondo. Inactivo: borde hairline.
class _ChipEstado extends StatelessWidget {
  final String estado;
  final bool seleccionado;
  final Color color;
  final VoidCallback onTap;

  const _ChipEstado({
    required this.estado,
    required this.seleccionado,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm + 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: seleccionado ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: seleccionado ? color : c.border,
          ),
        ),
        child: Text(
          estado,
          style: AppType.label.copyWith(
            color: seleccionado ? c.bg : c.textSecondary,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
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
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface1,
        border: Border(top: BorderSide(color: c.border)),
      ),
      child: SafeArea(
        top: false,
        child: AppButton(
          label: 'Guardar registro final',
          size: AppButtonSize.lg,
          expand: true,
          isLoading: enviando,
          onPressed: enviando ? null : onPressed,
        ),
      ),
    );
  }
}
