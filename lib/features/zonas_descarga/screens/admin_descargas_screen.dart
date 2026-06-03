// lib/features/zonas_descarga/screens/admin_descargas_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — cola en vivo + histórico en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - el stream de zonas (`ZonasDescargaService.stream()`),
//   - los streams Firestore de cola en vivo (`ZONA_DESCARGA_COLA`) e
//     histórico (`ZONA_DESCARGA_HISTORICO`) con sus where/orderBy/limit,
//   - el agregado de KPIs por `.get()` one-shot (NO snapshots, límite 5000)
//     que se recalcula al cambiar zona/rango (didUpdateWidget),
//   - el State (slug seleccionado + rango desde/hasta) y `_elegirRango`
//     (date range picker es/AR con la regla "si hasta == hoy → ahora"),
//   - la navegación al CRUD de zonas (`AppRoutes.adminZonasDescarga`).
//
// Layout Núcleo:
//   ┌─ Hero: eyebrow DESCARGAS · zona + hero number "N descargando ahora" ─┐
//   ├─ Acciones: gestionar zonas · rango (chip mono) ─────────────────────┤
//   ├─ Selector de zona (AppFilterChip) si hay > 1 ───────────────────────┤
//   ├─ AppKpiStrip: descargas · promedio · más lenta ─────────────────────┤
//   ├─ Cola en vivo (AppCard + AppHairline por fila, mono "hace X min") ──┤
//   └─ Histórico del rango (AppCard + AppHairline por fila) ──────────────┘
//
// Reglas duras: tokens (context.colors), números en AppType.mono, faltante
// → "—", embedded (AppScaffold auto-detecta el shell), sin overflow.
//
// La cola en vivo se LEVANTA al tope (un único StreamBuilder) para que el
// hero number, el dot de estado y la lista compartan la misma fuente —
// antes el stream vivía adentro de la sección de cola.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/zona_descarga.dart';
import '../services/zonas_descarga_service.dart';

/// Módulo "Descargas" — cola en vivo + recién descargaron + KPIs.
///
/// Reemplazó al detector PTO Volvo (eliminado 2026-05-24) que daba
/// falsos positivos y solo cubría flota Volvo. Ahora el dato viene de
/// presencia REAL en geocercas configurables (`ZONAS_DESCARGA`) que la
/// CF `zonaDescargaPoller` cruza con Sitrack — cubre la flota completa.
///
/// Para que funcione tienen que estar cargadas las zonas desde
/// "Zonas de descarga" (admin). Si no hay zonas → estado vacío con
/// CTA a esa pantalla.
class AdminDescargasScreen extends StatefulWidget {
  const AdminDescargasScreen({super.key});

  @override
  State<AdminDescargasScreen> createState() => _AdminDescargasScreenState();
}

class _AdminDescargasScreenState extends State<AdminDescargasScreen> {
  String? _slugSeleccionado;

