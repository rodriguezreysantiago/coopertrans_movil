import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/registro_jornada.dart';
import '../services/registro_jornada_service.dart';
import '../widgets/registro_jornada_card.dart';
import 'registro_jornada_detalle_screen.dart';

/// Vista ADMIN/SUPERVISOR del registro de jornada v3 (Paso 4 — destronar al v2).
///
/// El operador elige un chofer y ve su jornada REAL reconstruida (registro v3):
/// turno, manejo neto, pausas con motivo, recorrido, confianza y flags. Es la
/// fuente OFICIAL para adjudicar disputas (buzón de reclamos) y revisar
/// compliance, en vez del cómputo en vivo del v2 (que queda solo como aviso
/// preventivo). Solo lectura; lee `REGISTRO_JORNADAS` (la regla deja al
/// admin/supervisor/SEG_HIGIENE ver de cualquier chofer).
class AdminRegistroJornadaScreen extends StatefulWidget {
  /// Opcional: pre-seleccionar un chofer (p.ej. al venir desde un reclamo).
  final String? choferDniInicial;

  const AdminRegistroJornadaScreen({super.key, this.choferDniInicial});

  @override
  State<AdminRegistroJornadaScreen> createState() =>
      _AdminRegistroJornadaScreenState();
}

class _AdminRegistroJornadaScreenState
    extends State<AdminRegistroJornadaScreen> {
  String? _choferDni;
  String? _choferNombre;
  List<_ChoferOpt> _choferes = const [];
  bool _cargandoChoferes = true;
  bool _procesandoHoy = false;

  @override
  void initState() {
    super.initState();
    _choferDni = widget.choferDniInicial;
    _cargarChoferes();
  }

  Future<void> _cargarChoferes() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .where('ROL', whereIn: const ['CHOFER', 'USUARIO'])
          .get();
      final lista = snap.docs
          .map((d) {
            final m = d.data();
            return _ChoferOpt(
              dni: d.id,
              nombre: (m['NOMBRE'] as String?)?.trim() ?? d.id,
              activo: m['ACTIVO'] != false,
            );
          })
          .where((c) => c.activo)
          .toList()
        ..sort((a, b) => a.nombre.compareTo(b.nombre));
      if (!mounted) return;
      setState(() {
        _choferes = lista;
        _cargandoChoferes = false;
        if (_choferDni != null) {
          final match = lista.where((c) => c.dni == _choferDni);
          _choferNombre = match.isEmpty ? null : match.first.nombre;
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _cargandoChoferes = false);
    }
  }

  Future<void> _elegirChofer() async {
    if (_cargandoChoferes) return;
    final ctrl = TextEditingController();
    final elegido = await showModalBottomSheet<_ChoferOpt>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
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
    if (elegido != null && mounted) {
      setState(() {
        _choferDni = elegido.dni;
        _choferNombre = elegido.nombre;
      });
    }
  }

  /// Invoca la callable `procesarJornadaHoyChoferV3` por HTTPS directo (mismo
  /// patrón que el botón "Cargar jornada de hoy" del v2 — sin el plugin
  /// cloud_functions porque no tiene impl Windows). La callable reconstruye
  /// el turno en curso del chofer (00:00 ART → ahora) y lo persiste a
  /// REGISTRO_JORNADAS; el StreamBuilder de la lista se actualiza solo al
  /// llegar el doc nuevo. Idempotente — re-correr en el día sobre-escribe.
  Future<void> _procesarHoy() async {
    if (_choferDni == null || _procesandoHoy) return;
    setState(() => _procesandoHoy = true);
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
          'procesarJornadaHoyChoferV3';
      final response = await dio.post<Map<String, dynamic>>(
        url,
        data: {
          'data': {'choferDni': _choferDni},
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
      final persistidos = (result?['persistidos'] as num?)?.toInt() ?? 0;
      final eventos = (result?['eventos'] as num?)?.toInt() ?? 0;
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(persistidos > 0
            ? 'Jornada de hoy actualizada ($eventos eventos).'
            : 'Sin actividad del chofer hoy todavía.'),
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('No se pudo procesar la jornada: $e'),
      ));
    } finally {
      if (mounted) setState(() => _procesandoHoy = false);
    }
  }

  /// Abre el picker de rango pre-cargado con el rango actual y, al confirmar,
  /// navega al detalle combinando solo los turnos que iniciaron dentro del
  /// sub-rango. Solución al "gráfico muy denso" cuando el rango pill trae
  /// muchos turnos: el operador acota acá sin tener que volver y cambiar el
  /// pill global. Caps del picker = primer/último inicio de turno de la lista
  /// (no tiene sentido permitir elegir fechas fuera de los datos cargados).
  Future<void> _abrirCombinado(
    BuildContext ctx,
    List<RegistroJornada> jornadas,
  ) async {
    // Capturar referencias del context ANTES del await — el linter requiere
    // que no se use el BuildContext del StreamBuilder pasado a `ctx` después
    // de un gap async (el widget puede haberse desmontado).
    final messenger = ScaffoldMessenger.of(ctx);
    final navigator = Navigator.of(ctx);
    // Ordenar para sacar caps del picker.
    final ordenadas = [...jornadas]
      ..sort((a, b) => a.inicioTurno.compareTo(b.inicioTurno));
    final masViejo = _soloFecha(ordenadas.first.inicioTurno);
    final masNuevo = _soloFecha(ordenadas.last.inicioTurno);
    // Precarga con TODO el rango cargado — sin pill global, el picker es la
    // única vía para acotar. Por default abarca de la primera a la última
    // jornada listada; el usuario achica desde ahí.
    final r = await showDateRangePicker(
      context: ctx,
      initialDateRange: DateTimeRange(start: masViejo, end: masNuevo),
      firstDate: masViejo,
      lastDate: masNuevo,
      locale: const Locale('es', 'AR'),
      helpText: 'Acotar combinado',
      saveText: 'Combinar',
    );
    if (r == null || !mounted) return;
    final subDesde = DateTime(r.start.year, r.start.month, r.start.day);
    final subHasta =
        DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59);
    final filtradas = jornadas.where((j) {
      final d = j.inicioTurno;
      return !d.isBefore(subDesde) && !d.isAfter(subHasta);
    }).toList();

    if (filtradas.isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Sin turnos en el sub-rango elegido.'),
      ));
      return;
    }
    final jornada = filtradas.length == 1
        ? filtradas.first
        : _combinarRegistros(filtradas);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => RegistroJornadaDetalleScreen(
          jornada: jornada,
          choferNombre: _choferNombre,
        ),
      ),
    );
  }

  DateTime _soloFecha(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Jornada real (registro v3)',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Selector de chofer — único pill del entry. El rango/fechas se
          // pide ad-hoc al apretar "Ver combinado" (cada turno ya tiene su
          // fecha en la card del listado), siguiendo el feedback de Santiago
          // 2026-06-08: "las fechas se cambian dentro de cada chofer".
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
            child: _SelectorPill(
              icono: _cargandoChoferes
                  ? Icons.hourglass_empty
                  : Icons.person_outline,
              label: _choferNombre ??
                  (_cargandoChoferes ? 'Cargando choferes…' : 'Elegí un chofer'),
              muted: _choferNombre == null,
              onTap: _cargandoChoferes ? null : _elegirChofer,
            ),
          ),
          // CTA "Cargar jornada de hoy" — el cron diario procesa AYER a las
          // 06:45 ART, así que HOY no existe en REGISTRO_JORNADAS hasta
          // mañana. Este botón dispara la callable
          // `procesarJornadaHoyChoferV3` que reconstruye el turno parcial
          // (00:00 ART → ahora) y lo persiste. La lista lo levanta sola.
          if (_choferDni != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
              child: _BotonCargarHoy(
                cargando: _procesandoHoy,
                onTap: _procesandoHoy ? null : _procesarHoy,
              ),
            ),
          Expanded(child: _contenido()),
        ],
      ),
    );
  }

  Widget _contenido() {
    if (_choferDni == null) {
      return const AppEmptyState(
        icon: Icons.badge_outlined,
        title: 'Elegí un chofer',
        subtitle: 'Para ver su jornada real reconstruida desde Sitrack.',
      );
    }
    return StreamBuilder<List<RegistroJornada>>(
      stream: RegistroJornadaService.streamUltimasDelChofer(
          choferDni: _choferDni!),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return AppErrorState(
            title: 'No se pudo cargar el registro',
            subtitle: snap.error.toString(),
          );
        }
        if (!snap.hasData) {
          return const AppLoadingState(message: 'Cargando registro…');
        }
        final jornadas = snap.data!;
        if (jornadas.isEmpty) {
          return AppEmptyState(
            icon: Icons.route_outlined,
            title: 'Sin jornadas registradas',
            subtitle: '${_choferNombre ?? _choferDni} no tiene registros v3 '
                'todavía. Probá "Cargar jornada de hoy" si está manejando.',
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Botón "Ver combinado" si hay >1 turno — abre primero un
            // date-range picker para acotar el sub-rango del combinado
            // (con muchos turnos el gráfico queda denso). Default precargado
            // con el rango actual del pill; si quedan 0 turnos en el sub-rango
            // muestra snackbar, si queda 1 abre su detalle individual.
            if (jornadas.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
                child: _BotonVerCombinado(
                  cantidad: jornadas.length,
                  onTap: () => _abrirCombinado(ctx, jornadas),
                ),
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(AppSpacing.lg),
                itemCount: jornadas.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: AppSpacing.md),
                itemBuilder: (ctx, i) => RegistroJornadaCard(
                  j: jornadas[i],
                  onTap: () => Navigator.of(ctx).push(
                    MaterialPageRoute<void>(
                      builder: (_) => RegistroJornadaDetalleScreen(
                        jornada: jornadas[i],
                        choferNombre: _choferNombre,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ────────────────────────────────────────────────────────────────────────
// Fusión multi-turno (paridad con `_combinarJornadas` del v2)
// ────────────────────────────────────────────────────────────────────────

/// Fusiona varios turnos del registro v3 en un solo `RegistroJornada` sintético
/// — la pantalla de detalle lo recibe y muestra un gráfico velocidad/tiempo
/// continuo + tramos y paradas ordenados cronológicamente + KPIs sumados.
///
/// No es un doc real (id sintético `__combinado_X→Y`); es solo input para
/// la UI. Convenciones:
/// - Tiempos: inicio = inicioTurno del más viejo; fin = finTurno del más
///   nuevo. Recorrer huecos entre turnos: se ven en el gráfico como tramos
///   en 0 (no hay puntos de la serie esos minutos).
/// - Sumas: manejo neto, pausa total, km, bloques excedidos.
/// - OR: jornadaExcedida, vedaExcedida, descansoInsuficiente, driftFiltrado.
/// - Min (peor): confianza.
/// - Concat ordenado por timestamp: pausas, segmentos, serieVelocidad,
///   bloques, explicacion.
RegistroJornada _combinarRegistros(List<RegistroJornada> jornadas) {
  assert(jornadas.isNotEmpty, '_combinarRegistros requiere lista no vacía');
  final ordenadas = [...jornadas]
    ..sort((a, b) => a.inicioTurno.compareTo(b.inicioTurno));
  final primero = ordenadas.first;
  final ultimo = ordenadas.last;

  final bloques = <BloqueJornada>[];
  final pausas = <PausaJornada>[];
  final segmentos = <SegmentoJornada>[];
  final serie = <PuntoVelocidad>[];
  final explicacion = <String>[];
  var manejoNeto = 0;
  var pausaTotal = 0;
  var recorrido = 0;
  var bloquesExc = 0;
  var jornadaExc = false;
  var vedaExc = false;
  var descansoInsuf = false;
  var driftF = false;
  String confianza = 'alta';

  for (final j in ordenadas) {
    bloques.addAll(j.bloques);
    pausas.addAll(j.pausas);
    segmentos.addAll(j.segmentos);
    serie.addAll(j.serieVelocidad);
    explicacion
      ..add('— Turno ${_hhmmFecha(j.inicioTurno)} →')
      ..addAll(j.explicacion);
    manejoNeto += j.manejoNetoSeg;
    pausaTotal += j.pausaTotalSeg;
    recorrido += j.recorridoKm;
    bloquesExc += j.bloquesExcedidos;
    jornadaExc = jornadaExc || j.jornadaExcedida;
    vedaExc = vedaExc || j.vedaExcedida;
    descansoInsuf = descansoInsuf || j.descansoInsuficiente;
    driftF = driftF || j.driftFiltrado;
    confianza = _peorConfianza(confianza, j.confianza);
  }

  pausas.sort((a, b) => a.inicio.compareTo(b.inicio));
  segmentos.sort((a, b) => a.inicio.compareTo(b.inicio));
  serie.sort((a, b) => a.tsMs.compareTo(b.tsMs));

  return RegistroJornada(
    id: '__combinado_${primero.fecha}_${ultimo.fecha}',
    choferDni: primero.choferDni,
    patente: primero.patente,
    fecha: primero.fecha == ultimo.fecha
        ? primero.fecha
        : '${primero.fecha} → ${ultimo.fecha}',
    inicioTurno: primero.inicioTurno,
    finTurno: ultimo.finTurno,
    manejoNetoSeg: manejoNeto,
    pausaTotalSeg: pausaTotal,
    recorridoKm: recorrido,
    bloques: bloques,
    bloquesExcedidos: bloquesExc,
    jornadaExcedida: jornadaExc,
    vedaExcedida: vedaExc,
    descansoPrevioSeg: primero.descansoPrevioSeg,
    descansoInsuficiente: descansoInsuf,
    driftFiltrado: driftF,
    confianza: confianza,
    pausas: pausas,
    segmentos: segmentos,
    serieVelocidad: serie,
    explicacion: explicacion,
  );
}

String _peorConfianza(String a, String b) {
  // alta > media > baja → devuelve la "peor" de las dos.
  int rank(String x) => x == 'alta' ? 2 : (x == 'media' ? 1 : 0);
  return rank(a) <= rank(b) ? a : b;
}

String _hhmmFecha(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/'
    '${d.month.toString().padLeft(2, '0')} '
    '${d.hour.toString().padLeft(2, '0')}:'
    '${d.minute.toString().padLeft(2, '0')}';

class _ChoferOpt {
  final String dni;
  final String nombre;
  final bool activo;
  const _ChoferOpt(
      {required this.dni, required this.nombre, required this.activo});
}

/// Pill tappable (chofer). Mismo gesto que el selector de la pantalla
/// Jornada del v2.
class _SelectorPill extends StatelessWidget {
  final IconData icono;
  final String label;
  final bool muted;
  final VoidCallback? onTap;

  const _SelectorPill({
    required this.icono,
    required this.label,
    this.muted = false,
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
              Icon(icono, size: 16, color: enabled ? c.brand : c.textMuted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
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

/// Pill CTA "Cargar jornada de hoy" — mismo gesto visual que las pills de
/// selectores pero pintado en brand para señalar acción. Estado de carga con
/// spinner para que el admin sepa que la callable está corriendo (hasta 120 s
/// timeout en el server).
class _BotonCargarHoy extends StatelessWidget {
  final bool cargando;
  final VoidCallback? onTap;
  const _BotonCargarHoy({required this.cargando, required this.onTap});

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
            color: enabled ? c.brand.withValues(alpha: 0.12) : c.surface2,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(
                color: enabled ? c.brand.withValues(alpha: 0.5) : c.border),
          ),
          child: Row(
            children: [
              cargando
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(c.brand),
                      ),
                    )
                  : Icon(Icons.download_for_offline_outlined,
                      size: 16, color: enabled ? c.brand : c.textMuted),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  cargando
                      ? 'Procesando…'
                      : 'Cargar jornada de hoy',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: enabled ? c.brand : c.textMuted,
                    fontWeight: FontWeight.w600,
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

/// Pill CTA "Ver combinado" — visible cuando el rango trae > 1 turno. Abre el
/// detalle con el `RegistroJornada` fusionado (gráfico continuo, tramos +
/// paradas en orden cronológico). Pintado en info como el accent de tramos.
class _BotonVerCombinado extends StatelessWidget {
  final int cantidad;
  final VoidCallback onTap;
  const _BotonVerCombinado({required this.cantidad, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: c.info.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: c.info.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(Icons.timeline, size: 16, color: c.info),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  'Ver combinado · $cantidad turnos',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                    color: c.info,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(Icons.arrow_forward, size: 14, color: c.info),
            ],
          ),
        ),
      ),
    );
  }
}
