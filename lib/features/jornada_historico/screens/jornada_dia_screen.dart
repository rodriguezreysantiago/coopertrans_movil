// lib/features/jornada_historico/screens/jornada_dia_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — jornada de manejo del chofer en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream del doc (`JornadaHistoricoService.streamDia` /
//     `streamPorRango`, colección `VOLVO_JORNADAS_HISTORICO`),
//   - el modelo `JornadaDia` (tramos, paradas, serie de velocidad, KPIs),
//   - la fusión client-side de varios días (`_combinarJornadas`),
//   - la callable `procesarJornadaHoyChofer` (POST HTTPS con idToken),
//   - el stream de EMPLEADOS para el dropdown de choferes (`_cargarChoferes`),
//   - el State (chofer/rango seleccionados, `_esUnSoloDia`, `_esHoy`),
//   - el `LineChart` de fl_chart (mismos spots/ejes; solo recoloreado).
//
// Layout Núcleo:
//   ┌─ Selectores (chofer · rango fechas) — pills tappables ──────────┐
//   ├─ Hero: eyebrow JORNADA · fecha/rango · patente · inicio→fin ────┤
//   ├─ AppKpiStrip: manejo · km · vel máx · paradas ──────────────────┤
//   ├─ Gráfico de velocidad (fl_chart envuelto en AppCard) ───────────┤
//   ├─ TRAMOS DE MANEJO (filas + AppHairline, horarios en mono) ──────┤
//   └─ PARADAS (AppDot/AppBadge por tipo, horarios en mono) ──────────┘
//
// Reglas duras: tokens (context.colors), números/horarios en AppType.mono,
// embedded (sin fondo full-screen propio), faltante → "—", sin overflow.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
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
            orElse: () =>
                _ChoferOpt(dni: _choferDni!, nombre: _choferDni!, activo: true),
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
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (ctx) {
        final c = ctx.colors;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.md),
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
                    const AppEyebrow('ELEGIR CHOFER'),
                    const SizedBox(height: AppSpacing.md),
                    AppInput(
                      controller: ctrl,
                      autofocus: true,
                      icon: Icons.search,
                      hint: 'Buscar por nombre o DNI',
                      onChanged: (_) => setStateSheet(() {}),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Expanded(
                      child: filtrados.isEmpty
                          ? const AppEmptyState(
                              icon: Icons.person_search,
                              title: 'Sin coincidencias',
                              subtitle: 'Probá con otro nombre o DNI.',
                            )
                          : ListView.separated(
                              itemCount: filtrados.length,
                              separatorBuilder: (_, __) => const AppHairline(),
                              itemBuilder: (ctx, i) {
                                final opt = filtrados[i];
                                return InkWell(
                                  onTap: () => Navigator.pop(ctx, opt),
                                  borderRadius:
                                      BorderRadius.circular(AppRadius.lg),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: AppSpacing.md,
                                        horizontal: AppSpacing.sm),
                                    child: Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            opt.nombre,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: AppType.body
                                                .copyWith(color: c.text),
                                          ),
                                        ),
                                        const SizedBox(width: AppSpacing.md),
                                        Text(
                                          'DNI ${opt.dni}',
                                          style: AppType.monoSm
                                              .copyWith(color: c.textMuted),
                                        ),
                                      ],
                                    ),
                                  ),
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
            choferElegido: _choferNombre != null,
            rangoLabel: _esUnSoloDia
                ? _fmtFecha(_desde)
                : '${_fmtFecha(_desde)} → ${_fmtFecha(_hasta)}',
            cargandoChoferes: _cargandoChoferes,
            onChofer: _elegirChofer,
            onRango: _elegirRango,
          ),
          Expanded(
            child: _choferDni == null
                ? const AppEmptyState(
                    icon: Icons.person_search,
                    title: 'Elegí un chofer para ver su jornada',
                    subtitle: 'Tocá "Elegir chofer" arriba.',
                  )
                : (_esUnSoloDia
                    ? _DetalleUnDia(choferDni: _choferDni!, fecha: _desde)
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
/// + paradas).
///
/// Caso HOY: el cron `reconstruirJornadasDiario` corre a las 06:30 ART
/// procesando AYER, así que HOY no existe en `VOLVO_JORNADAS_HISTORICO`
/// hasta mañana. Para no quedar ciegos en el día, exponemos un botón
/// "Cargar jornada de hoy" que invoca la callable `procesarJornadaHoyChofer`
/// — procesa los eventos parciales (hoy 00:00 ART → ahora) y persiste
/// al mismo doc, por lo que el StreamBuilder se actualiza solo al
/// terminar. Si el doc ya existe (porque el admin ya lo cargó antes
/// hoy o estamos viendo ayer), aparece un botón flotante para "Actualizar".
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
          return const AppSkeletonList(count: 4, conAvatar: false);
        }
        if (snap.hasError) {
          return AppErrorState(
            title: 'Error al cargar la jornada',
            subtitle: snap.error.toString(),
          );
        }
        final j = snap.data;
        if (j == null) {
          // Estado vacío con CTA específico cuando es HOY — sino el
          // usuario no tendría forma de pedir el procesamiento parcial.
          return AppEmptyState(
            icon: Icons.event_busy,
            title: _esHoy
                ? 'Jornada de hoy no procesada todavía'
                : 'Sin jornada procesada',
            subtitle: _esHoy
                ? 'El cron procesa los días completos a las 06:30 ART. '
                    'Tocá "Cargar jornada de hoy" para reconstruir lo que '
                    'lleva el día hasta ahora.'
                : 'Este chofer no manejó ese día.',
            action: _esHoy
                ? AppButton.primary(
                    label: _procesando
                        ? 'Procesando…'
                        : 'Cargar jornada de hoy',
                    icon: Icons.refresh,
                    loading: _procesando,
                    onPressed: _procesando ? null : _procesarHoy,
                  )
                : null,
          );
        }
        // Hay jornada — si es HOY, dejamos un botón flotante para refrescar.
        return Stack(
          children: [
            _Contenido(jornada: j),
            if (_esHoy)
              Positioned(
                right: AppSpacing.lg,
                bottom: AppSpacing.lg,
                child: AppButton.primary(
                  label: _procesando ? 'Actualizando…' : 'Actualizar',
                  icon: Icons.refresh,
                  loading: _procesando,
                  onPressed: _procesando ? null : _procesarHoy,
                ),
              ),
          ],
        );
      },
    );
  }
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
      {required this.choferDni, required this.desde, required this.hasta});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<JornadaDia>>(
      stream: JornadaHistoricoService.streamPorRango(
          choferDni: choferDni, desde: desde, hasta: hasta),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSkeletonList(count: 4, conAvatar: false);
        }
        if (snap.hasError) {
          return AppErrorState(
            title: 'Error al cargar las jornadas del rango',
            subtitle: snap.error.toString(),
          );
        }
        final jornadas = snap.data ?? const [];
        if (jornadas.isEmpty) {
          return const AppEmptyState(
            icon: Icons.event_busy,
            title: 'Sin jornadas en el rango',
            subtitle:
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
    fecha: '${ordenadas.first.fecha} → ${ordenadas.last.fecha}',
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

// =============================================================================
// SELECTORES · chofer · rango fechas (pills tappables Núcleo)
// =============================================================================

class _Selectores extends StatelessWidget {
  final String choferLabel;
  final bool choferElegido;
  final String rangoLabel;
  final bool cargandoChoferes;
  final VoidCallback onChofer;
  final VoidCallback onRango;

  const _Selectores({
    required this.choferLabel,
    required this.choferElegido,
    required this.rangoLabel,
    required this.cargandoChoferes,
    required this.onChofer,
    required this.onRango,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: _SelectorPill(
              icono: cargandoChoferes
                  ? Icons.hourglass_empty
                  : Icons.person_outline,
              label: choferLabel,
              muted: !choferElegido,
              onTap: cargandoChoferes ? null : onChofer,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _SelectorPill(
              icono: Icons.date_range,
              label: rangoLabel,
              mono: true,
              onTap: onRango,
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill tappable estilo Núcleo: surface2 + hairline, icono brand,
/// label en una línea. Se usa para los selectores de chofer y rango.
class _SelectorPill extends StatelessWidget {
  final IconData icono;
  final String label;
  final bool muted;
  final bool mono;
  final VoidCallback? onTap;

  const _SelectorPill({
    required this.icono,
    required this.label,
    this.muted = false,
    this.mono = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final enabled = onTap != null;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: c.border),
          ),
          child: Row(
            children: [
              Icon(icono,
                  size: 16,
                  color: enabled ? c.brand : c.textMuted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (mono ? AppType.mono : AppType.body).copyWith(
                    color: muted ? c.textMuted : c.text,
                    fontWeight: FontWeight.w500,
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

// =============================================================================
// CONTENIDO · hero + KPIs + gráfico + tramos + paradas
// =============================================================================

class _Contenido extends StatelessWidget {
  final JornadaDia jornada;

  /// Opcional: cuando esta jornada es una fusión de varios días, este
  /// label se muestra arriba ("3 días combinados"). Si es null, se
  /// renderea la vista normal de 1 día.
  final String? rangoLabel;

  const _Contenido({required this.jornada, this.rangoLabel});

  @override
  Widget build(BuildContext context) {
    final multiDia = rangoLabel != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xxl,
      ),
      children: [
        _Hero(j: jornada, rangoLabel: rangoLabel),
        const SizedBox(height: AppSpacing.mdDense),
        _KpiStripJornada(j: jornada),
        const SizedBox(height: AppSpacing.mdDense),
        _GraficoVelocidad(j: jornada),
        const SizedBox(height: AppSpacing.mdDense),
        _SeccionTramos(j: jornada, multiDia: multiDia),
        const SizedBox(height: AppSpacing.mdDense),
        _SeccionParadas(j: jornada, multiDia: multiDia),
      ],
    );
  }
}

// =============================================================================
// HERO · eyebrow JORNADA · fecha/rango · patente · inicio→fin
// =============================================================================

class _Hero extends StatelessWidget {
  final JornadaDia j;
  final String? rangoLabel;
  const _Hero({required this.j, this.rangoLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final multiDia = rangoLabel != null;
    final patente = j.patentePrincipal.isNotEmpty ? j.patentePrincipal : '—';
    final patenteExtra =
        j.patentes.length > 1 ? '+${j.patentes.length - 1}' : null;
    final chofer = j.choferNombre?.trim();
    final tieneChofer = chofer != null && chofer.isNotEmpty;

    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const AppEyebrow('JORNADA'),
              const Spacer(),
              if (multiDia)
                AppBadge(
                  text: 'COMBINADA',
                  color: c.brand,
                  dot: true,
                  size: AppBadgeSize.sm,
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Fecha (o rango) — hero del bloque.
          Text(
            _fmtFechaLarga(j.fecha),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: AppType.h4.copyWith(color: c.text),
          ),
          if (multiDia) ...[
            const SizedBox(height: 2),
            Text(
              rangoLabel!,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _HeroMeta(
                icon: Icons.local_shipping_outlined,
                label: 'Unidad',
                value: patenteExtra != null ? '$patente ($patenteExtra)' : patente,
                mono: true,
              ),
              if (tieneChofer)
                _HeroMeta(
                  icon: Icons.person_outline,
                  label: chofer,
                  value: 'DNI ${j.choferDni}',
                  mono: true,
                ),
              _HeroMeta(
                icon: Icons.schedule,
                label: 'Inicio → fin',
                value: '${_fmtHoraSegun(j.inicio, multiDia: multiDia)} → '
                    '${_fmtHoraSegun(j.fin, multiDia: multiDia)}',
                mono: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeroMeta extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool mono;
  const _HeroMeta({
    required this.icon,
    required this.label,
    required this.value,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: c.textMuted),
        const SizedBox(width: AppSpacing.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: AppType.bodySm.copyWith(color: c.text), maxLines: 1),
            Text(value,
                style: (mono ? AppType.monoSm : AppType.bodySm)
                    .copyWith(color: c.textMuted),
                maxLines: 1),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// KPI STRIP · manejo · km · vel máx · paradas
// =============================================================================

class _KpiStripJornada extends StatelessWidget {
  final JornadaDia j;
  const _KpiStripJornada({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final stats = <AppStat>[
      AppStat(
        label: 'Manejo',
        value: _fmtHM(j.manejoMin),
        valueStyle: AppType.h4,
        accent: c.text,
      ),
      AppStat(
        label: 'Km',
        value: j.kmTotal > 0 ? AppFormatters.formatearMiles(j.kmTotal) : '—',
        valueStyle: AppType.h4,
        accent: j.kmTotal > 0 ? c.brand : c.textMuted,
      ),
      AppStat(
        label: 'Vel máx',
        value: j.velocidadMax > 0 ? '${j.velocidadMax}' : '—',
        unit: j.velocidadMax > 0 ? 'km/h' : null,
        valueStyle: AppType.h4,
        accent: j.velocidadMax > 0 ? c.text : c.textMuted,
      ),
      AppStat(
        label: 'Paradas',
        value: _fmtHM(j.paradasMin),
        valueStyle: AppType.h4,
        accent: c.text,
        delta: j.paradas.isNotEmpty
            ? '${j.paradas.length} parada${j.paradas.length == 1 ? "" : "s"}'
            : null,
        deltaColor: c.textMuted,
      ),
    ];

    return LayoutBuilder(
      builder: (ctx, constraints) {
        // En anchos chicos un strip de 4 columnas aprieta los hero
        // numbers. Bajo cierto umbral lo partimos en dos strips (2 + 2).
        if (constraints.maxWidth < 460) {
          return Column(
            children: [
              AppKpiStrip(stats: stats.sublist(0, 2)),
              const SizedBox(height: AppSpacing.sm),
              AppKpiStrip(stats: stats.sublist(2)),
            ],
          );
        }
        return AppKpiStrip(stats: stats);
      },
    );
  }
}

// =============================================================================
// GRÁFICO DE VELOCIDAD · fl_chart envuelto en AppCard (chart preservado)
// =============================================================================

class _GraficoVelocidad extends StatelessWidget {
  final JornadaDia j;
  const _GraficoVelocidad({required this.j});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (j.serieVelocidad.length < 2) {
      return AppCard(
        tier: 2,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppEyebrow('VELOCIDAD'),
            const SizedBox(height: AppSpacing.md),
            Text(
              'Sin serie de velocidad suficiente para graficar.',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
          ],
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
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppDot(c.brand, size: 7),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('VELOCIDAD', color: c.brand),
              const Spacer(),
              Text('km/h',
                  style: AppType.monoSm.copyWith(color: c.textMuted)),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
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
                      interval: 25,
                      reservedSize: 30,
                      getTitlesWidget: (v, m) => Text(
                        v.toInt().toString(),
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
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
                        return Text(
                          _fmtHoraCorta(d),
                          style: AppType.monoSm.copyWith(color: c.textMuted),
                        );
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
                    barWidth: 1.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          c.brand.withValues(alpha: 0.22),
                          c.brand.withValues(alpha: 0),
                        ],
                      ),
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

// =============================================================================
// SECCIÓN · primitiva bento (eyebrow + dot opcional + contenido)
// =============================================================================

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

// =============================================================================
// TRAMOS DE MANEJO · filas separadas por hairline, horarios en mono
// =============================================================================

class _SeccionTramos extends StatelessWidget {
  final JornadaDia j;
  final bool multiDia;
  const _SeccionTramos({required this.j, required this.multiDia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = j.tramos.length;
    return _Seccion(
      titulo: 'TRAMOS DE MANEJO',
      accentDot: c.info,
      trailing: Text(
        '$n',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        if (n == 0)
          Text(
            'Sin tramos de manejo detectados.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else
          for (var i = 0; i < n; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.md),
              const AppHairline(),
              const SizedBox(height: AppSpacing.md),
            ],
            _FilaTramo(t: j.tramos[i], multiDia: multiDia),
          ],
      ],
    );
  }
}

class _FilaTramo extends StatelessWidget {
  final TramoManejo t;
  final bool multiDia;
  const _FilaTramo({required this.t, required this.multiDia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppDot(c.info, size: 6),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_fmtHoraSegun(t.desde, multiDia: multiDia)} → '
                '${_fmtHoraSegun(t.hasta, multiDia: multiDia)}',
                style: AppType.mono.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '${_fmtHM(t.duracionMin)} · '
                '${t.kmAprox > 0 ? "${AppFormatters.formatearMiles(t.kmAprox)} km · " : ""}'
                'máx ${t.velocidadMax} · prom ${t.velocidadProm} km/h',
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// PARADAS · AppDot/AppBadge por tipo (corte de bloque / descanso 8h)
// =============================================================================

class _SeccionParadas extends StatelessWidget {
  final JornadaDia j;
  final bool multiDia;
  const _SeccionParadas({required this.j, required this.multiDia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = j.paradas.length;
    return _Seccion(
      titulo: 'PARADAS',
      accentDot: c.warning,
      trailing: Text(
        '$n',
        style: AppType.monoSm.copyWith(color: c.textMuted),
      ),
      children: [
        if (n == 0)
          Text(
            'Sin paradas detectadas entre tramos.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else
          for (var i = 0; i < n; i++) ...[
            if (i > 0) ...[
              const SizedBox(height: AppSpacing.md),
              const AppHairline(),
              const SizedBox(height: AppSpacing.md),
            ],
            _FilaParada(p: j.paradas[i], multiDia: multiDia),
          ],
      ],
    );
  }
}

class _FilaParada extends StatelessWidget {
  final Parada p;
  final bool multiDia;
  const _FilaParada({required this.p, required this.multiDia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Color semántico según la política Vecchi v2:
    //   - descanso entre jornadas (≥8h) → verde
    //   - corte de bloque suficiente (≥15 min) → indigo (brand)
    //   - insuficiente para cortar bloque → ámbar
    final color = p.cumple8h
        ? c.success
        : p.cumple15min
            ? c.brand
            : c.warning;
    final hint = p.cumple8h
        ? 'Descanso entre jornadas (≥ 8h)'
        : p.cumple15min
            ? 'Corte de bloque suficiente (≥ 15 min)'
            : 'Insuficiente para cortar bloque (< 15 min)';
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: AppDot(color, size: 6),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_fmtHoraSegun(p.desde, multiDia: multiDia)} → '
                      '${_fmtHoraSegun(p.hasta, multiDia: multiDia)}',
                      style: AppType.mono.copyWith(color: c.text),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  AppBadge(
                    text: p.etiqueta.toUpperCase(),
                    color: color,
                    size: AppBadgeSize.sm,
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                '${_fmtHM(p.duracionMin)} · $hint',
                style: AppType.bodySm.copyWith(color: c.textSecondary),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// FORMATTERS LOCALES (sin cambios de lógica)
// =============================================================================

String _fmtFecha(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';

String _fmtHoraCorta(DateTime d) =>
    '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

/// Convierte el `fecha` del modelo (`YYYY-MM-DD`, o `YYYY-MM-DD → YYYY-MM-DD`
/// en vista combinada) al formato AR `DD-MM-AAAA`. Si no parsea, devuelve
/// el original tal cual (nunca inventa).
String _fmtFechaLarga(String iso) {
  String uno(String s) {
    final partes = s.trim().split('-');
    if (partes.length != 3) return s.trim();
    return '${partes[2]}-${partes[1]}-${partes[0]}';
  }

  if (iso.contains('→')) {
    final lados = iso.split('→');
    if (lados.length == 2) {
      return '${uno(lados[0])} → ${uno(lados[1])}';
    }
  }
  return uno(iso);
}

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