  /// Rango de fechas para filtrar el histórico de descargas. Default:
  /// hoy 00:00 → ahora. La cola en vivo NO se filtra (siempre es ahora).
  late DateTime _desde;
  late DateTime _hasta;

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _desde = DateTime(ahora.year, ahora.month, ahora.day); // 00:00 hoy
    _hasta = ahora;
  }

  Future<void> _elegirRango() async {
    final ahora = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: ahora.subtract(const Duration(days: 365)),
      lastDate: ahora,
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
      helpText: 'Rango de descargas a mostrar',
      saveText: 'Aplicar',
      locale: const Locale('es', 'AR'),
    );
    if (r == null) return;
    setState(() {
      _desde = DateTime(r.start.year, r.start.month, r.start.day);
      // Si elegís HOY como hasta, queremos hasta AHORA (no medianoche).
      // Si elegís un día pasado, hasta el fin del día.
      final esHoy = r.end.year == ahora.year &&
          r.end.month == ahora.month &&
          r.end.day == ahora.day;
      _hasta = esHoy
          ? ahora
          : DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Descargas',
      body: StreamBuilder<List<ZonaDescarga>>(
        stream: ZonasDescargaService.stream(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const AppSkeletonList(count: 4, conAvatar: false);
          }
          final zonas = (snap.data ?? const <ZonaDescarga>[])
              .where((z) => z.activo)
              .toList();
          if (zonas.isEmpty) {
            return const _SinZonas();
          }
          _slugSeleccionado ??= zonas.first.slug;
          final zonaActual = zonas.firstWhere(
            (z) => z.slug == _slugSeleccionado,
            orElse: () => zonas.first,
          );
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.xxl,
            ),
            children: [
              // Cola en vivo levantada al tope: alimenta el hero number, el
              // dot de estado y la lista, con un único listener.
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection(AppCollections.zonaDescargaCola)
                    .where('slug_zona', isEqualTo: zonaActual.slug)
                    .snapshots(),
                builder: (cctx, csnap) {
                  final cargandoCola =
                      csnap.connectionState == ConnectionState.waiting;
                  final docsCola = (csnap.data?.docs ?? const []).toList()
                    ..sort((a, b) {
                      final ta = (a.data()['entrada_ts'] as Timestamp?);
                      final tb = (b.data()['entrada_ts'] as Timestamp?);
                      if (ta == null && tb == null) return 0;
                      if (ta == null) return 1;
                      if (tb == null) return -1;
                      return ta.compareTo(tb);
                    });
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Hero(
                        zona: zonaActual,
                        enCola: docsCola.length,
                        cargando: cargandoCola,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _Acciones(
                        desde: _desde,
                        hasta: _hasta,
                        onRango: _elegirRango,
                        onGestionarZonas: () => Navigator.pushNamed(
                            context, AppRoutes.adminZonasDescarga),
                      ),
                      if (zonas.length > 1) ...[
                        const SizedBox(height: AppSpacing.md),
                        _SelectorZona(
                          zonas: zonas,
                          seleccionada: zonaActual.slug,
                          onChanged: (s) =>
                              setState(() => _slugSeleccionado = s),
                        ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                      _KpisZona(
                        slug: zonaActual.slug,
                        desde: _desde,
                        hasta: _hasta,
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _ColaEnVivo(
                        zona: zonaActual,
                        cargando: cargandoCola,
                        docs: docsCola,
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: AppSpacing.lg),
              _DescargasDelRango(
                slug: zonaActual.slug,
                desde: _desde,
                hasta: _hasta,
              ),
            ],
          );
        },
      ),
    );
  }
}

// =============================================================================
// HERO · eyebrow DESCARGAS · zona + hero number "N descargando ahora"
// =============================================================================

class _Hero extends StatelessWidget {
  final ZonaDescarga zona;
  final int enCola;
  final bool cargando;
  const _Hero({
    required this.zona,
    required this.enCola,
    required this.cargando,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayActividad = enCola > 0;
    return AppCard(
      tier: 2,
      glow: hayActividad,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: AppEyebrow('DESCARGAS')),
              AppBadge(
                text: zona.nombre.toUpperCase(),
                color: c.brand,
                size: AppBadgeSize.sm,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                cargando ? '—' : '$enCola',
                style: AppType.mega.copyWith(
                  fontSize: 72,
                  color: hayActividad ? c.text : c.textMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  children: [
                    AppDot(
                      hayActividad ? c.success : c.textMuted,
                      size: 7,
                      glow: hayActividad,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'descargando ahora',
                      style: AppType.monoSm.copyWith(color: c.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ACCIONES · gestionar zonas + rango (chip mono)
// =============================================================================

class _Acciones extends StatelessWidget {
  final DateTime desde;
  final DateTime hasta;
  final VoidCallback onRango;
  final VoidCallback onGestionarZonas;
  const _Acciones({
    required this.desde,
    required this.hasta,
    required this.onRango,
    required this.onGestionarZonas,
  });

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        // Chip de rango — tappeable, muestra el rango actual en mono.
        Expanded(
          child: InkWell(
            onTap: onRango,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md, vertical: 10),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(AppRadius.lg),
                border: Border.all(color: c.border),
              ),
              child: Row(
                children: [
                  Icon(Icons.date_range, size: 15, color: c.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const AppEyebrow('RANGO'),
                        const SizedBox(height: 2),
                        Text(
                          '${_fmt(desde)} → ${_fmt(hasta)}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppType.monoSm.copyWith(color: c.text),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        AppButton.secondary(
          label: 'Zonas',
          icon: Icons.tune,
          size: AppButtonSize.sm,
          onPressed: onGestionarZonas,
        ),
      ],
    );
  }
}

class _SinZonas extends StatelessWidget {
  const _SinZonas();

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.add_location_alt_outlined,
      title: 'No hay zonas de descarga cargadas',
      subtitle: 'Cargá la primera zona (por ej. YPF Añelo) para que el '
          'sistema empiece a detectar entradas y salidas.',
      action: AppButton(
        label: 'Cargar zona',
        icon: Icons.add,
        onPressed: () =>
            Navigator.pushNamed(context, AppRoutes.adminZonasDescarga),
      ),
    );
  }
}

class _SelectorZona extends StatelessWidget {
  final List<ZonaDescarga> zonas;
  final String seleccionada;
  final ValueChanged<String> onChanged;
  const _SelectorZona({
    required this.zonas,
    required this.seleccionada,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final z in zonas)
          AppFilterChip(
            label: z.nombre,
            count: z.estadiaMinMin,
            activo: z.slug == seleccionada,
            onTap: () => onChanged(z.slug),
          ),
      ],
    );
  }
}

// ─── KPIs ─────────────────────────────────────────────────────────

class _KpisZona extends StatefulWidget {
  final String slug;
  final DateTime desde;
  final DateTime hasta;
  const _KpisZona({
    required this.slug,
    required this.desde,
    required this.hasta,
  });

  @override
  State<_KpisZona> createState() => _KpisZonaState();
}

class _KpisZonaState extends State<_KpisZona> {
  late Future<QuerySnapshot<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _cargar();
  }

  @override
  void didUpdateWidget(covariant _KpisZona old) {
    super.didUpdateWidget(old);
    if (old.slug != widget.slug ||
        old.desde != widget.desde ||
        old.hasta != widget.hasta) {
      _future = _cargar();
    }
  }

  // `.get()` one-shot + límite defensivo. Antes era `.snapshots()` (listener
  // permanente) SIN límite sobre el histórico del rango — y el date-picker
  // llega a 365 días (auditoría 2026-05-30). Los KPIs son un resumen, no
  // necesitan ser live; se recalculan al cambiar zona/rango (didUpdateWidget).
  Future<QuerySnapshot<Map<String, dynamic>>> _cargar() {
    return FirebaseFirestore.instance
        .collection(AppCollections.zonaDescargaHistorico)
        .where('slug_zona', isEqualTo: widget.slug)
        .where('entrada_ts',
            isGreaterThanOrEqualTo: Timestamp.fromDate(widget.desde))
        .where('entrada_ts',
            isLessThanOrEqualTo: Timestamp.fromDate(widget.hasta))
        .limit(5000)
        .get();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
      future: _future,
      builder: (ctx, snap) {
        final cargando = snap.connectionState == ConnectionState.waiting;
        final docs = snap.data?.docs ?? const [];
        final count = docs.length;
        var sum = 0;
        int maxDur = 0;
        String maxPat = '';
        for (final d in docs) {
          final dur = ((d.data()['duracion_min'] ?? 0) as num).toInt();
          sum += dur;
          if (dur > maxDur) {
            maxDur = dur;
            maxPat = (d.data()['patente'] ?? '').toString();
          }
        }
        final promedio = count > 0 ? (sum / count).round() : 0;
        return AppKpiStrip(
          stats: [
            AppStat(
              label: 'Descargas',
              value: cargando ? '—' : '$count',
              valueStyle: AppType.h3,
            ),
            AppStat(
              label: 'Promedio',
              value: cargando ? '—' : (count > 0 ? '$promedio' : '—'),
              unit: count > 0 ? 'min' : null,
              valueStyle: AppType.h3,
            ),
            AppStat(
              label: maxPat.isEmpty ? 'Más lenta' : 'Más lenta',
              value: cargando ? '—' : (maxDur > 0 ? '$maxDur' : '—'),
              unit: maxDur > 0 ? 'min' : null,
              valueStyle: AppType.h3,
              accent: maxDur > 90 ? c.error : null,
              delta: maxPat.isEmpty ? null : maxPat,
              deltaColor: c.textMuted,
            ),
          ],
        );
      },
    );
  }
}

// ─── Cola en vivo ────────────────────────────────────────────────

class _ColaEnVivo extends StatelessWidget {
  final ZonaDescarga zona;
  final bool cargando;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  const _ColaEnVivo({
    required this.zona,
    required this.cargando,
    required this.docs,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppDot(c.success, size: 7, glow: docs.isNotEmpty),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppEyebrow('COLA EN VIVO · ${zona.nombre}',
                    color: c.success),
              ),
              if (!cargando)
                Text(
                  '${docs.length}',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          if (cargando)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: c.brand),
                ),
              ),
            )
          else if (docs.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                'No hay unidades en la zona ahora',
                style: AppType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            for (var i = 0; i < docs.length; i++) ...[
              if (i > 0) ...[
                const SizedBox(height: AppSpacing.md),
                const AppHairline(),
                const SizedBox(height: AppSpacing.md),
              ],
              _FilaCola(
                posicion: i + 1,
                data: docs[i].data(),
                estadiaMinMin: zona.estadiaMinMin,
              ),
            ],
        ],
      ),
    );
  }
}

