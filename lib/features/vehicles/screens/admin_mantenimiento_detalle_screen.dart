// lib/features/vehicles/screens/admin_mantenimiento_detalle_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — detalle de mantenimiento en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - la carga de 3 fuentes por patente (`_cargar`): VEHICULOS (service),
//     VOLVO_ESTADO (tell-tales + telemetría), VEHICULOS_TALLER (historial),
//   - la clasificación de advertencias (`clasificarAdvertencias`),
//   - el cálculo de serviceDistance manual (`AppMantenimiento`),
//   - el gráfico de km/día (fl_chart) + KPIs + tabla por mes que lee
//     `OdometrosService` (`cargarUltimosDias` / `agruparPorMes`).
//
// Layout Núcleo:
//   ┌─ Hero: eyebrow MANTENIMIENTO · patente · marca/modelo · estado badge ─┐
//   ├─ AppKpiStrip: al próximo service · km actual · recorrido ─────────────┤
//   ├─ Service (bento, filas con AppHairline) ──────────────────────────────┤
//   ├─ Advertencias del tablero (AppDot + AppBadge por severidad) ──────────┤
//   ├─ Telemetría (filas) ──────────────────────────────────────────────────┤
//   ├─ Km recorridos (KPIs + fl_chart + tabla) ─────────────────────────────┤
//   └─ Historial de taller (ExpansionTile por visita) ──────────────────────┘
//
// Reglas duras: tokens (context.colors), números en AppType.mono, faltante
// → "—", estados → AppDot/AppBadge semántico, sin overflow.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/odometros_service.dart';
import '../utils/volvo_telltales_es.dart';
import '../widgets/mantenimiento_badge.dart';

/// Detalle de mantenimiento de UNA unidad — todo junto: service, advertencias
/// del tablero, telemetría e historial de taller completo. Lee 3 fuentes por
/// patente: VEHICULOS (service), VOLVO_ESTADO (tell-tales + telemetría) y
/// VEHICULOS_TALLER (historial, que escribe volvo_sync).
class AdminMantenimientoDetalleScreen extends StatelessWidget {
  final String patente;
  const AdminMantenimientoDetalleScreen({super.key, required this.patente});

  Future<List<Map<String, dynamic>>> _cargar() async {
    final db = FirebaseFirestore.instance;
    final res = await Future.wait([
      db.collection(AppCollections.vehiculos).doc(patente).get(),
      db.collection('VOLVO_ESTADO').doc(patente).get(),
      db.collection('VEHICULOS_TALLER').doc(patente).get(),
    ]);
    return res.map((d) => (d.data() ?? <String, dynamic>{})).toList();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mantenimiento — $patente',
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _cargar(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppSkeletonList(count: 5, conAvatar: false);
          }
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el mantenimiento',
              subtitle: snap.error.toString(),
            );
          }
          final vehiculo = snap.data![0];
          final volvo = snap.data![1];
          final taller = snap.data![2];
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
            children: [
              _Hero(patente: patente, vehiculo: vehiculo),
              const SizedBox(height: AppSpacing.mdDense),
              _SeccionService(vehiculo: vehiculo),
              const SizedBox(height: AppSpacing.mdDense),
              _SeccionAdvertencias(volvo: volvo),
              const SizedBox(height: AppSpacing.mdDense),
              _SeccionTelemetria(vehiculo: vehiculo, volvo: volvo),
              const SizedBox(height: AppSpacing.mdDense),
              _SeccionKmRecorridos(patente: patente),
              const SizedBox(height: AppSpacing.mdDense),
              _SeccionHistorial(taller: taller),
            ],
          );
        },
      ),
    );
  }
}

