import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_instalada.dart';
import '../services/gomeria_service.dart';
import '../widgets/esquema_unidad_view.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Pantalla detalle de una unidad — el corazón del flujo del operador
/// de gomería. Muestra un esquema visual de la unidad desde arriba
/// (CustomPainter en `EsquemaUnidadView`) con cada cubierta en su
/// posición física real, color según % vida útil consumida y patrón
/// interno distinto entre dirección (chevrons) y tracción (tacos). Tap
/// en cubierta → dialog de acciones contextual.
///
/// Para tractor mostramos también el odómetro actual (KM_ACTUAL del
/// vehículo) en la cabecera y se usa para calcular el % de vida en vivo
/// de cada cubierta instalada.
class GomeriaUnidadDetalleScreen extends StatefulWidget {
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;
  final String tipoVehiculo;
  final String modelo;

  const GomeriaUnidadDetalleScreen({
    super.key,
    required this.unidadId,
    required this.unidadTipo,
    required this.tipoVehiculo,
    required this.modelo,
  });

  @override
  State<GomeriaUnidadDetalleScreen> createState() =>
      _GomeriaUnidadDetalleScreenState();
}

class _GomeriaUnidadDetalleScreenState
    extends State<GomeriaUnidadDetalleScreen> {
  final _service = GomeriaService();

  @override
  Widget build(BuildContext context) {
    final cantPosiciones = posicionesParaUnidad(widget.unidadTipo).length;

    return AppScaffold(
      title: widget.unidadId,
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        // Stream del vehículo: necesario para mostrar el KM_ACTUAL en
        // cabecera y para que cada cubierta calcule su % de vida útil
        // consumida en vivo (KM_ACTUAL - km_unidad_al_instalar).
        stream: FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .doc(widget.unidadId)
            .snapshots(),
        builder: (ctx, vehSnap) {
          if (vehSnap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar la unidad',
              subtitle: vehSnap.error.toString(),
            );
          }
          final kmActual =
              (vehSnap.data?.data()?['KM_ACTUAL'] as num?)?.toDouble();
          return StreamBuilder<List<CubiertaInstalada>>(
            stream: _service
                .streamInstalacionesActivasPorUnidad(widget.unidadId),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return AppErrorState(
                  title: 'No se pudieron cargar las cubiertas instaladas',
                  subtitle: snap.error.toString(),
                );
              }
              final activas = snap.data ?? const <CubiertaInstalada>[];
              // Mapeo posicion_codigo → CubiertaInstalada activa.
              final mapa = <String, CubiertaInstalada>{};
              var cantLegacy = 0;
              for (final i in activas) {
                mapa[i.posicion] = i;
                if (i.legacyInicial) cantLegacy++;
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.md,
                  AppSpacing.lg,
                  AppSpacing.xl,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Cabecera(
                      unidadId: widget.unidadId,
                      unidadTipo: widget.unidadTipo,
                      tipoVehiculo: widget.tipoVehiculo,
                      modelo: widget.modelo,
                      cantInstaladas: activas.length,
                      cantPosiciones: cantPosiciones,
                      kmActual: kmActual,
                      cantLegacy: cantLegacy,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    EsquemaUnidadView(
                      tipo: widget.unidadTipo,
                      instaladas: mapa,
                      kmActualUnidad: kmActual,
                      onTapPosicion: (p) =>
                          _onTapPosicion(context, p, mapa[p.codigo]),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _onTapPosicion(
    BuildContext context,
    PosicionCubierta posicion,
    CubiertaInstalada? actual,
  ) async {
    if (actual == null) {
      // Vacía → diálogo de instalación.
      await showDialog(
        context: context,
        builder: (ctx) => _InstalarCubiertaDialog(
          unidadId: widget.unidadId,
          unidadTipo: widget.unidadTipo,
          posicion: posicion,
          service: _service,
        ),
      );
    } else {
      // Ocupada → diálogo de acciones (retirar / descartar).
      await showDialog(
        context: context,
        builder: (ctx) => _PosicionOcupadaDialog(
          posicion: posicion,
          instalada: actual,
          service: _service,
        ),
      );
    }
  }
}

// =============================================================================
// CABECERA
// =============================================================================

class _Cabecera extends StatelessWidget {
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;
  final String tipoVehiculo;
  final String modelo;
  final int cantInstaladas;
  final int cantPosiciones;
  final double? kmActual;
  final int cantLegacy;

  const _Cabecera({
    required this.unidadId,
    required this.unidadTipo,
    required this.tipoVehiculo,
    required this.modelo,
    required this.cantInstaladas,
    required this.cantPosiciones,
    required this.kmActual,
    required this.cantLegacy,
  });

  @override
  Widget build(BuildContext context) {
    final completo = cantInstaladas == cantPosiciones;
    final esTractor = unidadTipo == TipoUnidadCubierta.tractor;
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.lg - 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                esTractor
                    ? Icons.local_shipping_outlined
                    : Icons.rv_hookup_outlined,
                color: AppColors.warning,
                size: 32,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unidadId,
                      style: AppType.heading.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$tipoVehiculo${modelo.isNotEmpty ? " · $modelo" : ""}',
                      style: AppType.label
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md - 2,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: (completo
                          ? AppColors.success
                          : AppColors.warning)
                      .withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: completo
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                ),
                child: Text(
                  '$cantInstaladas / $cantPosiciones',
                  style: TextStyle(
                    color: completo
                        ? AppColors.success
                        : AppColors.warning,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          // Odómetro: solo tiene sentido para tractor (los enganches no
          // tienen KM_ACTUAL propio; sus km vienen del cruce con
          // ASIGNACIONES_ENGANCHE en Fase 2).
          if (esTractor) ...[
            const SizedBox(height: AppSpacing.md - 2),
            Row(
              children: [
                const Icon(Icons.speed,
                    size: 16, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Text(
                  kmActual != null
                      ? '${AppFormatters.formatearMiles(kmActual)} km actuales'
                      : 'Sin lectura de odómetro',
                  style: AppType.label.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ],
          if (cantLegacy > 0) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Container(
                  width: 16,
                  height: 16,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.surface0,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.textPrimary,
                      width: 1,
                    ),
                  ),
                  child: const Text(
                    'L',
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '$cantLegacy ${cantLegacy == 1 ? "cubierta sin datos previos" : "cubiertas sin datos previos"} (carga inicial)',
                    style: AppType.label
                        .copyWith(color: AppColors.textSecondary),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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

// =============================================================================
// DIALOG INSTALAR
// =============================================================================

class _InstalarCubiertaDialog extends StatefulWidget {
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;
  final PosicionCubierta posicion;
  final GomeriaService service;

  const _InstalarCubiertaDialog({
    required this.unidadId,
    required this.unidadTipo,
    required this.posicion,
    required this.service,
  });

  @override
  State<_InstalarCubiertaDialog> createState() =>
      _InstalarCubiertaDialogState();
}

class _InstalarCubiertaDialogState extends State<_InstalarCubiertaDialog> {
  Cubierta? _cubiertaSel;
  final _motivoCtrl = TextEditingController();
  bool _guardando = false;

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: Text('Instalar en ${widget.posicion.etiqueta}'),
      content: SizedBox(
        // Anti-overflow (auditoria 2026-05-17): antes width: 380 pisaba
        // viewports < 380dp (Samsung J4 / Moto E entry). Clamp al espacio
        // disponible del AlertDialog (viewport - 80 insets), tope 380.
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Solo mostramos cubiertas EN_DEPOSITO con tipo_uso compatible
              // (la validación STRICT igual la hace el service, pero filtrar
              // acá evita opciones inválidas en la UI).
              StreamBuilder<List<Cubierta>>(
                stream: widget.service.streamCubiertasEnDeposito(
                    tipoUso: widget.posicion.tipoUsoRequerido),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const SizedBox(
                      height: 60,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final cubiertas = snap.data ?? const <Cubierta>[];
                  if (cubiertas.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Text(
                        'No hay cubiertas '
                        '${widget.posicion.tipoUsoRequerido.etiqueta.toUpperCase()} '
                        'en depósito.',
                        style: const TextStyle(color: AppColors.warning),
                      ),
                    );
                  }
                  cubiertas.sort((a, b) => a.codigo.compareTo(b.codigo));
                  return DropdownButtonFormField<Cubierta>(
                    initialValue: _cubiertaSel,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Cubierta'),
                    items: cubiertas
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(
                                '${c.codigo} · ${c.modeloEtiqueta}'
                                '${c.vidas > 1 ? " (${c.vidas - 1}× recapada)" : ""}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _cubiertaSel = v),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _motivoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Motivo (opcional)',
                  hintText: 'Ej. rotación, reemplazo por pinchazo',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: _guardando ? null : () => Navigator.pop(context),
        ),
        AppButton(
          label: 'Instalar',
          isLoading: _guardando,
          onPressed: _guardando ? null : _guardar,
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    final c = _cubiertaSel;
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una cubierta.')),
      );
      return;
    }
    setState(() => _guardando = true);
    try {
      await widget.service.instalar(
        cubiertaId: c.id,
        unidadId: widget.unidadId,
        unidadTipo: widget.unidadTipo,
        posicionCodigo: widget.posicion.codigo,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        motivo: _motivoCtrl.text.trim().isEmpty ? null : _motivoCtrl.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e, s) {
      setState(() => _guardando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo instalar la cubierta. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }
}

// =============================================================================
// DIALOG POSICIÓN OCUPADA
// =============================================================================

class _PosicionOcupadaDialog extends StatefulWidget {
  final PosicionCubierta posicion;
  final CubiertaInstalada instalada;
  final GomeriaService service;

  const _PosicionOcupadaDialog({
    required this.posicion,
    required this.instalada,
    required this.service,
  });

  @override
  State<_PosicionOcupadaDialog> createState() =>
      _PosicionOcupadaDialogState();
}

class _PosicionOcupadaDialogState extends State<_PosicionOcupadaDialog> {
  final _motivoCtrl = TextEditingController();
  bool _operando = false;

  @override
  void dispose() {
    _motivoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.instalada;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(i.unidadId)
          .snapshots(),
      builder: (ctx, vehSnap) {
        final kmActual =
            (vehSnap.data?.data()?['KM_ACTUAL'] as num?)?.toDouble();
        final pct = i.porcentajeVidaConsumida(kmActualUnidad: kmActual);
        return AlertDialog(
          backgroundColor: AppColors.background,
          title: Text(widget.posicion.etiqueta),
          content: SizedBox(
            width: (MediaQuery.of(ctx).size.width - 80).clamp(240.0, 380.0),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tire_repair,
                          color: AppColors.success),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          i.cubiertaCodigo,
                          style: AppType.heading.copyWith(
                            color: AppColors.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (i.modeloEtiqueta != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      i.modeloEtiqueta!,
                      style: AppType.label
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.md),
                  _info('Vida al instalar', '${i.vidaAlInstalar}'),
                  _info('Días instalada', '${i.diasDuracion()}'),
                  if (i.kmUnidadAlInstalar != null)
                    _info('Km del tractor al instalar',
                        AppFormatters.formatearMiles(i.kmUnidadAlInstalar)),
                  if (kmActual != null && i.kmUnidadAlInstalar != null)
                    _info(
                      'Km recorridos por la cubierta',
                      AppFormatters.formatearMiles(
                          (kmActual - i.kmUnidadAlInstalar!).clamp(0, double.infinity)),
                    ),
                  if (i.kmVidaEstimadaAlInstalar != null)
                    _info('Km esperados',
                        AppFormatters.formatearMiles(i.kmVidaEstimadaAlInstalar)),
                  if (i.ultimaPresionPsi != null)
                    _info('Última presión',
                        '${i.ultimaPresionPsi} PSI'),
                  if (i.ultimaProfundidadBandaMm != null)
                    _info('Última banda',
                        '${i.ultimaProfundidadBandaMm} mm'),
                  if (pct != null) ...[
                    const SizedBox(height: AppSpacing.md - 2),
                    _BarraVida(porcentaje: pct),
                  ],
                  const SizedBox(height: AppSpacing.sm),
                  AppButton.ghost(
                    label: 'Registrar control (presión / banda)',
                    icon: Icons.fact_check_outlined,
                    onPressed: _operando ? null : _abrirRegistroControl,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  TextField(
                    controller: _motivoCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Motivo del retiro (opcional)',
                      hintText: 'Ej. rotación, pinchazo, desgaste',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            AppButton.ghost(
              label: 'Cancelar',
              onPressed: _operando ? null : () => Navigator.pop(context),
            ),
            AppButton.danger(
              label: 'Descartar',
              onPressed: _operando
                  ? null
                  : () => _retirar(EstadoCubierta.descartada),
            ),
            AppButton.secondary(
              label: 'Rotar',
              onPressed: _operando ? null : _abrirRotar,
            ),
            AppButton(
              label: 'Al depósito',
              isLoading: _operando,
              onPressed: _operando
                  ? null
                  : () => _retirar(EstadoCubierta.enDeposito),
            ),
          ],
        );
      },
    );
  }

  Future<void> _abrirRegistroControl() async {
    final res = await showDialog<_Lectura>(
      context: context,
      builder: (ctx) => const _RegistrarControlDialog(),
    );
    if (res == null) return;
    setState(() => _operando = true);
    try {
      await widget.service.registrarLectura(
        instalacionId: widget.instalada.id,
        presionPsi: res.presionPsi,
        profundidadBandaMm: res.profundidadMm,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      setState(() => _operando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Control registrado.')),
        );
      }
    } catch (e, s) {
      setState(() => _operando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo registrar el control. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }

  Future<void> _abrirRotar() async {
    final navigator = Navigator.of(context);
    final destino = await showDialog<PosicionCubierta>(
      context: context,
      builder: (ctx) => _SelectorPosicionDestinoDialog(
        instalada: widget.instalada,
        posicionOrigen: widget.posicion,
      ),
    );
    if (destino == null) return;
    setState(() => _operando = true);
    try {
      await widget.service.rotar(
        instalacionOrigenId: widget.instalada.id,
        posicionDestinoCodigo: destino.codigo,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        motivo: _motivoCtrl.text.trim().isEmpty ? null : _motivoCtrl.text,
      );
      if (mounted) navigator.pop();
    } catch (e, s) {
      setState(() => _operando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo rotar la cubierta. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }

  Widget _info(String etiqueta, String valor) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(
          children: [
            // 180 → 140: en mobile el dialog tenía ~327 dp internos y
            // sólo 147 quedaban para el valor (insuficiente para
            // "1.234.567 km"). Bajamos label a 140 + ellipsis ambos.
            SizedBox(
              width: 140,
              child: Text(
                etiqueta,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:
                    AppType.label.copyWith(color: AppColors.textSecondary),
              ),
            ),
            Expanded(
              child: Text(
                valor,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.label.copyWith(color: AppColors.textPrimary),
              ),
            ),
          ],
        ),
      );

  Future<void> _retirar(EstadoCubierta destino) async {
    setState(() => _operando = true);
    try {
      await widget.service.retirar(
        instalacionId: widget.instalada.id,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        motivo: _motivoCtrl.text.trim().isEmpty ? null : _motivoCtrl.text,
        destinoFinal: destino,
      );
      if (mounted) Navigator.pop(context);
    } catch (e, s) {
      setState(() => _operando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo retirar la cubierta. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }
}

// =============================================================================
// DIALOG REGISTRAR CONTROL (presión / profundidad de banda)
// =============================================================================

class _Lectura {
  final int? presionPsi;
  final double? profundidadMm;
  const _Lectura({this.presionPsi, this.profundidadMm});
  bool get vacio => presionPsi == null && profundidadMm == null;
}

class _RegistrarControlDialog extends StatefulWidget {
  const _RegistrarControlDialog();

  @override
  State<_RegistrarControlDialog> createState() =>
      _RegistrarControlDialogState();
}

class _RegistrarControlDialogState extends State<_RegistrarControlDialog> {
  final _presionCtrl = TextEditingController();
  final _bandaCtrl = TextEditingController();

  @override
  void dispose() {
    _presionCtrl.dispose();
    _bandaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: const Text('Registrar control'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 360.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _presionCtrl,
              decoration: const InputDecoration(
                labelText: 'Presión (PSI)',
                hintText: 'Ej. 110',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [AppFormatters.inputMiles],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _bandaCtrl,
              decoration: const InputDecoration(
                labelText: 'Profundidad de banda (mm)',
                hintText: 'Ej. 12.5',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Completá al menos uno de los dos.',
              style: AppType.label.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: () => Navigator.pop(context),
        ),
        AppButton(
          label: 'Guardar',
          onPressed: () {
            final lectura = _Lectura(
              presionPsi: AppFormatters.parsearMiles(_presionCtrl.text),
              profundidadMm: double.tryParse(
                  _bandaCtrl.text.trim().replaceAll(',', '.')),
            );
            if (lectura.vacio) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('Completá al menos uno de los dos.')),
              );
              return;
            }
            Navigator.pop(context, lectura);
          },
        ),
      ],
    );
  }
}

// =============================================================================
// SELECTOR DE POSICIÓN DESTINO (rotación dentro de la misma unidad)
// =============================================================================

/// Lista las posiciones de la misma unidad como tarjetas tappeables.
/// Marca cuáles aceptan la cubierta de origen (mismo `tipoUso`),
/// cuáles están vacías y cuáles tienen cubierta (rotación = swap).
/// El usuario tappea una y se cierra el dialog devolviendo la posición.
class _SelectorPosicionDestinoDialog extends StatelessWidget {
  final CubiertaInstalada instalada;
  final PosicionCubierta posicionOrigen;

  const _SelectorPosicionDestinoDialog({
    required this.instalada,
    required this.posicionOrigen,
  });

  @override
  Widget build(BuildContext context) {
    final posiciones = posicionesParaUnidad(instalada.unidadTipo)
        .where((p) =>
            p.codigo != posicionOrigen.codigo &&
            p.tipoUsoRequerido == posicionOrigen.tipoUsoRequerido)
        .toList();
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: Text('Rotar ${instalada.cubiertaCodigo}'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.cubiertasInstaladas)
              .where('unidad_id', isEqualTo: instalada.unidadId)
              .where('hasta', isNull: true)
              .snapshots(),
          builder: (ctx, snap) {
            final activasPorPos = <String, CubiertaInstalada>{};
            for (final d in snap.data?.docs ?? const []) {
              final i = CubiertaInstalada.fromDoc(d);
              activasPorPos[i.posicion] = i;
            }
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                    child: Text(
                      'Elegí la posición destino. Si está ocupada, '
                      'se hace un intercambio (swap).',
                      style: AppType.label
                          .copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                  for (final p in posiciones)
                    _opcion(context, p, activasPorPos[p.codigo]),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: () => Navigator.pop(context),
        ),
      ],
    );
  }

  Widget _opcion(BuildContext context, PosicionCubierta p,
      CubiertaInstalada? actual) {
    final ocupada = actual != null;
    final color = ocupada ? AppColors.brandSoft : AppColors.success;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        onTap: () => Navigator.pop(context, p),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.md - 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Row(
            children: [
              Icon(
                ocupada ? Icons.swap_horiz : Icons.check_circle_outline,
                color: color,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.etiqueta,
                      style: AppType.label.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (ocupada)
                      Text(
                        'Tiene ${actual.cubiertaCodigo} — se intercambian.',
                        style: AppType.label
                            .copyWith(color: AppColors.textSecondary),
                      )
                    else
                      Text(
                        'Vacía',
                        style: AppType.label
                            .copyWith(color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right,
                  color: AppColors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarraVida extends StatelessWidget {
  final double porcentaje;
  const _BarraVida({required this.porcentaje});

  @override
  Widget build(BuildContext context) {
    final color = porcentaje >= 100
        ? AppColors.error
        : porcentaje >= 80
            ? AppColors.warning
            : AppColors.success;
    final etiqueta = porcentaje >= 100
        ? 'Pasó la vida estimada'
        : porcentaje >= 80
            ? 'Próxima a fin de vida'
            : 'Vida útil consumida';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              etiqueta,
              style: AppType.eyebrow.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
            const Spacer(),
            Text(
              '${porcentaje.toStringAsFixed(0)}%',
              style: AppType.label.copyWith(color: color, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (porcentaje / 100).clamp(0, 1).toDouble(),
            minHeight: 6,
            backgroundColor: AppColors.borderSubtle,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}
