import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/jornada_dia.dart';
import '../services/jornada_historico_service.dart';

/// Pantalla "Jornada del día" — muestra la jornada reconstruida de un
/// chofer en una fecha específica:
///
///   - Resumen del día (inicio, fin, manejo neto, paradas, km, vel máx).
///   - Gráfico de velocidad vs tiempo (LineChart).
///   - Lista de tramos de manejo (cuando arrancó, cuando paró, duración,
///     km, velocidad máx y promedio).
///   - Lista de paradas entre tramos (duración + clasificación según
///     política Vecchi v2: ≥15 min cumple corte de bloque, ≥8h cumple
///     descanso entre jornadas).
///
/// Lee de `VOLVO_JORNADAS_HISTORICO` (la CF `reconstruirJornadasDiario`
/// la pobla todas las mañanas a las 06:30 ART procesando el día anterior).
///
/// Entry point: tile "JORNADA" del hub ICM. Se entra sin args (selectores
/// vacíos) — el operador elige chofer + fecha. Si se navega con args
/// `{choferDni, fecha}`, viene pre-cargado (futuro: tap desde detalle
/// chofer ICM).
class JornadaDiaScreen extends StatefulWidget {
  final String? choferDniInicial;
  final DateTime? fechaInicial;

  const JornadaDiaScreen({
    super.key,
    this.choferDniInicial,
    this.fechaInicial,
  });

  @override
  State<JornadaDiaScreen> createState() => _JornadaDiaScreenState();
}

class _JornadaDiaScreenState extends State<JornadaDiaScreen> {
  String? _choferDni;
  String? _choferNombre;
  // Rango de fechas (puede ser 1 solo día → desde == hasta). Si el usuario
  // elige más de un día, mostramos lista de cards resumen; tap sobre una
  // expande el detalle del día.
  late DateTime _desde;
  late DateTime _hasta;

  // Cache de choferes (EMPLEADOS con rol CHOFER) para el dropdown.
  List<_ChoferOpt> _choferes = const [];
  bool _cargandoChoferes = true;

  @override
  void initState() {
    super.initState();
    _choferDni = widget.choferDniInicial;
    final ayer = DateTime.now().subtract(const Duration(days: 1));
    final inicial =
        widget.fechaInicial ?? DateTime(ayer.year, ayer.month, ayer.day);
    _desde = inicial;
    _hasta = inicial;
    _cargarChoferes();
  }

  bool get _esUnSoloDia =>
      _desde.year == _hasta.year &&
      _desde.month == _hasta.month &&
      _desde.day == _hasta.day;

  Future<void> _cargarChoferes() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .where('ROL', whereIn: const ['CHOFER', 'USUARIO'])
          .get();
      final lista = snap.docs.map((d) {
        final m = d.data();
        return _ChoferOpt(
          dni: d.id,
          nombre: (m['NOMBRE'] as String?)?.trim() ?? d.id,
          activo: m['ACTIVO'] != false,
        );
      }).where((c) => c.activo).toList()
        ..sort((a, b) => a.nombre.compareTo(b.nombre));
      if (!mounted) return;
      setState(() {
        _choferes = lista;
        _cargandoChoferes = false;
        // Si vino preseleccionado, completar el nombre
        if (_choferDni != null) {
          final hit = lista.firstWhere(
            (c) => c.dni == _choferDni,
            orElse: () => _ChoferOpt(dni: _choferDni!, nombre: _choferDni!, activo: true),
          );
          _choferNombre = hit.nombre;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cargandoChoferes = false);
    }
  }