/// Color semántico Núcleo para cada estado de mantenimiento. (El
/// `MantenimientoEstadoX.color` usa lima/limón fuera de paleta; acá
/// honramos la tinta única indigo + semánticos.)
Color _colorEstado(BuildContext context, MantenimientoEstado e) {
  final c = context.colors;
  switch (e) {
    case MantenimientoEstado.vencido:
      return c.error;
    case MantenimientoEstado.urgente:
    case MantenimientoEstado.programar:
    case MantenimientoEstado.atencion:
      return c.warning;
    case MantenimientoEstado.ok:
      return c.success;
    case MantenimientoEstado.sinDato:
      return c.textMuted;
  }
}

Color _colorSeveridad(BuildContext context, SeveridadAdvertencia s) {
  final c = context.colors;
  switch (s) {
    case SeveridadAdvertencia.critico:
      return c.error;
    case SeveridadAdvertencia.alto:
    case SeveridadAdvertencia.medio:
      return c.warning;
    case SeveridadAdvertencia.bajo:
      return c.textMuted;
  }
}

// =============================================================================
// HERO · patente + marca/modelo + estado del service
// =============================================================================

class _Hero extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> vehiculo;
  const _Hero({required this.patente, required this.vehiculo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final marca = (vehiculo['MARCA'] ?? '').toString();
    final modelo = (vehiculo['MODELO'] ?? '').toString();
    final marcaModelo = '$marca $modelo'.trim();

    final ultimoKm = (vehiculo['ULTIMO_SERVICE_KM'] as num?)?.toDouble();
    final kmActual = (vehiculo['KM_ACTUAL'] as num?)?.toDouble();
    final serviceDist = AppMantenimiento.serviceDistanceDesdeManual(
      ultimoServiceKm: ultimoKm,
      kmActual: kmActual,
    );
    final estado = AppMantenimiento.clasificar(serviceDist);
    final estadoColor = _colorEstado(context, estado);
    final recorrido = (ultimoKm != null && kmActual != null)
        ? kmActual - ultimoKm
        : null;

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('MANTENIMIENTO'),
              const Spacer(),
              AppBadge(
                text: estado.etiqueta.toUpperCase(),
                color: estadoColor,
                dot: true,
                size: AppBadgeSize.sm,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            patente,
            style: AppType.h3.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            marcaModelo.isEmpty ? 'Sin marca/modelo' : marcaModelo,
            style: AppType.body.copyWith(color: c.textSecondary),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.lg),
          AppKpiStrip(
            stats: [
              AppStat(
                label: 'Al próximo service',
                value: serviceDist == null
                    ? '—'
                    : (serviceDist <= 0
                        ? 'Vencido'
                        : AppFormatters.formatearMiles(serviceDist)),
                unit: (serviceDist == null || serviceDist <= 0) ? null : 'km',
                valueStyle: AppType.h4,
                accent: estadoColor,
              ),
              AppStat(
                label: 'Km actual',
                value: kmActual == null
                    ? '—'
                    : AppFormatters.formatearMiles(kmActual),
                unit: kmActual == null ? null : 'km',
                valueStyle: AppType.h4,
              ),
              AppStat(
                label: 'Recorrido',
                value: recorrido == null
                    ? '—'
                    : AppFormatters.formatearMiles(recorrido),
                unit: recorrido == null ? null : 'km',
                valueStyle: AppType.h4,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// PRIMITIVAS NÚCLEO — sección bento + fila label/valor
// =============================================================================

/// Tarjeta de sección Núcleo: eyebrow (+ dot opcional) + contenido.
class _Seccion extends StatelessWidget {
  final String titulo;
  final Color? accentDot;
  final Widget? trailing;
  final List<Widget> children;

  const _Seccion({
    required this.titulo,
    this.accentDot,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: AppEyebrow(titulo, color: accentDot)),
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

/// Fila label (izq) / valor (der) — Núcleo.
class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final Color? valorColor;
  final bool mono;

  const _Linea(this.label, this.valor, {this.valorColor, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valBase = mono ? AppType.mono : AppType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              style: valBase.copyWith(
                color: valorColor ?? c.text,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Service ──────────────────────────────────────────────────────────────
class _SeccionService extends StatelessWidget {
  final Map<String, dynamic> vehiculo;
  const _SeccionService({required this.vehiculo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ultimoKm = (vehiculo['ULTIMO_SERVICE_KM'] as num?)?.toDouble();
    final kmActual = (vehiculo['KM_ACTUAL'] as num?)?.toDouble();
    final fechaRaw = vehiculo['ULTIMO_SERVICE_FECHA']?.toString() ?? '';
    final serviceDist = AppMantenimiento.serviceDistanceDesdeManual(
      ultimoServiceKm: ultimoKm,
      kmActual: kmActual,
    );
    final estado = AppMantenimiento.clasificar(serviceDist);
    final estadoColor = _colorEstado(context, estado);
    final proximo = ultimoKm != null
        ? ultimoKm + AppMantenimiento.intervaloServiceKm
        : null;

    return _Seccion(
      titulo: 'SERVICE',
      accentDot: estadoColor,
      trailing: MantenimientoBadge(serviceDistanceKm: serviceDist),
      children: [
        _Linea('Estado', estado.etiqueta, valorColor: estadoColor),
        if (ultimoKm != null)
          _Linea('Último service',
              '${AppFormatters.formatearMiles(ultimoKm)} km',
              mono: true),
        if (fechaRaw.isNotEmpty && fechaRaw != '-')
          _Linea('Fecha último service',
              AppFormatters.formatearFecha(fechaRaw),
              mono: true),
        if (kmActual != null)
          _Linea('Km actual', '${AppFormatters.formatearMiles(kmActual)} km',
              mono: true),
        if (proximo != null)
          _Linea('Próximo service',
              '${AppFormatters.formatearMiles(proximo)} km',
              mono: true),
        if (ultimoKm != null && kmActual != null)
          _Linea('Recorrido desde el último',
              '${AppFormatters.formatearMiles(kmActual - ultimoKm)} km',
              mono: true),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Intervalo 50.000 km · dato automático desde Volvo Connect',
          style: AppType.bodySm.copyWith(color: c.textMuted),
        ),
      ],
    );
  }
}

// ─── Advertencias (tell-tales) ──────────────────────────────────────────────
class _SeccionAdvertencias extends StatelessWidget {
  final Map<String, dynamic> volvo;
  const _SeccionAdvertencias({required this.volvo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tt = volvo['tell_tales'];
    final tieneDatos = tt is List && tt.isNotEmpty;
    final advertencias = clasificarAdvertencias(tt is List ? tt : null);
    // Si hay alguna crítica, el dot de la sección va en rojo; sino ámbar
    // (hay advertencias) o verde (todo limpio).
    final hayCritica =
        advertencias.any((a) => a.severidad == SeveridadAdvertencia.critico);
    final dot = advertencias.isEmpty
        ? c.success
        : (hayCritica ? c.error : c.warning);

    return _Seccion(
      titulo: 'ADVERTENCIAS DEL TABLERO',
      accentDot: dot,
      trailing: advertencias.isNotEmpty
          ? Text('${advertencias.length}',
              style: AppType.monoSm.copyWith(color: c.textMuted))
          : null,
      children: [
        if (advertencias.isEmpty)
          Text(
            tieneDatos
                ? 'Sin advertencias activas — ningún testigo en rojo o amarillo.'
                : 'Esta unidad no transmite los testigos del tablero (modelo sin esa telemetría).',
            style: AppType.body.copyWith(color: c.textSecondary),
          )
        else
          for (var i = 0; i < advertencias.length; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.sm),
              const AppHairline(),
              const SizedBox(height: AppSpacing.sm),
            ],
            _FilaAdvertencia(adv: advertencias[i]),
          ],
      ],
    );
  }
}

class _FilaAdvertencia extends StatelessWidget {
  final Advertencia adv;
  const _FilaAdvertencia({required this.adv});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _colorSeveridad(context, adv.severidad);
    return Row(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AppDot(color, size: 7),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            adv.nombre,
            style: AppType.body.copyWith(color: c.text),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        AppBadge(
          text: adv.estado == 'RED'
              ? 'CRÍTICO'
              : adv.severidad.name.toUpperCase(),
          color: color,
          size: AppBadgeSize.sm,
        ),
      ],
    );
  }
}

// ─── Telemetría ─────────────────────────────────────────────────────────────
class _SeccionTelemetria extends StatelessWidget {
  final Map<String, dynamic> vehiculo;
  final Map<String, dynamic> volvo;
  const _SeccionTelemetria({required this.vehiculo, required this.volvo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final horas = (volvo['horas_motor'] as num?)?.toDouble();
    final combustible = (volvo['combustible_pct'] as num?)?.toDouble();
    final adblue = (volvo['adblue_pct'] as num?)?.toDouble();
    final temp = (volvo['temp_motor_c'] as num?)?.toDouble();
    final kmActual = (vehiculo['KM_ACTUAL'] as num?)?.toDouble();

    final filas = <Widget>[
      if (horas != null)
        _Linea('Horas de motor',
            '${AppFormatters.formatearMiles(horas.roundToDouble())} h',
            mono: true),
      if (kmActual != null)
        _Linea('Km actual', '${AppFormatters.formatearMiles(kmActual)} km',
            mono: true),
      if (combustible != null)
        _Linea('Combustible', '${combustible.round()} %', mono: true),
      if (adblue != null) _Linea('AdBlue', '${adblue.round()} %', mono: true),
      if (temp != null) _Linea('Temp. motor', '${temp.round()} °C', mono: true),
    ];

    return _Seccion(
      titulo: 'TELEMETRÍA',
      children: [
        if (filas.isEmpty)
          Text('Sin datos de telemetría.',
              style: AppType.body.copyWith(color: c.textSecondary))
        else
          ...filas,
      ],
    );
  }
}

// ─── Historial de taller ─────────────────────────────────────────────────────
class _SeccionHistorial extends StatelessWidget {
  final Map<String, dynamic> taller;
  const _SeccionHistorial({required this.taller});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final servicios = (taller['servicios'] as List?) ?? const [];
    return _Seccion(
      titulo: 'HISTORIAL DE TALLER',
      trailing: Text('${servicios.length}',
          style: AppType.monoSm.copyWith(color: c.textMuted)),
      children: [
        if (servicios.isEmpty)
          Text(
            'Sin historial de taller. Se sincroniza desde Volvo Connect.',
            style: AppType.body.copyWith(color: c.textSecondary),
          )
        else
          ...servicios.map((s) => _ItemVisita(visita: s as Map)),
      ],
    );
  }
}

class _ItemVisita extends StatelessWidget {
  final Map visita;
  const _ItemVisita({required this.visita});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esService = visita['es_service'] == true;
    final fecha = (visita['fecha'] ?? '').toString();
    final km = (visita['km'] as num?)?.toDouble();
    final taller = (visita['taller'] ?? '').toString();
    final ops = (visita['operaciones'] as List?) ?? const [];
    final color = esService ? c.success : c.textMuted;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding:
            const EdgeInsets.only(left: AppSpacing.lg, bottom: AppSpacing.sm),
        leading: Icon(
          esService ? Icons.build_outlined : Icons.handyman_outlined,
          color: color,
          size: 18,
        ),
        title: Text(
          '${AppFormatters.formatearFecha(fecha)}'
          '${km != null ? ' · ${AppFormatters.formatearMiles(km)} km' : ''}',
          style: AppType.body.copyWith(
              color: c.text, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${esService ? 'Service' : 'Reparación'}'
          '${taller.isNotEmpty ? ' · $taller' : ''}',
          style: AppType.monoSm.copyWith(color: color),
        ),
        children: ops.isEmpty
            ? [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Sin detalle de operaciones.',
                      style: AppType.bodySm.copyWith(color: c.textMuted)),
                )
              ]
            : ops.map<Widget>((o) {
                final op = o as Map;
                final desc = (op['desc'] ?? '').toString();
                final grupo = (op['grupo'] ?? '').toString();
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('• ',
                          style: AppType.body.copyWith(color: c.textMuted)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(desc.isEmpty ? grupo : desc,
                                style: AppType.bodySm
                                    .copyWith(color: c.textSecondary)),
                            if (grupo.isNotEmpty && desc.isNotEmpty)
                              Text(grupo,
                                  style: AppType.monoSm
                                      .copyWith(color: c.textMuted)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
      ),
    );
  }
}

/// Km recorridos por día — gráfico últimos 30 días + KPIs del mes en
/// curso vs mes anterior + tabla últimos 3 meses (km, L, l/100km).
/// Lee `TELEMETRIA_HISTORICO` (snapshot diario que escribe la CF
/// `telemetriaSnapshotScheduled` cada 6h). El `km` y `litros_acumulados`
/// son acumulados → calculamos delta diario client-side.
class _SeccionKmRecorridos extends StatefulWidget {
  final String patente;
  const _SeccionKmRecorridos({required this.patente});

  @override
  State<_SeccionKmRecorridos> createState() => _SeccionKmRecorridosState();
}

class _SeccionKmRecorridosState extends State<_SeccionKmRecorridos> {
  late Future<_KmRecorridosData> _future;

  @override
  void initState() {
    super.initState();
    _future = _cargar();
  }

  Future<_KmRecorridosData> _cargar() async {
    final dias = await OdometrosService.cargarUltimosDias(
        patente: widget.patente, dias: 30);
    final meses = await OdometrosService.agruparPorMes(
        patente: widget.patente, meses: 3);
    return _KmRecorridosData(dias: dias, meses: meses);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _Seccion(
      titulo: 'KM RECORRIDOS',
      children: [
        FutureBuilder<_KmRecorridosData>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const AppSkeleton.box(height: 120);
            }
            if (snap.hasError || snap.data == null) {
              return Text(
                'No se pudo cargar: ${snap.error ?? "sin datos"}',
                style: AppType.body.copyWith(color: c.textSecondary),
              );
            }
            final data = snap.data!;
            if (data.dias.isEmpty) {
              return Text(
                'Sin snapshots para esta unidad (probable no-Volvo o nueva).',
                style: AppType.body.copyWith(color: c.textSecondary),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _KpisMes(meses: data.meses),
                const SizedBox(height: AppSpacing.lg),
                _GraficoDias(dias: data.dias),
                const SizedBox(height: AppSpacing.lg),
                _TablaMeses(meses: data.meses),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _KmRecorridosData {
  final List<OdometroDia> dias;
  final Map<String, MesAgregado> meses;
  const _KmRecorridosData({required this.dias, required this.meses});
}

class _KpisMes extends StatelessWidget {
  final Map<String, MesAgregado> meses;
  const _KpisMes({required this.meses});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (meses.isEmpty) return const SizedBox.shrink();
    final lista = meses.values.toList();
    final mesActual = lista.first;
    final mesAnterior = lista.length > 1 ? lista[1] : null;
    return AppKpiStrip(
      stats: [
        AppStat(
          label: 'Km mes en curso',
          value: AppFormatters.formatearMiles(mesActual.kmTotal.toDouble()),
          valueStyle: AppType.h4,
          delta: '${mesActual.diasConDato} días con dato',
          deltaColor: c.textMuted,
        ),
        if (mesAnterior != null)
          AppStat(
            label: 'Km mes anterior',
            value:
                AppFormatters.formatearMiles(mesAnterior.kmTotal.toDouble()),
            valueStyle: AppType.h4,
            delta: '${mesAnterior.diasConDato} días con dato',
            deltaColor: c.textMuted,
          ),
        AppStat(
          label: 'L/100km mes',
          value: mesActual.litros100km > 0
              ? mesActual.litros100km.toStringAsFixed(1)
              : '—',
          valueStyle: AppType.h4,
          delta: '${mesActual.litrosTotal.toStringAsFixed(0)} L consumidos',
          deltaColor: c.textMuted,
        ),
      ],
    );
  }
}

class _GraficoDias extends StatelessWidget {
  final List<OdometroDia> dias;
  const _GraficoDias({required this.dias});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Filtramos los días con delta > 0 (el primero suele tener 0 por no
    // tener día previo). La serie va cronológicamente ascendente.
    final cronologico = dias.reversed.toList();
    final spots = <FlSpot>[];
    var maxKm = 0.0;
    for (var i = 0; i < cronologico.length; i++) {
      final k = cronologico[i].deltaKm.toDouble();
      spots.add(FlSpot(i.toDouble(), k));
      if (k > maxKm) maxKm = k;
    }
    if (spots.length < 2) {
      return SizedBox(
        height: 60,
        child: Center(
          child: Text(
            'Necesitamos más días para graficar',
            style: AppType.body.copyWith(color: c.textSecondary),
          ),
        ),
      );
    }
    final maxY = maxKm <= 0 ? 100.0 : (maxKm * 1.15).ceilToDouble();
    final ejeStyle = AppType.monoSm.copyWith(color: c.textMuted);
    return SizedBox(
      height: 160,
      child: LineChart(
        LineChartData(
          minY: 0,
          maxY: maxY,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (v) => FlLine(
              color: c.border,
              strokeWidth: 1,
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 32,
                interval: maxY / 4,
                getTitlesWidget: (v, m) =>
                    Text(v.toInt().toString(), style: ejeStyle),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                interval: (cronologico.length / 5).ceilToDouble(),
                reservedSize: 22,
                getTitlesWidget: (v, m) {
                  final i = v.toInt();
                  if (i < 0 || i >= cronologico.length) return const Text('');
                  final f = cronologico[i].fecha;
                  if (f.length < 10) return const Text('');
                  return Text('${f.substring(8, 10)}/${f.substring(5, 7)}',
                      style: ejeStyle);
                },
              ),
            ),
          ),
          borderData: FlBorderData(show: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: c.brand,
              barWidth: 2,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: c.brand.withValues(alpha: 0.15),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TablaMeses extends StatelessWidget {
  final Map<String, MesAgregado> meses;
  const _TablaMeses({required this.meses});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (meses.isEmpty) return const SizedBox.shrink();
    return DataTable(
      headingRowHeight: 32,
      dataRowMinHeight: 30,
      dataRowMaxHeight: 36,
      columnSpacing: AppSpacing.lg,
      horizontalMargin: 4,
      dividerThickness: 1,
      headingTextStyle: AppType.eyebrow.copyWith(color: c.textMuted),
      dataTextStyle: AppType.mono.copyWith(color: c.text),
      columns: const [
        DataColumn(label: Text('MES')),
        DataColumn(label: Text('KM'), numeric: true),
        DataColumn(label: Text('L'), numeric: true),
        DataColumn(label: Text('L/100KM'), numeric: true),
        DataColumn(label: Text('DÍAS'), numeric: true),
      ],
      rows: meses.values
          .map((m) => DataRow(cells: [
                DataCell(Text(m.mes)),
                DataCell(Text(
                    AppFormatters.formatearMiles(m.kmTotal.toDouble()))),
                DataCell(Text(m.litrosTotal.toStringAsFixed(0))),
                DataCell(Text(m.litros100km > 0
                    ? m.litros100km.toStringAsFixed(1)
                    : '—')),
                DataCell(Text(m.diasConDato.toString())),
              ]))
          .toList(),
    );
  }
}
