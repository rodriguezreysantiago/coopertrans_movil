import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
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
            return const AppLoadingState();
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
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
            children: [
              _SeccionService(vehiculo: vehiculo),
              const SizedBox(height: 12),
              _SeccionAdvertencias(volvo: volvo),
              const SizedBox(height: 12),
              _SeccionTelemetria(vehiculo: vehiculo, volvo: volvo),
              const SizedBox(height: 12),
              _SeccionHistorial(taller: taller),
            ],
          );
        },
      ),
    );
  }
}

Color _colorSeveridad(SeveridadAdvertencia s) {
  switch (s) {
    case SeveridadAdvertencia.critico:
      return AppColors.accentRed;
    case SeveridadAdvertencia.alto:
      return AppColors.accentOrange;
    case SeveridadAdvertencia.medio:
      return AppColors.accentAmber;
    case SeveridadAdvertencia.bajo:
      return Colors.white54;
  }
}

/// Encabezado de sección reutilizable.
class _TituloSeccion extends StatelessWidget {
  final IconData icon;
  final String texto;
  const _TituloSeccion(this.icon, this.texto);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 2),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white60),
          const SizedBox(width: 8),
          Text(
            texto.toUpperCase(),
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _Fila extends StatelessWidget {
  final String label;
  final String valor;
  final Color? color;
  const _Fila(this.label, this.valor, {this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ),
          Expanded(
            flex: 5,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              style: TextStyle(
                color: color ?? Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
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
    final ultimoKm = (vehiculo['ULTIMO_SERVICE_KM'] as num?)?.toDouble();
    final kmActual = (vehiculo['KM_ACTUAL'] as num?)?.toDouble();
    final fechaRaw = vehiculo['ULTIMO_SERVICE_FECHA']?.toString() ?? '';
    final serviceDist = AppMantenimiento.serviceDistanceDesdeManual(
      ultimoServiceKm: ultimoKm,
      kmActual: kmActual,
    );
    final estado = AppMantenimiento.clasificar(serviceDist);
    final proximo = ultimoKm != null
        ? ultimoKm + AppMantenimiento.intervaloServiceKm
        : null;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                  child: _TituloSeccion(Icons.build_circle_outlined, 'Service')),
              MantenimientoBadge(serviceDistanceKm: serviceDist),
            ],
          ),
          _Fila('Estado', estado.etiqueta, color: estado.color),
          if (ultimoKm != null)
            _Fila('Último service',
                '${AppFormatters.formatearMiles(ultimoKm)} km'),
          if (fechaRaw.isNotEmpty && fechaRaw != '-')
            _Fila('Fecha último service', AppFormatters.formatearFecha(fechaRaw)),
          if (kmActual != null)
            _Fila('Km actual', '${AppFormatters.formatearMiles(kmActual)} km'),
          if (proximo != null)
            _Fila('Próximo service',
                '${AppFormatters.formatearMiles(proximo)} km'),
          if (ultimoKm != null && kmActual != null)
            _Fila('Recorrido desde el último',
                '${AppFormatters.formatearMiles(kmActual - ultimoKm)} km'),
          const SizedBox(height: 4),
          const Text(
            'Intervalo 50.000 km · dato automático desde Volvo Connect',
            style: TextStyle(
                color: Colors.white38, fontSize: 10, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }
}

// ─── Advertencias (tell-tales) ──────────────────────────────────────────────
class _SeccionAdvertencias extends StatelessWidget {
  final Map<String, dynamic> volvo;
  const _SeccionAdvertencias({required this.volvo});

  @override
  Widget build(BuildContext context) {
    final tt = volvo['tell_tales'];
    final tieneDatos = tt is List && tt.isNotEmpty;
    final advertencias = clasificarAdvertencias(tt is List ? tt : null);

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TituloSeccion(
              Icons.warning_amber_outlined, 'Advertencias del tablero'),
          if (advertencias.isEmpty)
            Text(
              tieneDatos
                  ? 'Sin advertencias activas — ningún testigo en rojo o amarillo.'
                  : 'Esta unidad no transmite los testigos del tablero (modelo sin esa telemetría).',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            ...advertencias.map((a) {
              final color = _colorSeveridad(a.severidad);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.circle, size: 10, color: color),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(a.nombre,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withAlpha(25),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        a.estado == 'RED' ? 'CRÍTICO' : a.severidad.name.toUpperCase(),
                        style: TextStyle(
                            color: color,
                            fontSize: 9,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
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
    final horas = (volvo['horas_motor'] as num?)?.toDouble();
    final combustible = (volvo['combustible_pct'] as num?)?.toDouble();
    final adblue = (volvo['adblue_pct'] as num?)?.toDouble();
    final temp = (volvo['temp_motor_c'] as num?)?.toDouble();
    final kmActual = (vehiculo['KM_ACTUAL'] as num?)?.toDouble();

    final filas = <Widget>[
      if (horas != null)
        _Fila('Horas de motor',
            '${AppFormatters.formatearMiles(horas.roundToDouble())} h'),
      if (kmActual != null)
        _Fila('Km actual', '${AppFormatters.formatearMiles(kmActual)} km'),
      if (combustible != null)
        _Fila('Combustible', '${combustible.round()} %'),
      if (adblue != null) _Fila('AdBlue', '${adblue.round()} %'),
      if (temp != null) _Fila('Temp. motor', '${temp.round()} °C'),
    ];

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _TituloSeccion(Icons.insights_outlined, 'Telemetría'),
          if (filas.isEmpty)
            const Text('Sin datos de telemetría.',
                style: TextStyle(color: Colors.white54, fontSize: 12))
          else
            ...filas,
        ],
      ),
    );
  }
}

// ─── Historial de taller ─────────────────────────────────────────────────────
class _SeccionHistorial extends StatelessWidget {
  final Map<String, dynamic> taller;
  const _SeccionHistorial({required this.taller});

  @override
  Widget build(BuildContext context) {
    final servicios = (taller['servicios'] as List?) ?? const [];
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TituloSeccion(Icons.history, 'Historial de taller (${servicios.length})'),
          if (servicios.isEmpty)
            const Text(
              'Sin historial de taller. Se sincroniza desde Volvo Connect.',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            )
          else
            ...servicios.map((s) => _ItemVisita(visita: s as Map)),
        ],
      ),
    );
  }
}

