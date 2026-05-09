import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_instalada.dart';
import '../services/gomeria_service.dart';

/// Pantalla detalle de una unidad — el corazón del flujo del operador
/// de gomería. Muestra el layout de posiciones de la unidad (10 para
/// tractor, 12 para enganche) agrupado por eje. Cada posición se
/// renderiza como un tile que indica si está ocupada (con qué cubierta,
/// modelo, vida y % de vida útil consumida) o vacía. Tap en posición →
/// dialog de acciones contextual.
///
/// Para tractor mostramos también el odómetro actual (KM_ACTUAL del
/// vehículo) en la cabecera y se usa para calcular el % de vida en vivo
/// de cada cubierta instalada.
///
/// El layout es texto/tile (no CustomPainter visual). En tracción dual
/// las dos ruedas internas se dibujan pegadas y separadas de las
/// externas con un gap para reflejar la geometría física desde arriba.
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
    final posiciones = posicionesParaUnidad(widget.unidadTipo);
    // Agrupamos por eje para renderizar fila por fila (más cercano al
    // layout físico desde arriba: eje 1 al frente, eje 3 al fondo).
    final porEje = <int, List<PosicionCubierta>>{};
    for (final p in posiciones) {
      porEje.putIfAbsent(p.eje, () => []).add(p);
    }
    final ejesOrdenados = porEje.keys.toList()..sort();

    return AppScaffold(
      title: widget.unidadId,
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        // Stream del vehículo: necesario para mostrar el KM_ACTUAL en
        // cabecera y para que cada tile calcule su % de vida útil
        // consumida en vivo (KM_ACTUAL - km_unidad_al_instalar).
        stream: FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .doc(widget.unidadId)
            .snapshots(),
        builder: (ctx, vehSnap) {
          final kmActual =
              (vehSnap.data?.data()?['KM_ACTUAL'] as num?)?.toDouble();
          return StreamBuilder<List<CubiertaInstalada>>(
            stream: _service
                .streamInstalacionesActivasPorUnidad(widget.unidadId),
            builder: (ctx, snap) {
              final activas = snap.data ?? const <CubiertaInstalada>[];
              // Mapeo posicion_codigo → CubiertaInstalada activa.
              final mapa = <String, CubiertaInstalada>{};
              for (final i in activas) {
                mapa[i.posicion] = i;
              }
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Cabecera(
                      unidadId: widget.unidadId,
                      unidadTipo: widget.unidadTipo,
                      tipoVehiculo: widget.tipoVehiculo,
                      modelo: widget.modelo,
                      cantInstaladas: activas.length,
                      cantPosiciones: posiciones.length,
                      kmActual: kmActual,
                    ),
                    const SizedBox(height: 16),
                    for (final eje in ejesOrdenados) ...[
                      _EjeHeader(
                          eje: eje, posiciones: porEje[eje]!),
                      const SizedBox(height: 8),
                      _GridEje(
                        posiciones: porEje[eje]!,
                        instaladas: mapa,
                        kmActualUnidad: kmActual,
                        onTap: (p) =>
                            _onTapPosicion(context, p, mapa[p.codigo]),
                      ),
                      const SizedBox(height: 16),
                    ],
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

  const _Cabecera({
    required this.unidadId,
    required this.unidadTipo,
    required this.tipoVehiculo,
    required this.modelo,
    required this.cantInstaladas,
    required this.cantPosiciones,
    required this.kmActual,
  });

  @override
  Widget build(BuildContext context) {
    final completo = cantInstaladas == cantPosiciones;
    final esTractor = unidadTipo == TipoUnidadCubierta.tractor;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                esTractor
                    ? Icons.local_shipping_outlined
                    : Icons.rv_hookup_outlined,
                color: AppColors.accentOrange,
                size: 32,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      unidadId,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '$tipoVehiculo${modelo.isNotEmpty ? " · $modelo" : ""}',
                      style: const TextStyle(
                          color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: (completo
                          ? AppColors.accentGreen
                          : AppColors.accentOrange)
                      .withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: completo
                        ? AppColors.accentGreen
                        : AppColors.accentOrange,
                  ),
                ),
                child: Text(
                  '$cantInstaladas / $cantPosiciones',
                  style: TextStyle(
                    color: completo
                        ? AppColors.accentGreen
                        : AppColors.accentOrange,
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
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.speed, size: 16, color: Colors.white60),
                const SizedBox(width: 6),
                Text(
                  kmActual != null
                      ? '${AppFormatters.formatearMiles(kmActual)} km actuales'
                      : 'Sin lectura de odómetro',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EjeHeader extends StatelessWidget {
  final int eje;
  final List<PosicionCubierta> posiciones;
  const _EjeHeader({required this.eje, required this.posiciones});

  @override
  Widget build(BuildContext context) {
    final tipo = posiciones.first.tipoUsoRequerido;
    final etiquetaTipo = tipo == TipoUsoCubierta.direccion
        ? 'DIRECCIÓN'
        : 'TRACCIÓN';
    final color = tipo == TipoUsoCubierta.direccion
        ? AppColors.accentOrange
        : AppColors.accentBlue;
    return Row(
      children: [
        Text(
          'EJE $eje',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(3),
            border: Border.all(color: color, width: 0.5),
          ),
          child: Text(
            etiquetaTipo,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// GRID DE POSICIONES POR EJE
// =============================================================================

class _GridEje extends StatelessWidget {
  final List<PosicionCubierta> posiciones;
  final Map<String, CubiertaInstalada> instaladas;
  final double? kmActualUnidad;
  final ValueChanged<PosicionCubierta> onTap;

  const _GridEje({
    required this.posiciones,
    required this.instaladas,
    required this.kmActualUnidad,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Para reflejar la geometría física dejamos un gap visual entre
    // las dos ruedas internas de un eje dual y un poco menos entre las
    // pares IZQ_EXT|IZQ_INT (que físicamente están pegadas). Para el
    // eje de dirección (2 posiciones) no hay duales: simétrico nomás.
    final esDual = posiciones.length == 4;

    // En mobile (< 480 dp) un eje dual con 4 tiles en una sola Row
    // dejaba ~79 dp por tile y el modelo ("Bridgestone R268 295/80R22.5"
    // fontSize 9 maxLines 2) wrappeaba a 3 líneas → overflow.
    // Splitting en 2 filas IZQ + DER para mobile, manteniendo la
    // representación física correcta. Eje no dual (2 ruedas) entra OK
    // en cualquier ancho.
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final usar2x2 = esDual && constraints.maxWidth < 480;
        if (usar2x2) {
          return Column(
            children: [
              Row(
                children: [
                  Expanded(child: _wrapTile(posiciones[0])),
                  Expanded(child: _wrapTile(posiciones[1])),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _wrapTile(posiciones[2])),
                  Expanded(child: _wrapTile(posiciones[3])),
                ],
              ),
            ],
          );
        }
        // Layout original 1x4 con gap eje en el medio.
        final widgets = <Widget>[];
        for (var i = 0; i < posiciones.length; i++) {
          widgets.add(Expanded(child: _wrapTile(posiciones[i])));
          if (esDual && i == 1) {
            widgets.add(const SizedBox(width: 28));
          }
        }
        return Row(children: widgets);
      },
    );
  }

  Widget _wrapTile(PosicionCubierta p) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: _PosicionTile(
          posicion: p,
          instalada: instaladas[p.codigo],
          kmActualUnidad: kmActualUnidad,
          onTap: () => onTap(p),
        ),
      );
}

class _PosicionTile extends StatelessWidget {
  final PosicionCubierta posicion;
  final CubiertaInstalada? instalada;
  final double? kmActualUnidad;
  final VoidCallback onTap;

  const _PosicionTile({
    required this.posicion,
    required this.instalada,
    required this.kmActualUnidad,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ocupada = instalada != null;
    if (!ocupada) {
      return _tileVacia();
    }
    final pct =
        instalada!.porcentajeVidaConsumida(kmActualUnidad: kmActualUnidad);
    final color = _colorDesgaste(pct);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              posicion.lado,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 9,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              instalada!.cubiertaCodigo,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (instalada!.modeloEtiqueta != null) ...[
              const SizedBox(height: 2),
              Text(
                _resumenModelo(instalada!.modeloEtiqueta!),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 9,
                  height: 1.1,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.accentTeal.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    instalada!.vidaAlInstalar == 1
                        ? 'NUEVA'
                        : 'V${instalada!.vidaAlInstalar}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            if (pct != null) ...[
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: (pct / 100).clamp(0, 1).toDouble(),
                  minHeight: 4,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${pct.toStringAsFixed(0)}%',
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _tileVacia() {
    final color = AppColors.accentOrange.withValues(alpha: 0.5);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 6),
        decoration: BoxDecoration(
          border: Border.all(color: color, width: 1.5),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_circle_outline, color: color, size: 22),
            const SizedBox(height: 6),
            Text(
              posicion.lado,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Color del marco / progreso según el % de vida útil consumida.
  /// `null` (sin estimación) → verde neutro. <80 verde, <100 ámbar,
  /// >=100 rojo (pasó la vida estimada).
  static Color _colorDesgaste(double? pct) {
    if (pct == null) return AppColors.accentGreen;
    if (pct >= 100) return AppColors.accentRed;
    if (pct >= 80) return AppColors.accentOrange;
    return AppColors.accentGreen;
  }

  /// Saca el "— Tracción"/"— Dirección" del final de la etiqueta del
  /// modelo para no duplicar info que ya está en el header del eje.
  /// "Bridgestone R268 295/80R22.5 — Tracción" → "Bridgestone R268
  /// 295/80R22.5".
  static String _resumenModelo(String etiqueta) {
    final i = etiqueta.indexOf(' — ');
    return i >= 0 ? etiqueta.substring(0, i) : etiqueta;
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
        width: 380,
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
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        'No hay cubiertas '
                        '${widget.posicion.tipoUsoRequerido.etiqueta.toUpperCase()} '
                        'en depósito.',
                        style: const TextStyle(color: Colors.amber),
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
              const SizedBox(height: 12),
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
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentGreen),
          child: _guardando
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator())
              : const Text('INSTALAR'),
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
    } catch (e) {
      setState(() => _guardando = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
            width: 380,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.tire_repair,
                          color: AppColors.accentGreen),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          i.cubiertaCodigo,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (i.modeloEtiqueta != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      i.modeloEtiqueta!,
                      style: const TextStyle(
                          color: Colors.white70, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 12),
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
                    const SizedBox(height: 10),
                    _BarraVida(porcentaje: pct),
                  ],
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _operando ? null : _abrirRegistroControl,
                    icon: const Icon(Icons.fact_check_outlined,
                        color: AppColors.accentPurple, size: 18),
                    label: const Text(
                      'REGISTRAR CONTROL (presión / banda)',
                      style: TextStyle(
                          color: AppColors.accentPurple, fontSize: 11),
                    ),
                  ),
                  const SizedBox(height: 4),
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
            TextButton(
              onPressed: _operando ? null : () => Navigator.pop(context),
              child: const Text('CANCELAR'),
            ),
            OutlinedButton(
              onPressed: _operando
                  ? null
                  : () => _retirar(EstadoCubierta.descartada),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentRed,
                side: const BorderSide(color: AppColors.accentRed),
              ),
              child: const Text('DESCARTAR'),
            ),
            OutlinedButton(
              onPressed: _operando ? null : _abrirRotar,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.accentTeal,
                side: const BorderSide(color: AppColors.accentTeal),
              ),
              child: const Text('ROTAR'),
            ),
            ElevatedButton(
              onPressed: _operando
                  ? null
                  : () => _retirar(EstadoCubierta.enDeposito),
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.accentBlue),
              child: _operando
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator())
                  : const Text('AL DEPÓSITO'),
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
    } catch (e) {
      setState(() => _operando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
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
    } catch (e) {
      setState(() => _operando = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
                    const TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ),
            Expanded(
              child: Text(
                valor,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
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
    } catch (e) {
      setState(() => _operando = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
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
        width: 360,
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
            const SizedBox(height: 12),
            TextField(
              controller: _bandaCtrl,
              decoration: const InputDecoration(
                labelText: 'Profundidad de banda (mm)',
                hintText: 'Ej. 12.5',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 8),
            const Text(
              'Completá al menos uno de los dos.',
              style: TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
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
          child: const Text('GUARDAR'),
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
        width: 380,
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
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Elegí la posición destino. Si está ocupada, '
                      'se hace un intercambio (swap).',
                      style: TextStyle(color: Colors.white60, fontSize: 12),
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
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
      ],
    );
  }

  Widget _opcion(BuildContext context, PosicionCubierta p,
      CubiertaInstalada? actual) {
    final ocupada = actual != null;
    final color = ocupada ? AppColors.accentTeal : AppColors.accentGreen;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => Navigator.pop(context, p),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.06),
            border: Border.all(color: color.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                ocupada ? Icons.swap_horiz : Icons.check_circle_outline,
                color: color,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.etiqueta,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (ocupada)
                      Text(
                        'Tiene ${actual.cubiertaCodigo} — se intercambian.',
                        style:
                            const TextStyle(color: Colors.white60, fontSize: 11),
                      )
                    else
                      const Text(
                        'Vacía',
                        style:
                            TextStyle(color: Colors.white60, fontSize: 11),
                      ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.white38),
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
        ? AppColors.accentRed
        : porcentaje >= 80
            ? AppColors.accentOrange
            : AppColors.accentGreen;
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
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Spacer(),
            Text(
              '${porcentaje.toStringAsFixed(0)}%',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: (porcentaje / 100).clamp(0, 1).toDouble(),
            minHeight: 6,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}
