import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/jornada_dia.dart';
import '../services/jornada_historico_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
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
                    Text('Elegir chofer',
                        style: AppType.heading.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
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
                                style: AppType.label.copyWith(color: Colors.white60)),
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
///
/// Caso HOY: el cron `reconstruirJornadasDiario` corre a las 06:30 ART
/// procesando AYER, así que HOY no existe en `VOLVO_JORNADAS_HISTORICO`
/// hasta mañana. Para no quedar ciegos en el día, exponemos un botón
/// "Cargar jornada de hoy" que invoca la callable `procesarJornadaHoyChofer`
/// — procesa los eventos parciales (hoy 00:00 ART → ahora) y persiste
/// al mismo doc, por lo que el StreamBuilder se actualiza solo al
/// terminar. Si el doc ya existe (porque el admin ya lo cargó antes
/// hoy o estamos viendo ayer), aparece un FAB para "Actualizar".
class _DetalleUnDia extends StatefulWidget {
  final String choferDni;
  final DateTime fecha;
  const _DetalleUnDia({required this.choferDni, required this.fecha});

  @override
  State<_DetalleUnDia> createState() => _DetalleUnDiaState();
}

class _DetalleUnDiaState extends State<_DetalleUnDia> {
  bool _procesando = false;

  bool get _esHoy {
    final h = DateTime.now();
    return widget.fecha.year == h.year &&
        widget.fecha.month == h.month &&
        widget.fecha.day == h.day;
  }