  Future<void> _elegirRango() async {
    final hoy = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
      firstDate: hoy.subtract(const Duration(days: 365)),
      lastDate: hoy,
      locale: const Locale('es', 'AR'),
      helpText: 'Días de jornada',
      saveText: 'Aplicar',
    );
    if (r == null) return;
    setState(() {
      _desde = DateTime(r.start.year, r.start.month, r.start.day);
      _hasta = DateTime(r.end.year, r.end.month, r.end.day);
    });
  }

  Future<void> _elegirChofer() async {
    if (_cargandoChoferes) return;
    final ctrl = TextEditingController();
    final elegido = await showModalBottomSheet<_ChoferOpt>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: StatefulBuilder(builder: (ctx, setStateSheet) {
              final q = ctrl.text.trim().toUpperCase();
              final filtrados = q.isEmpty
                  ? _choferes
                  : _choferes
                      .where((c) =>
                          c.nombre.toUpperCase().contains(q) ||
                          c.dni.contains(q))
                      .toList();
              return SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('Elegir chofer',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        )),
                    const SizedBox(height: 10),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      style: const TextStyle(color: Colors.white),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        labelText: 'Buscar por nombre o DNI',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => setStateSheet(() {}),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtrados.length,
                        itemBuilder: (ctx, i) {
                          final c = filtrados[i];
                          return ListTile(
                            title: Text(c.nombre,
                                style: const TextStyle(color: Colors.white)),
                            subtitle: Text('DNI ${c.dni}',
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 12)),
                            onTap: () => Navigator.pop(ctx, c),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              );
            }),
          ),
        );
      },
    );
    if (elegido == null) return;
    setState(() {
      _choferDni = elegido.dni;
      _choferNombre = elegido.nombre;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Jornada',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Selectores(
            choferLabel: _choferNombre ?? 'Elegir chofer…',
            rangoLabel: _esUnSoloDia
                ? _fmtFecha(_desde)
                : '${_fmtFecha(_desde)} → ${_fmtFecha(_hasta)}',
            cargandoChoferes: _cargandoChoferes,
            onChofer: _elegirChofer,
            onRango: _elegirRango,
          ),
          Expanded(
            child: _choferDni == null
                ? const _Placeholder(
                    icono: Icons.person_search,
                    titulo: 'Elegí un chofer para ver su jornada',
                    subtitulo: 'Tocá "Elegir chofer" arriba.',
                  )
                : (_esUnSoloDia
                    ? _DetalleUnDia(
                        choferDni: _choferDni!, fecha: _desde)
                    : _ListaRango(
                        choferDni: _choferDni!,
                        desde: _desde,
                        hasta: _hasta,
                      )),
          ),
        ],
      ),
    );
  }
}

/// Stream de UN solo día — detalle completo (resumen + gráfico + tramos
/// + paradas) usando los widgets viejos.
class _DetalleUnDia extends StatelessWidget {
  final String choferDni;
  final DateTime fecha;
  const _DetalleUnDia({required this.choferDni, required this.fecha});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<JornadaDia?>(
      stream: JornadaHistoricoService.streamDia(
          choferDni: choferDni, fecha: fecha),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(
                  color: AppColors.success));
        }
        if (snap.hasError) {
          return _Placeholder(
            icono: Icons.error_outline,
            titulo: 'Error al cargar la jornada',
            subtitulo: snap.error.toString(),
          );
        }
        final j = snap.data;
        if (j == null) {
          return const _Placeholder(
            icono: Icons.event_busy,
            titulo: 'Sin jornada procesada',
            subtitulo:
                'Este chofer no manejó ese día, o el día todavía no se '
                'procesó (el cron corre a las 06:30 ART procesando el día '
                'anterior).',
          );
        }
        return _Contenido(jornada: j);
      },
    );
  }
}

/// Stream de varios días — lista de cards resumen ordenadas
/// cronológicamente. Tap sobre una card abre el detalle del día puntual
/// (reusa la misma pantalla con fecha igual a desde y hasta).
class _ListaRango extends StatelessWidget {
  final String choferDni;
  final DateTime desde;
  final DateTime hasta;
  const _ListaRango(
      {required this.choferDni,
      required this.desde,
      required this.hasta});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<JornadaDia>>(
      stream: JornadaHistoricoService.streamPorRango(
          choferDni: choferDni, desde: desde, hasta: hasta),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: CircularProgressIndicator(
                  color: AppColors.success));
        }
        if (snap.hasError) {
          return _Placeholder(
            icono: Icons.error_outline,
            titulo: 'Error al cargar las jornadas del rango',
            subtitulo: snap.error.toString(),
          );
        }
        final jornadas = snap.data ?? const [];
        if (jornadas.isEmpty) {
          return const _Placeholder(
            icono: Icons.event_busy,
            titulo: 'Sin jornadas en el rango',
            subtitulo:
                'No hay jornadas procesadas para este chofer entre las fechas '
                'elegidas (o no manejó esos días).',
          );
        }
        // Suma agregada para que el operador vea totales del rango.
        final totalKm = jornadas.fold<int>(0, (s, j) => s + j.kmTotal);
        final totalManejo =
            jornadas.fold<int>(0, (s, j) => s + j.manejoMin);
        return ListView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
              child: Text(
                '${jornadas.length} jornada${jornadas.length == 1 ? "" : "s"} · '
                'total ${_fmtHM(totalManejo)} manejo · '
                '${totalKm.toString()} km',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            for (final j in jornadas) _CardResumenDia(jornada: j),
          ],
        );
      },
    );
  }
}

/// Card compacta con resumen de UN día dentro de una lista de rango.
/// Tap → abre la misma pantalla con ese día puntual (vista detalle).
class _CardResumenDia extends StatelessWidget {
  final JornadaDia jornada;
  const _CardResumenDia({required this.jornada});