class _FilaCola extends StatelessWidget {
  final int posicion;
  final Map<String, dynamic> data;
  final int estadiaMinMin;
  const _FilaCola({
    required this.posicion,
    required this.data,
    required this.estadiaMinMin,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final entrada = (data['entrada_ts'] as Timestamp?)?.toDate();
    final ahora = DateTime.now();
    final minDentro =
        entrada == null ? 0 : ahora.difference(entrada).inMinutes;
    final cumple = minDentro >= estadiaMinMin;
    final patente = (data['patente'] ?? '?').toString();
    final chofer = (data['chofer_nombre'] ?? '').toString().trim();
    final dni = (data['chofer_dni'] ?? '').toString();
    // Color de la posición: #1 en brand (la que más tiempo lleva), las
    // primeras 3 en warning, el resto muted. Es jerarquía visual, no estado.
    final colorPos = posicion == 1
        ? c.brand
        : (posicion <= 3 ? c.warning : c.textMuted);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Posición en círculo mono.
        Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: colorPos.withValues(alpha: 0.14),
            shape: BoxShape.circle,
            border: Border.all(color: colorPos.withValues(alpha: 0.5)),
          ),
          child: Text(
            '$posicion',
            style: AppType.monoSm.copyWith(
              color: colorPos,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    patente,
                    style: AppType.mono.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      chofer.isNotEmpty ? chofer : '(sin chofer iButton)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodySm.copyWith(
                        color: chofer.isNotEmpty ? c.text : c.textMuted,
                        fontStyle:
                            chofer.isNotEmpty ? null : FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                [
                  _textoTiempo(minDentro),
                  if (entrada != null)
                    'entró ${AppFormatters.formatearFechaHoraSinSegundos(entrada)}',
                  if (dni.isNotEmpty) 'DNI $dni',
                ].join('  ·  '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // Estado de estadía: si todavía no cumple la mínima, badge "esperando".
        if (cumple)
          AppBadge(
            text: 'EN ZONA',
            color: c.success,
            dot: true,
            size: AppBadgeSize.sm,
          )
        else
          Tooltip(
            message: 'Aún no cumple estadía mínima ($estadiaMinMin min). '
                'Si se va antes no se cuenta como descarga.',
            child: AppBadge(
              text: 'ESPERANDO',
              color: c.textMuted,
              size: AppBadgeSize.sm,
            ),
          ),
      ],
    );
  }

  String _textoTiempo(int min) {
    if (min < 60) return 'Hace $min min';
    final h = min ~/ 60;
    final m = min % 60;
    return 'Hace ${h}h ${m}m';
  }
}

// ─── Descargas del rango (histórico filtrado) ────────────────────

class _DescargasDelRango extends StatelessWidget {
  final String slug;
  final DateTime desde;
  final DateTime hasta;
  const _DescargasDelRango({
    required this.slug,
    required this.desde,
    required this.hasta,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      // Filtra por ENTRADA en el rango (cuándo empezó la descarga).
      // Si una descarga empezó dentro pero terminó después de "hasta",
      // igual aparece — útil para "qué descargas hubo en este turno"
      // sin perder las que se extendieron al siguiente.
      stream: FirebaseFirestore.instance
          .collection(AppCollections.zonaDescargaHistorico)
          .where('slug_zona', isEqualTo: slug)
          .where('entrada_ts',
              isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
          .where('entrada_ts',
              isLessThanOrEqualTo: Timestamp.fromDate(hasta))
          .orderBy('entrada_ts', descending: true)
          .limit(500)
          .snapshots(),
      builder: (ctx, snap) {
        final cargando = snap.connectionState == ConnectionState.waiting;
        final docs = snap.data?.docs ?? const [];
        return AppCard(
          tier: 2,
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.history, size: 15, color: c.textMuted),
                  const SizedBox(width: AppSpacing.sm),
                  const Expanded(child: AppEyebrow('DESCARGAS DEL RANGO')),
                  if (!cargando)
                    Text(
                      '${docs.length}',
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              if (cargando)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: c.brand),
                    ),
                  ),
                )
              else if (docs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Text(
                    'Sin descargas en el rango seleccionado',
                    style: AppType.bodySm.copyWith(color: c.textMuted),
                  ),
                )
              else
                for (var i = 0; i < docs.length; i++) ...[
                  if (i > 0) ...[
                    const SizedBox(height: AppSpacing.md),
                    const AppHairline(),
                    const SizedBox(height: AppSpacing.md),
                  ],
                  _FilaHistorico(data: docs[i].data()),
                ],
            ],
          ),
        );
      },
    );
  }
}

