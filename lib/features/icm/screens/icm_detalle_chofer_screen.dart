import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';
import '../services/sitrack_eventos_service.dart';

/// Detalle ICM individual de un chofer, con el número **oficial de Sitrack**
/// (lo que audita YPF, MÁS BAJO = MEJOR):
///   - Header: nombre + DNI + ICM del mes + severidad.
///   - Comparativa con el mes anterior (¿mejoró o empeoró?).
///   - ICM urbano vs no-urbano (dónde maneja peor).
///   - Desglose de infracciones (altas / medias / leves) + excesos de
///     velocidad + conducción agresiva.
///   - **Detalle de eventos** (desde SITRACK_EVENTOS): qué tipo, cuándo,
///     dónde, a qué velocidad y con qué límite. Para que el operador
///     entienda QUÉ disparó los counters de infracciones.
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
    // Eventos individuales del período actual desde SITRACK_EVENTOS.
    // Si el actual está vacío, caemos al anterior para no mostrar lista
    // vacía si el chofer no manejó este mes (mismo patrón de fallback
    // que la tendencia ICM en el hub).
    final periodoConDatos =
        periodos[0] != null && !periodos[0]!.vacio ? periodos[0] : periodos[1];
    List<SitrackEventoChofer> eventos = const [];
    if (periodoConDatos != null) {
      final desde = DateTime.tryParse(periodoConDatos.fechaDesde);
      final hastaBase = DateTime.tryParse(periodoConDatos.fechaHasta);
      // El doc oficial trae `fecha_hasta` como YYYY-MM-DD (00:00 ART).
      // Sumamos casi un día para incluir TODOS los eventos de la fecha hasta.
      final hasta = hastaBase?.add(
          const Duration(hours: 23, minutes: 59, seconds: 59));
      if (desde != null && hasta != null) {
        eventos = await SitrackEventosService.cargarEventosChofer(
          db: db,
          dni: dni,
          desde: desde,
          hasta: hasta,
        );
      }
    }
    return _DetalleData(
      actual: _buscar(periodos[0], dni),
      anterior: _buscar(periodos[1], dni),
      idActual: idActual,
      idAnterior: idAnterior,
      nombreEmpleado: nombreEmp,
      eventos: eventos,
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
                const SizedBox(height: 18),
                const _SeccionTitulo('Detalle de eventos'),
                const SizedBox(height: 8),
                _ListaEventos(eventos: data.eventos),
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
  final List<SitrackEventoChofer> eventos;

  const _DetalleData({
    required this.actual,
    required this.anterior,
    required this.idActual,
    required this.idAnterior,
    required this.nombreEmpleado,
    this.eventos = const [],
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

/// Lista de eventos individuales del período (desde SITRACK_EVENTOS).
/// Stateful porque mantiene el filtro por tipo seleccionado.
class _ListaEventos extends StatefulWidget {
  final List<SitrackEventoChofer> eventos;
  const _ListaEventos({required this.eventos});

  @override
  State<_ListaEventos> createState() => _ListaEventosState();
}

class _ListaEventosState extends State<_ListaEventos> {
  /// `null` = "todos". Si está seteado, filtra por `event_name`.
  String? _filtroTipo;

  /// Máximo a mostrar de entrada — la mayoría de los choferes
  /// tienen >100 eventos por mes, lista gigante ahoga al operador.
  /// El botón "Mostrar más" levanta el tope.
  int _maxVisibles = 30;

  @override
  Widget build(BuildContext context) {
    final eventos = widget.eventos;
    if (eventos.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: Text(
            'Sin eventos individuales para este período.\n'
            'Si el chofer manejó, puede que Sitrack todavía no haya enviado '
            'los detalles (se sincroniza cada 5 min).',
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

    // Cuento por tipo para los chips de filtro (top 8 más frecuentes).
    final conteoPorTipo = <String, int>{};
    for (final e in eventos) {
      conteoPorTipo[e.eventName] = (conteoPorTipo[e.eventName] ?? 0) + 1;
    }
    final tiposFrecuentes = conteoPorTipo.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final filtrados = _filtroTipo == null
        ? eventos
        : eventos.where((e) => e.eventName == _filtroTipo).toList();
    final visibles = filtrados.take(_maxVisibles).toList();
    final hayMas = filtrados.length > visibles.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Resumen + chips
        Text(
          '${eventos.length} evento${eventos.length == 1 ? "" : "s"} '
          'en el período',
          style: const TextStyle(color: Colors.white60, fontSize: 11),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _ChipFiltro(
                label: 'Todos (${eventos.length})',
                selected: _filtroTipo == null,
                onTap: () => setState(() {
                  _filtroTipo = null;
                  _maxVisibles = 30;
                }),
              ),
              for (final t in tiposFrecuentes.take(8))
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
        // Lista
        ...visibles.map((e) => _EventoCard(evento: e)),
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
        if (eventos.length >= 500) ...[
          const SizedBox(height: 6),
          Text(
            'Mostrando los 500 eventos más recientes del período.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
              fontStyle: FontStyle.italic,
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

/// Card compacta de un evento: tipo + timestamp ART + ubicación +
/// velocidad si aplica. Si fue exceso cartográfico, fondo rojo claro.
class _EventoCard extends StatelessWidget {
  final SitrackEventoChofer evento;
  const _EventoCard({required this.evento});

  @override
  Widget build(BuildContext context) {
    final exceso = evento.esExcesoCartografico;
    final tieneVel = evento.speed != null;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 3),
      color: exceso
          ? Colors.red.shade900.withValues(alpha: 0.18)
          : Colors.white.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: BorderSide(
          color: exceso
              ? Colors.redAccent.withValues(alpha: 0.5)
              : Colors.white12,
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    evento.eventName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: exceso ? Colors.redAccent : Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  AppFormatters.formatearFechaHoraSinSegundos(
                      evento.reportDate),
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
            if ((evento.location ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.place,
                      size: 12, color: Colors.white38),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      evento.location!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (tieneVel || evento.assetName != null) ...[
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                runSpacing: 2,
                children: [
                  if (tieneVel)
                    Text(
                      evento.cartographyLimitSpeed != null
                          ? '${evento.speed!.toStringAsFixed(0)} km/h '
                              '· límite ${evento.cartographyLimitSpeed!.toStringAsFixed(0)} km/h'
                          : '${evento.speed!.toStringAsFixed(0)} km/h',
                      style: TextStyle(
                        color: exceso ? Colors.redAccent : Colors.white60,
                        fontSize: 11,
                        fontWeight: exceso ? FontWeight.w600 : null,
                      ),
                    ),
                  if ((evento.assetName ?? '').isNotEmpty)
                    Text(
                      'Unidad: ${evento.assetName}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
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