  @override
  Widget build(BuildContext context) {
    // Convertimos 'YYYY-MM-DD' del doc a un DateTime ART (sin tiempo).
    final partes = jornada.fecha.split('-');
    final fecha = partes.length == 3
        ? DateTime(
            int.tryParse(partes[0]) ?? 0,
            int.tryParse(partes[1]) ?? 1,
            int.tryParse(partes[2]) ?? 1,
          )
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AppCard(
        padding: const EdgeInsets.all(14),
        onTap: fecha == null
            ? null
            : () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => JornadaDiaScreen(
                      choferDniInicial: jornada.choferDni,
                      fechaInicial: fecha,
                    ),
                  ),
                );
              },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.calendar_today,
                    color: AppColors.success, size: 16),
                const SizedBox(width: 8),
                Text(
                  jornada.fecha,
                  style: const TextStyle(
                    color: AppColors.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  jornada.patentePrincipal,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_forward_ios,
                    color: Colors.white24, size: 12),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                _MiniKpi(
                  label: 'INICIO',
                  valor: _fmtHoraCorta(jornada.inicio),
                  color: AppColors.accentTeal,
                  icono: Icons.play_arrow,
                ),
                const SizedBox(width: 18),
                _MiniKpi(
                  label: 'FIN',
                  valor: _fmtHoraCorta(jornada.fin),
                  color: AppColors.accentTeal,
                  icono: Icons.stop,
                ),
                const SizedBox(width: 18),
                _MiniKpi(
                  label: 'MANEJO',
                  valor: _fmtHM(jornada.manejoMin),
                  color: AppColors.accentBlue,
                  icono: Icons.directions_car,
                ),
                const SizedBox(width: 18),
                _MiniKpi(
                  label: 'KM',
                  valor: jornada.kmTotal.toString(),
                  color: AppColors.success,
                  icono: Icons.route,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniKpi extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;
  final IconData icono;
  const _MiniKpi({
    required this.label,
    required this.valor,
    required this.color,
    required this.icono,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono, color: color, size: 14),
        const SizedBox(width: 4),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                )),
            Text(valor,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                )),
          ],
        ),
      ],
    );
  }
}

class _ChoferOpt {
  final String dni;
  final String nombre;
  final bool activo;
  const _ChoferOpt(
      {required this.dni, required this.nombre, required this.activo});
}

class _Selectores extends StatelessWidget {
  final String choferLabel;
  final String rangoLabel;
  final bool cargandoChoferes;
  final VoidCallback onChofer;
  final VoidCallback onRango;

  const _Selectores({
    required this.choferLabel,
    required this.rangoLabel,
    required this.cargandoChoferes,
    required this.onChofer,
    required this.onRango,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: _PillButton(
              icono: cargandoChoferes
                  ? Icons.hourglass_empty
                  : Icons.person_outline,
              label: choferLabel,
              color: AppColors.accentBlue,
              onTap: cargandoChoferes ? null : onChofer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _PillButton(
              icono: Icons.date_range,
              label: rangoLabel,
              color: AppColors.accentTeal,
              onTap: onRango,
            ),
          ),
        ],
      ),
    );
  }
}

class _PillButton extends StatelessWidget {
  final IconData icono;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _PillButton(
      {required this.icono,
      required this.label,
      required this.color,
      this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(icono, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String subtitulo;
  const _Placeholder(
      {required this.icono,
      required this.titulo,
      required this.subtitulo});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, color: Colors.white38, size: 48),
            const SizedBox(height: 12),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14),
            ),
            const SizedBox(height: 8),
            Text(
              subtitulo,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Contenido extends StatelessWidget {
  final JornadaDia jornada;
  const _Contenido({required this.jornada});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        _ResumenCard(j: jornada),
        const SizedBox(height: 12),
        _GraficoVelocidad(j: jornada),
        const SizedBox(height: 16),
        _SeccionLabel(
          icono: Icons.timeline,
          texto: 'TRAMOS DE MANEJO (${jornada.tramos.length})',
        ),
        const SizedBox(height: 8),
        for (final t in jornada.tramos) _TramoCard(t: t),
        const SizedBox(height: 16),
        _SeccionLabel(
          icono: Icons.local_parking,
          texto: 'PARADAS (${jornada.paradas.length})',
        ),
        const SizedBox(height: 8),
        if (jornada.paradas.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Sin paradas detectadas entre tramos.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
        for (final p in jornada.paradas) _ParadaCard(p: p),
      ],
    );
  }
}

class _ResumenCard extends StatelessWidget {
  final JornadaDia j;
  const _ResumenCard({required this.j});