  /// Invoca la callable `procesarJornadaHoyChofer` por HTTPS directo
  /// (no usamos `cloud_functions` plugin porque no tiene impl Windows
  /// — mismo patrón que `loginConDni` y `actualizarRolEmpleado`).
  ///
  /// La callable está en us-central1. Auth con Bearer del idToken del
  /// usuario logueado (el server chequea rol ADMIN/SUPERVISOR).
  Future<void> _procesarHoy() async {
    if (!mounted) return;
    setState(() => _procesando = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        throw StateError('Sin sesión activa.');
      }
      final idToken = await user.getIdToken();
      if (idToken == null || idToken.isEmpty) {
        throw StateError('No se pudo obtener el token de sesión.');
      }
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 120),
      ));
      const url =
          'https://us-central1-coopertrans-movil.cloudfunctions.net/'
          'procesarJornadaHoyChofer';
      final response = await dio.post<Map<String, dynamic>>(
        url,
        // Protocolo callable: payload va envuelto en `data`.
        data: {
          'data': {'choferDni': widget.choferDni},
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
      if (response.statusCode == null || response.statusCode! >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        final message = (err?['message'] ?? '').toString();
        throw Exception(
            message.isNotEmpty ? message : 'HTTP ${response.statusCode}');
      }
      final result = response.data?['result'] as Map<String, dynamic>?;
      final persistida = result?['jornada_persistida'] == true;
      final eventos = result?['eventos'] ?? 0;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(persistida
            ? 'Jornada de hoy actualizada ($eventos eventos).'
            : 'Sin actividad del chofer hoy todavía.'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('No se pudo procesar la jornada: $e'),
      ));
    } finally {
      if (mounted) setState(() => _procesando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<JornadaDia?>(
      stream: JornadaHistoricoService.streamDia(
          choferDni: widget.choferDni, fecha: widget.fecha),
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
          // Placeholder con CTA específico cuando es HOY — sino el
          // usuario no tendría forma de pedir el procesamiento parcial.
          return _PlaceholderConAccion(
            icono: Icons.event_busy,
            titulo: _esHoy
                ? 'Jornada de hoy no procesada todavía'
                : 'Sin jornada procesada',
            subtitulo: _esHoy
                ? 'El cron procesa los días completos a las 06:30 ART. '
                    'Tocá "Cargar jornada de hoy" para reconstruir lo que '
                    'lleva el día hasta ahora.'
                : 'Este chofer no manejó ese día.',
            accion: _esHoy
                ? _AccionPlaceholder(
                    label: 'Cargar jornada de hoy',
                    icono: Icons.refresh,
                    onTap: _procesarHoy,
                    cargando: _procesando,
                  )
                : null,
          );
        }
        // Hay jornada — si es HOY, dejamos un FAB para refrescar.
        return Stack(
          children: [
            _Contenido(jornada: j),
            if (_esHoy)
              Positioned(
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: FloatingActionButton.extended(
                  heroTag: 'jornada_hoy_refrescar',
                  backgroundColor: AppColors.success,
                  foregroundColor: Colors.white,
                  onPressed: _procesando ? null : _procesarHoy,
                  icon: _procesando
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 18),
                  label: Text(_procesando ? 'Actualizando…' : 'Actualizar'),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Placeholder con un botón de acción opcional. Variante del `_Placeholder`
/// original que solo mostraba texto — necesario para el CTA "Cargar
/// jornada de hoy" cuando no hay doc todavía.
class _PlaceholderConAccion extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String subtitulo;
  final _AccionPlaceholder? accion;

  const _PlaceholderConAccion({
    required this.icono,
    required this.titulo,
    required this.subtitulo,
    this.accion,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, color: Colors.white38, size: 48),
            const SizedBox(height: AppSpacing.md),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: AppType.body.copyWith(
                  color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitulo,
              textAlign: TextAlign.center,
              style: AppType.label.copyWith(color: Colors.white54),
            ),
            if (accion != null) ...[
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: accion!.cargando ? 'Procesando…' : accion!.label,
                icon: accion!.icono,
                isLoading: accion!.cargando,
                onPressed: accion!.cargando ? null : accion!.onTap,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _AccionPlaceholder {
  final String label;
  final IconData icono;
  final VoidCallback onTap;
  final bool cargando;
  const _AccionPlaceholder({
    required this.label,
    required this.icono,
    required this.onTap,
    required this.cargando,
  });
}

/// Stream de varios días — los **combina en una sola jornada continua**
/// (gráfico extendido N×24h, tramos en orden cronológico, paradas
/// combinadas, KPIs sumados). Decisión 2026-05-28: el operador querio
/// ver el patrón continuo del rango sin ver cards separadas — mejor
/// para detectar tendencias multi-día (ej. jornadas largas seguidas
/// que el descanso entre ellas no compensa).
///
/// La fusión es client-side y barata (pocos KB por día). Si el rango
/// es muy grande (ej. 30 días) y la lista de paradas crece, igual
/// renderea bien — `ListView` interno de `_Contenido` virtualiza.
///
/// Si una fecha del rango NO tiene jornada (chofer no manejó), se
/// skipea silenciosamente — el rango muestra solo los días que tuvieron
/// actividad. Por eso el header dice "X días con jornada" (no
/// "X días en el rango").
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
        final combinada = _combinarJornadas(jornadas);
        return _Contenido(
          jornada: combinada,
          rangoLabel:
              '${jornadas.length} día${jornadas.length == 1 ? "" : "s"} combinados',
        );
      },
    );
  }
}

/// Fusiona N `JornadaDia` en una sola estructura como si fuera un
/// continuo de N×24h. La jornada resultante mantiene los timestamps
/// originales (el gráfico se extiende a 48h, 72h, etc.) y suma los
/// KPIs. Para detectar la "patente principal" del rango se cuenta
/// frecuencia entre las patentes de cada día.
JornadaDia _combinarJornadas(List<JornadaDia> jornadas) {
  assert(jornadas.isNotEmpty, '_combinarJornadas requiere lista no vacía');
  // Ordenar cronológicamente por inicio.
  final ordenadas = [...jornadas]..sort((a, b) => a.inicio.compareTo(b.inicio));

  // Concatenar listas — ya vienen ordenadas dentro de cada día.
  final tramos = <TramoManejo>[];
  final paradas = <Parada>[];
  final serie = <PuntoVelocidad>[];
  final patentes = <String>{};
  final patenteFreq = <String, int>{};

  var manejoMin = 0;
  var paradasMin = 0;
  var kmTotal = 0;
  var velMax = 0;
  var totalEv = 0;

  for (final j in ordenadas) {
    tramos.addAll(j.tramos);
    paradas.addAll(j.paradas);
    serie.addAll(j.serieVelocidad);
    patentes.addAll(j.patentes);
    patenteFreq[j.patentePrincipal] =
        (patenteFreq[j.patentePrincipal] ?? 0) + 1;
    manejoMin += j.manejoMin;
    paradasMin += j.paradasMin;
    kmTotal += j.kmTotal;
    if (j.velocidadMax > velMax) velMax = j.velocidadMax;
    totalEv += j.totalEventos;
  }

  // Ordenar la serie de velocidad por timestamp — debería estar
  // ya ordenada por el orden de procesamiento, pero por las dudas.
  serie.sort((a, b) => a.tsMs.compareTo(b.tsMs));

  // Patente más usada en el rango (la que aparece como principal en
  // más días). Empate → la primera alfabéticamente para determinismo.
  final patentePrincipal = patenteFreq.entries
          .toList()
          .let((entries) {
            entries.sort((a, b) {
              final cmp = b.value.compareTo(a.value);
              if (cmp != 0) return cmp;
              return a.key.compareTo(b.key);
            });
            return entries;
          })
          .firstOrNull
          ?.key ??
      ordenadas.first.patentePrincipal;

  return JornadaDia(
    id: '__combinada_${ordenadas.first.fecha}_${ordenadas.last.fecha}',
    choferDni: ordenadas.first.choferDni,
    choferNombre: ordenadas.first.choferNombre,
    patentePrincipal: patentePrincipal,
    patentes: patentes.toList()..sort(),
    fecha:
        '${ordenadas.first.fecha} → ${ordenadas.last.fecha}',
    inicio: ordenadas.first.inicio,
    fin: ordenadas.last.fin,
    manejoMin: manejoMin,
    paradasMin: paradasMin,
    kmTotal: kmTotal,
    velocidadMax: velMax,
    totalEventos: totalEv,
    tramos: tramos,
    paradas: paradas,
    serieVelocidad: serie,
  );
}

/// Mini extension para encadenar transformaciones en una expresión.
extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

// `_CardResumenDia` y `_MiniKpi` removidos 2026-05-28: la vista de rango
// pasó a ser combinada (una sola jornada continua) en lugar de lista
// de cards por día. Si en el futuro se decide ofrecer toggle "ver por
// día" vs "combinado", recuperar del git history (commit anterior a
// este).

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
              color: AppColors.info,
              onTap: cargandoChoferes ? null : onChofer,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _PillButton(
              icono: Icons.date_range,
              label: rangoLabel,
              color: AppColors.brandSoft,
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
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            Icon(icono, color: color, size: 18),
            const SizedBox(width: AppSpacing.sm),
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
            const SizedBox(height: AppSpacing.md),
            Text(
              titulo,
              textAlign: TextAlign.center,
              style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              subtitulo,
              textAlign: TextAlign.center,
              style: AppType.label.copyWith(color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }
}

class _Contenido extends StatelessWidget {
  final JornadaDia jornada;
  /// Opcional: cuando esta jornada es una fusión de varios días, este
  /// label se muestra arriba ("3 días combinados"). Si es null, se
  /// renderea la vista normal de 1 día.
  final String? rangoLabel;

  const _Contenido({required this.jornada, this.rangoLabel});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        if (rangoLabel != null) ...[
          Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.sm),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: AppColors.brandSoft.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                  color: AppColors.brandSoft.withValues(alpha: 0.40)),
            ),
            child: Row(
              children: [
                const Icon(Icons.merge_type,
                    color: AppColors.brandSoft, size: 16),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'VISTA COMBINADA — $rangoLabel',
                    style: AppType.eyebrow.copyWith(
                      color: AppColors.brandSoft,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        _ResumenCard(j: jornada, multiDia: rangoLabel != null),
        const SizedBox(height: AppSpacing.md),
        _GraficoVelocidad(j: jornada),
        const SizedBox(height: AppSpacing.lg),
        _SeccionLabel(
          icono: Icons.timeline,
          texto: 'TRAMOS DE MANEJO (${jornada.tramos.length})',
        ),
        const SizedBox(height: AppSpacing.sm),
        for (final t in jornada.tramos)
          _TramoCard(t: t, multiDia: rangoLabel != null),
        const SizedBox(height: AppSpacing.lg),
        _SeccionLabel(
          icono: Icons.local_parking,
          texto: 'PARADAS (${jornada.paradas.length})',
        ),
        const SizedBox(height: AppSpacing.sm),
        if (jornada.paradas.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Sin paradas detectadas entre tramos.',
              textAlign: TextAlign.center,
              style: AppType.label.copyWith(color: Colors.white54),
            ),
          ),
        for (final p in jornada.paradas)
          _ParadaCard(p: p, multiDia: rangoLabel != null),
      ],
    );
  }
}

class _ResumenCard extends StatelessWidget {
  final JornadaDia j;
  final bool multiDia;
  const _ResumenCard({required this.j, this.multiDia = false});

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
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  patentes,
                  style: AppType.heading.copyWith(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
              Text(
                '${_fmtHoraSegun(j.inicio, multiDia: multiDia)} → '
                '${_fmtHoraSegun(j.fin, multiDia: multiDia)}',
                style:
                    AppType.label.copyWith(color: Colors.white70),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 18,
            runSpacing: 10,
            children: [
              _Kpi(
                  label: 'MANEJO',
                  valor: _fmtHM(j.manejoMin),
                  icono: Icons.directions_car,
                  color: AppColors.info),
              _Kpi(
                  label: 'PARADAS',
                  valor: _fmtHM(j.paradasMin),
                  icono: Icons.local_parking,
                  color: AppColors.warning),
              _Kpi(
                  label: 'KM',
                  valor: j.kmTotal.toString(),
                  icono: Icons.route,
                  color: AppColors.brandSoft),
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
                style: AppType.body.copyWith(color: Colors.white, fontWeight: FontWeight.bold)),
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
        padding: EdgeInsets.all(AppSpacing.lg),
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
                  color: AppColors.brandSoft, size: 18),
              SizedBox(width: AppSpacing.sm),
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
                    color: AppColors.brandSoft,
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      color: AppColors.brandSoft.withValues(alpha: 0.15),
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
  final bool multiDia;
  const _TramoCard({required this.t, this.multiDia = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.directions_car,
              color: AppColors.info, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_fmtHoraSegun(t.desde, multiDia: multiDia)} → '
                  '${_fmtHoraSegun(t.hasta, multiDia: multiDia)}',
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
                  style: AppType.eyebrow.copyWith(color: Colors.white60),
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
  final bool multiDia;
  const _ParadaCard({required this.p, this.multiDia = false});

  @override
  Widget build(BuildContext context) {
    final color =
        p.cumple8h ? AppColors.success :
        p.cumple15min ? AppColors.brandSoft :
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
        borderRadius: BorderRadius.circular(AppRadius.sm),
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
                      '${_fmtHoraSegun(p.desde, multiDia: multiDia)} → '
                      '${_fmtHoraSegun(p.hasta, multiDia: multiDia)}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                    ),
                    const SizedBox(width: AppSpacing.sm),
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
                  style: AppType.eyebrow.copyWith(color: Colors.white60),
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
            style: AppType.eyebrow.copyWith(color: AppColors.success, fontWeight: FontWeight.bold, letterSpacing: 1.5),
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

/// Cuando la jornada cruza varios días (vista combinada), agregar
/// "DD/MM" delante para distinguir tramos/paradas del día 1 vs día 2.
String _fmtHoraSegun(DateTime d, {required bool multiDia}) {
  final hm = _fmtHoraCorta(d);
  if (!multiDia) return hm;
  return '${d.day.toString().padLeft(2, '0')}/'
      '${d.month.toString().padLeft(2, '0')} $hm';
}

String _fmtHM(int min) {
  if (min < 60) return '${min}m';
  final h = min ~/ 60;
  final m = min % 60;
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