class _ItemVisita extends StatelessWidget {
  final Map visita;
  const _ItemVisita({required this.visita});

  @override
  Widget build(BuildContext context) {
    final esService = visita['es_service'] == true;
    final fecha = (visita['fecha'] ?? '').toString();
    final km = (visita['km'] as num?)?.toDouble();
    final taller = (visita['taller'] ?? '').toString();
    final ops = (visita['operaciones'] as List?) ?? const [];
    final color = esService ? AppColors.accentGreen : Colors.white38;

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(left: 18, bottom: 8),
        leading: Icon(
          esService ? Icons.build_outlined : Icons.handyman_outlined,
          color: color,
          size: 18,
        ),
        title: Text(
          '${AppFormatters.formatearFecha(fecha)}'
          '${km != null ? ' · ${AppFormatters.formatearMiles(km)} km' : ''}',
          style: const TextStyle(
              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          '${esService ? 'Service' : 'Reparación'}'
          '${taller.isNotEmpty ? ' · $taller' : ''}',
          style: TextStyle(color: color, fontSize: 11),
        ),
        children: ops.isEmpty
            ? [
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Sin detalle de operaciones.',
                      style: TextStyle(color: Colors.white38, fontSize: 11)),
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
                      const Text('• ',
                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(desc.isEmpty ? grupo : desc,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 12)),
                            if (grupo.isNotEmpty && desc.isNotEmpty)
                              Text(grupo,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 10)),
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