  @override
  Widget build(BuildContext context) {
    final patentes = j.patentes.length > 1
        ? '${j.patentePrincipal} (+${j.patentes.length - 1})'
        : j.patentePrincipal;
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping_outlined,
                  color: AppColors.success, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  patentes,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16),
                ),
              ),
              Text(
                '${_fmtHoraCorta(j.inicio)} → ${_fmtHoraCorta(j.fin)}',
                style:
                    const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              _Kpi(
                  label: 'MANEJO',
                  valor: _fmtHM(j.manejoMin),
                  icono: Icons.directions_car,
                  color: AppColors.accentBlue),
              _Kpi(
                  label: 'PARADAS',
                  valor: _fmtHM(j.paradasMin),
                  icono: Icons.local_parking,
                  color: AppColors.warning),
              _Kpi(
                  label: 'KM',
                  valor: j.kmTotal.toString(),
                  icono: Icons.route,
                  color: AppColors.accentTeal),
              _Kpi(
                  label: 'VEL MÁX',
                  valor: '${j.velocidadMax} km/h',
                  icono: Icons.speed,
                  color: AppColors.error),
            ],
          ),
        ],
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String valor;
  final IconData icono;
  final Color color;
  const _Kpi(
      {required this.label,
      required this.valor,
      required this.icono,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icono, color: color, size: 18),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            Text(valor,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ],
    );
  }
}

class _GraficoVelocidad extends StatelessWidget {
  final JornadaDia j;
  const _GraficoVelocidad({required this.j});

  @override
  Widget build(BuildContext context) {
    if (j.serieVelocidad.length < 2) {
      return const AppCard(
        padding: EdgeInsets.all(16),
        child: Center(
          child: Text(
            'Sin serie de velocidad suficiente para graficar.',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      );
    }

    final minTs = j.serieVelocidad.first.tsMs.toDouble();
    final maxTs = j.serieVelocidad.last.tsMs.toDouble();
    final spots = j.serieVelocidad
        .map((p) => FlSpot(p.tsMs.toDouble(), p.speed.toDouble()))
        .toList();
    final velMax = j.velocidadMax.toDouble();
    final maxY = (velMax <= 0 ? 100.0 : (velMax + 10).ceilToDouble());
    final intervaloX = (maxTs - minTs) / 5;

    return AppCard(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.speed,
                  color: AppColors.accentTeal, size: 18),
              SizedBox(width: 8),
              Text('Velocidad (km/h)',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: LineChart(
              LineChartData(
                minX: minTs,
                maxX: maxTs,
                minY: 0,
                maxY: maxY,
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 25,
                  getDrawingHorizontalLine: (v) => FlLine(
                    color: Colors.white.withValues(alpha: 0.05),
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
                      interval: 25,
                      reservedSize: 30,
                      getTitlesWidget: (v, m) => Text(v.toInt().toString(),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 10)),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: intervaloX,
                      reservedSize: 22,
                      getTitlesWidget: (v, m) {
                        final d =
                            DateTime.fromMillisecondsSinceEpoch(v.toInt());
                        return Text(_fmtHoraCorta(d),
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 10));
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: false,
                    color: AppColors.accentTeal,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: AppColors.accentTeal.withValues(alpha: 0.15),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TramoCard extends StatelessWidget {
  final TramoManejo t;
  const _TramoCard({required this.t});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.accentBlue.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_car,
              color: AppColors.accentBlue, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_fmtHoraCorta(t.desde)} → ${_fmtHoraCorta(t.hasta)}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtHM(t.duracionMin)} · '
                  '${t.kmAprox > 0 ? "${t.kmAprox} km · " : ""}'
                  'máx ${t.velocidadMax} · prom ${t.velocidadProm} km/h',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ParadaCard extends StatelessWidget {
  final Parada p;
  const _ParadaCard({required this.p});

  @override
  Widget build(BuildContext context) {
    final color =
        p.cumple8h ? AppColors.success :
        p.cumple15min ? AppColors.accentTeal :
        AppColors.warning;
    final hint = p.cumple8h
        ? '✓ Descanso entre jornadas (≥ 8h)'
        : p.cumple15min
            ? '✓ Corte de bloque suficiente (≥ 15 min)'
            : 'Insuficiente para cortar bloque (< 15 min)';
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(Icons.local_parking, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      '${_fmtHoraCorta(p.desde)} → ${_fmtHoraCorta(p.hasta)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        p.etiqueta,
                        style: TextStyle(
                            color: color,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${_fmtHM(p.duracionMin)} · $hint',
                  style: const TextStyle(color: Colors.white60, fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SeccionLabel extends StatelessWidget {
  final IconData icono;
  final String texto;
  const _SeccionLabel({required this.icono, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: Row(
        children: [
          Icon(icono, color: AppColors.success, size: 14),
          const SizedBox(width: 6),
          Text(
            texto,
            style: const TextStyle(
                color: AppColors.success,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }
}

String _fmtFecha(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

String _fmtHoraCorta(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

String _fmtHM(int min) {
  if (min < 60) return '${min}m';
  final h = min ~/ 60;
  final m = min % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