class _FilaHistorico extends StatelessWidget {
  final Map<String, dynamic> data;
  const _FilaHistorico({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final patente = (data['patente'] ?? '?').toString();
    final chofer = (data['chofer_nombre'] ?? '').toString().trim();
    final dur = ((data['duracion_min'] ?? 0) as num).toInt();
    final entrada = (data['entrada_ts'] as Timestamp?)?.toDate();
    final salida = (data['salida_ts'] as Timestamp?)?.toDate();
    final colorDur =
        dur > 90 ? c.error : (dur > 60 ? c.warning : c.success);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    patente,
                    style: AppType.mono.copyWith(
                      color: c.text,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      chofer.isNotEmpty ? chofer : '(sin chofer iButton)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodySm.copyWith(
                        color: chofer.isNotEmpty ? c.text : c.textMuted,
                        fontStyle:
                            chofer.isNotEmpty ? null : FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                [
                  if (entrada != null)
                    'Entró ${AppFormatters.formatearFechaHoraSinSegundos(entrada)}',
                  if (salida != null)
                    'Salió ${AppFormatters.formatearFechaHoraSinSegundos(salida)}',
                ].join('  ·  '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        // Duración como pill semántica: verde < 60, ámbar 60-90, coral > 90.
        AppBadge(
          text: '$dur min',
          color: colorDur,
          size: AppBadgeSize.sm,
        ),
      ],
    );
  }
}
