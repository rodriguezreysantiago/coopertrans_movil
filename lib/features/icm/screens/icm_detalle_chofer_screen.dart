import 'package:coopertrans_movil/shared/constants/app_colors.dart';
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
///   - **Detalle de infracciones** (desde `chofer.infracciones`, que el
///     scraper trae con `get_infractions(scopeId)` de Sitrack): tabla
///     con las MISMAS columnas que muestra el modal de Sitrack
///     (vehículo + tipo + fecha + ubicación + vel.permitida + pico +
///     tiempo + puntaje).
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
                    style: const TextStyle(color: AppColors.error)),
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
                const SizedBox(height: 18),
                const _SeccionTitulo('Detalle de infracciones'),
                const SizedBox(height: 8),
                _ListaInfracciones(infracciones: c.infracciones),
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
        : (mejoro ? AppColors.success : AppColors.error);
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

/// Lista de infracciones individuales del chofer en el período (de
/// `chofer.infracciones`, embebido en el doc del período por el scraper
/// Python que llama get_infractions(scopeId) de Sitrack). Muestra las
/// MISMAS columnas que el modal de Sitrack — el operador ve lo mismo
/// en la app que en el portal.
///
/// Stateful porque mantiene chips de filtro por tipo de infracción
/// (top 6 más frecuentes) y paginación local (de a 30 con "Mostrar más").
class _ListaInfracciones extends StatefulWidget {
  final List<InfraccionIndividual> infracciones;
  const _ListaInfracciones({required this.infracciones});

  @override
  State<_ListaInfracciones> createState() => _ListaInfraccionesState();
}

class _ListaInfraccionesState extends State<_ListaInfracciones> {
  String? _filtroTipo;
  int _maxVisibles = 30;

  @override
  Widget build(BuildContext context) {
    final lista = widget.infracciones;
    if (lista.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'Sin infracciones individuales para este período.\n'
            'El detalle se sincroniza desde Sitrack una vez al día.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
      );
    }

    // Top tipos por cantidad
    final conteoPorTipo = <String, int>{};
    for (final i in lista) {
      conteoPorTipo[i.infraccion] = (conteoPorTipo[i.infraccion] ?? 0) + 1;
    }
    final tiposFrecuentes = conteoPorTipo.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final filtrados = _filtroTipo == null
        ? lista
        : lista.where((i) => i.infraccion == _filtroTipo).toList();
    final visibles = filtrados.take(_maxVisibles).toList();
    final hayMas = filtrados.length > visibles.length;
    final sumaPuntaje = lista.fold<double>(0, (a, b) => a + b.puntaje);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${lista.length} infracción${lista.length == 1 ? "" : "es"} · '
          'Suma de puntaje: ${sumaPuntaje.toStringAsFixed(2)}',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _ChipFiltro(
                label: 'Todas (${lista.length})',
                selected: _filtroTipo == null,
                onTap: () => setState(() {
                  _filtroTipo = null;
                  _maxVisibles = 30;
                }),
              ),
              for (final t in tiposFrecuentes.take(6))
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _ChipFiltro(
                    label: '${t.key} (${t.value})',
                    selected: _filtroTipo == t.key,
                    onTap: () => setState(() {
                      _filtroTipo = t.key;
                      _maxVisibles = 30;
                    }),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        ...visibles.map((i) => _InfraccionCard(infraccion: i)),
        if (hayMas) ...[
          const SizedBox(height: 8),
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() => _maxVisibles += 50),
              icon: const Icon(Icons.expand_more, size: 18),
              label: Text('Mostrar más '
                  '(${filtrados.length - visibles.length} restantes)'),
            ),
          ),
        ],
      ],
    );
  }
}

class _ChipFiltro extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChipFiltro({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: selected ? Colors.black : Colors.white70,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Card de una infracción individual. Mismas columnas que la tabla del
/// modal de Sitrack: tipo + fecha + ubicación + vel.permitida + pico de
/// velocidad + tiempo (si aplica) + puntaje. Color rojo si es exceso real.
class _InfraccionCard extends StatelessWidget {
  final InfraccionIndividual infraccion;
  const _InfraccionCard({required this.infraccion});

  Color _colorPuntaje() {
    if (infraccion.puntaje >= 10) return Colors.red.shade600;
    if (infraccion.puntaje >= 5) return Colors.amber.shade700;
    return Colors.green.shade600;
  }

  @override
  Widget build(BuildContext context) {
    final i = infraccion;
    final color = _colorPuntaje();
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: Colors.white.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila 1: tipo + puntaje
            Row(
              children: [
                Expanded(
                  child: Text(
                    i.infraccion,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: color.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    i.puntaje.toStringAsFixed(2),
                    style: TextStyle(
                      color: color,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // Fila 2: fecha + patente
            Row(
              children: [
                const Icon(Icons.access_time,
                    size: 12, color: Colors.white38),
                const SizedBox(width: 4),
                Text(
                  i.fecha,
                  style: const TextStyle(
                      color: Colors.white60, fontSize: 11),
                ),
                if (i.patente.isNotEmpty) ...[
                  const SizedBox(width: 14),
                  const Icon(Icons.local_shipping,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 4),
                  Text(
                    i.patente,
                    style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                ],
                if (i.tiempo != null) ...[
                  const SizedBox(width: 14),
                  const Icon(Icons.timer,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 4),
                  Text(
                    i.tiempo!,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 11),
                  ),
                ],
              ],
            ),
            // Fila 3: ubicación
            if (i.ubicacion.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.place,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      i.ubicacion,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
            // Fila 4: velocidades (sólo si están)
            if (i.velMaxima != null || i.velLimite != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.speed,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 4),
                  Text(
                    i.velLimite != null && i.velMaxima != null
                        ? 'Pico ${i.velMaxima!.toStringAsFixed(0)} km/h '
                            '· límite ${i.velLimite!.toStringAsFixed(0)} km/h'
                        : i.velMaxima != null
                            ? 'Pico ${i.velMaxima!.toStringAsFixed(0)} km/h'
                            : 'Límite ${i.velLimite!.toStringAsFixed(0)} km/h',
                    style: TextStyle(
                      color: i.esExcesoVelocidad
                          ? AppColors.error
                          : Colors.white60,
                      fontSize: 11,
                      fontWeight: i.esExcesoVelocidad
                          ? FontWeight.w600
                          : null,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
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
      'Escala más baja = mejor. Se actualiza una vez al día. '
      'El detalle de eventos viene del stream /files/reports de Sitrack '
      '(actualizado cada 5 min).',
      style: TextStyle(
        color: Colors.white.withValues(alpha: 0.35),
        fontSize: 11,
        fontStyle: FontStyle.italic,
        height: 1.3,
      ),
    );
  }
}
