import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

/// Detalle ICM individual de un chofer, con el número **oficial de Sitrack**
/// (lo que audita YPF, MÁS BAJO = MEJOR):
///   - Header: nombre + DNI + ICM del mes + severidad.
///   - Comparativa con el mes anterior (¿mejoró o empeoró?).
///   - ICM urbano vs no-urbano (dónde maneja peor).
///   - Desglose de infracciones (altas / medias / leves) + excesos de
///     velocidad + conducción agresiva.
///
/// Se llega desde el ranking / reporte / card de inicio con el DNI como
/// argumento de ruta.
class IcmDetalleChoferScreen extends StatefulWidget {
  const IcmDetalleChoferScreen({super.key});

  @override
  State<IcmDetalleChoferScreen> createState() =>
      _IcmDetalleChoferScreenState();
}

class _IcmDetalleChoferScreenState extends State<IcmDetalleChoferScreen> {
  Future<_DetalleData>? _future;
  String _dni = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null) return; // cargar 1 sola vez
    final args = ModalRoute.of(context)?.settings.arguments;
    _dni = args is String ? args : '';
    if (_dni.isEmpty) return;
    _future = _cargar(_dni);
  }

  Future<_DetalleData> _cargar(String dni) async {
    final db = FirebaseFirestore.instance;
    final idActual = IcmOficialService.periodoId();
    final idAnterior = IcmOficialService.periodoId(offsetMeses: -1);
    final periodos = await Future.wait([
      IcmOficialService.cargarPeriodo(db, idActual),
      IcmOficialService.cargarPeriodo(db, idAnterior),
    ]);
    // Nombre desde EMPLEADOS (por si el doc oficial trae el nombre Sitrack
    // distinto / vacío).
    final empSnap = await db.collection('EMPLEADOS').doc(dni).get();
    final nombreEmp = (empSnap.data()?['NOMBRE'] ?? '').toString().trim();
    return _DetalleData(
      actual: _buscar(periodos[0], dni),
      anterior: _buscar(periodos[1], dni),
      idActual: idActual,
      idAnterior: idAnterior,
      nombreEmpleado: nombreEmp,
    );
  }

  IcmOficialChofer? _buscar(IcmOficialPeriodo? p, String dni) {
    if (p == null || dni.isEmpty) return null;
    for (final c in p.choferes) {
      if (c.dni == dni) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_dni.isEmpty) {
      return const AppScaffold(
        title: 'Detalle ICM',
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Vení desde el ranking — el detalle requiere un chofer '
              'seleccionado.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ),
      );
    }
    return AppScaffold(
      title: 'Detalle ICM',
      body: FutureBuilder<_DetalleData>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Error: ${snap.error}',
                    style: const TextStyle(color: Colors.redAccent)),
              ),
            );
          }
          final data = snap.data!;
          final c = data.actual ?? data.anterior;
          if (c == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Text(
                  'No hay datos del ICM oficial para este chofer '
                  '(${AppFormatters.formatearDNI(_dni)}).\n\n'
                  'Puede que no haya tenido actividad registrada o que el '
                  'mes recién arranque.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, height: 1.4),
                ),
              ),
            );
          }
          final nombre = data.nombreEmpleado.isNotEmpty
              ? data.nombreEmpleado
              : (c.nombre.isNotEmpty ? c.nombre : 'DNI $_dni');
          final esActual = data.actual != null;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  nombre: nombre,
                  dni: _dni,
                  chofer: c,
                  periodoLabel: IcmOficialService.labelPeriodo(
                      esActual ? data.idActual : data.idAnterior),
                  esMesActual: esActual,
                ),
                const SizedBox(height: 16),
                _ComparativaMeses(
                  actual: data.actual,
                  anterior: data.anterior,
                  labelActual:
                      IcmOficialService.labelPeriodo(data.idActual),
                  labelAnterior:
                      IcmOficialService.labelPeriodo(data.idAnterior),
                ),
                const SizedBox(height: 16),
                const _SeccionTitulo('ICM por tipo de vía'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatCard(
                      label: 'Urbano',
                      valor: c.icmUrbano.toStringAsFixed(1),
                    ),
                    const SizedBox(width: 8),
                    _StatCard(
                      label: 'No urbano (ruta)',
                      valor: c.icmNoUrbano.toStringAsFixed(1),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const _SeccionTitulo('Recorrido del período'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatCard(
                      label: 'Distancia',
                      valor: '${AppFormatters.formatearMiles(c.distanciaKm)} km',
                    ),
                    const SizedBox(width: 8),
                    _StatCard(
                      label: 'Tiempo de manejo',
                      valor: '${c.tiempoH.toStringAsFixed(0)} h',
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const _SeccionTitulo('Infracciones'),
                const SizedBox(height: 8),
                _Infracciones(chofer: c),
                const SizedBox(height: 16),
                const _SeccionTitulo('Otros indicadores'),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _StatCard(
                      label: 'Excesos de velocidad',
                      valor: '${c.excesosVelocidad}',
                    ),
                    const SizedBox(width: 8),
                    _StatCard(
                      label: 'Conducción agresiva',
                      valor: '${c.conduccionAgresiva}',
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const _NotaFuente(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DetalleData {
  final IcmOficialChofer? actual;
  final IcmOficialChofer? anterior;
  final String idActual;
  final String idAnterior;
  final String nombreEmpleado;

  const _DetalleData({
    required this.actual,
    required this.anterior,
    required this.idActual,
    required this.idAnterior,
    required this.nombreEmpleado,
  });
}

class _Header extends StatelessWidget {
  final String nombre;
  final String dni;
  final IcmOficialChofer chofer;
  final String periodoLabel;
  final bool esMesActual;

  const _Header({
    required this.nombre,
    required this.dni,
    required this.chofer,
    required this.periodoLabel,
    required this.esMesActual,
  });

  @override
  Widget build(BuildContext context) {
    final color = colorSeveridadIcm(chofer.severidad);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                children: [
                  Text(
                    chofer.sinActividad
                        ? '—'
                        : chofer.icm.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'ICM oficial',
                    style: TextStyle(color: Colors.white70, fontSize: 9),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    nombre,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'DNI ${AppFormatters.formatearDNI(dni)}',
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${chofer.severidadLabel} · $periodoLabel'
                    '${esMesActual ? '' : ' (último con datos)'}',
                    style: TextStyle(color: color, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Comparativa del ICM del chofer entre el mes actual y el anterior.
/// MÁS BAJO = MEJOR → si bajó, mejoró (verde).
class _ComparativaMeses extends StatelessWidget {
  final IcmOficialChofer? actual;
  final IcmOficialChofer? anterior;
  final String labelActual;
  final String labelAnterior;

  const _ComparativaMeses({
    required this.actual,
    required this.anterior,
    required this.labelActual,
    required this.labelAnterior,
  });

  @override
  Widget build(BuildContext context) {
    if (actual == null || anterior == null) {
      return const SizedBox.shrink();
    }
    // ⚠ En el ICM oficial, 0 = "sin infracciones" y 0 = "sin actividad" son
    // indistinguibles numéricamente pero opuestos. Si en alguno de los dos
    // meses no hubo actividad, NO se puede calcular un delta (sino un chofer
    // que no manejó figuraría como "mejoró a 0" — plata mal asignada).
    if (actual!.sinActividad || anterior!.sinActividad) {
      return AppCard(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.info_outline, color: Colors.white38, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  actual!.sinActividad
                      ? 'Sin actividad este mes — no comparable con $labelAnterior.'
                      : 'Sin actividad en $labelAnterior — no hay base de comparación.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final a = actual!.icm;
    final b = anterior!.icm;
    final delta = a - b; // negativo = mejoró
    final mejoro = delta < 0;
    final igual = delta.abs() < 0.05;
    final color = igual
        ? Colors.white54
        : (mejoro ? Colors.greenAccent : Colors.redAccent);
    final icono = igual
        ? Icons.remove
        : (mejoro ? Icons.arrow_downward : Icons.arrow_upward);
    final txt = igual
        ? 'Sin cambios vs $labelAnterior'
        : '${mejoro ? 'Mejoró' : 'Empeoró'} '
            '${delta.abs().toStringAsFixed(1)} pts vs $labelAnterior '
            '(${b.toStringAsFixed(1)})';
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Icon(icono, color: color, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                txt,
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Infracciones extends StatelessWidget {
  final IcmOficialChofer chofer;
  const _Infracciones({required this.chofer});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _StatCard(
          label: 'Altas',
          valor: '${chofer.infAltas}',
          color: Colors.red.shade600,
        ),
        const SizedBox(width: 8),
        _StatCard(
          label: 'Medias',
          valor: '${chofer.infMedias}',
          color: Colors.amber.shade700,
        ),
        const SizedBox(width: 8),
        _StatCard(
          label: 'Leves',
          valor: '${chofer.infLeves}',
          color: Colors.green.shade600,
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String valor;
  final Color? color;

  const _StatCard({required this.label, required this.valor, this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style:
                      const TextStyle(color: Colors.white54, fontSize: 10),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  valor,
                  style: TextStyle(
                    color: color ?? Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeccionTitulo extends StatelessWidget {
  final String texto;
  const _SeccionTitulo(this.texto);

  @override
  Widget build(BuildContext context) {
    return Text(
      texto,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.3,
      ),
    );
  }
}

class _NotaFuente extends StatelessWidget {
  const _NotaFuente();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Fuente: tablero ICM oficial de Sitrack (lo que audita YPF). '
      'Escala más baja = mejor. Se actualiza una vez al día.',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.35),
        fontSize: 11,
        fontStyle: FontStyle.italic,
        height: 1.3,
      ),
    );
  }
}
