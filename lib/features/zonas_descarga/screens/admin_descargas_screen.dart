import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/zona_descarga.dart';
import '../services/zonas_descarga_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Módulo "Descargas" — cola en vivo + recién descargaron + KPIs.
///
/// Reemplazó al detector PTO Volvo (eliminado 2026-05-24) que daba
/// falsos positivos y solo cubría flota Volvo. Ahora el dato viene de
/// presencia REAL en geocercas configurables (`ZONAS_DESCARGA`) que la
/// CF `zonaDescargaPoller` cruza con Sitrack — cubre la flota completa.
///
/// Para que funcione tienen que estar cargadas las zonas desde
/// "Zonas de descarga" (admin). Si no hay zonas → pantalla vacía con
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
            return const Center(child: CircularProgressIndicator());
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Acceso permanente al CRUD de zonas — visible aunque ya
              // haya zonas cargadas. Sin esto, una vez que existe la
              // primera zona el _SinZonas (con su CTA "Cargar zona")
              // desaparece y no quedaba forma de crear/editar/desactivar
              // más zonas desde acá.
              _BotonGestionarZonas(
                onTap: () => Navigator.pushNamed(
                    context, AppRoutes.adminZonasDescarga),
              ),
              if (zonas.length > 1)
                _SelectorZona(
                  zonas: zonas,
                  seleccionada: zonaActual.slug,
                  onChanged: (s) =>
                      setState(() => _slugSeleccionado = s),
                ),
              _BotonRango(
                desde: _desde,
                hasta: _hasta,
                onTap: _elegirRango,
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  children: [
                    _KpisZona(
                      slug: zonaActual.slug,
                      desde: _desde,
                      hasta: _hasta,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _ColaEnVivo(zona: zonaActual),
                    const SizedBox(height: AppSpacing.lg),
                    _DescargasDelRango(
                      slug: zonaActual.slug,
                      desde: _desde,
                      hasta: _hasta,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Botón único con el rango actual visible. Tap → date range picker.
class _BotonRango extends StatelessWidget {
  final DateTime desde;
  final DateTime hasta;
  final VoidCallback onTap;
  const _BotonRango({
    required this.desde,
    required this.hasta,
    required this.onTap,
  });

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppColors.brand.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(
              color: AppColors.brand.withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.date_range,
                  color: AppColors.brand, size: 22),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'RANGO DE DESCARGAS',
                      style: TextStyle(
                        color: AppColors.brand,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmt(desde)} → ${_fmt(hasta)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.calendar_today,
                  color: Colors.white54, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class _SinZonas extends StatelessWidget {
  const _SinZonas();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_location_alt_outlined,
                color: Colors.white24, size: 72),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'No hay zonas de descarga cargadas',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Cargá la primera zona (por ej. YPF Añelo) para que el '
              'sistema empiece a detectar entradas y salidas.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => Navigator.pushNamed(
                  context, AppRoutes.adminZonasDescarga),
              icon: const Icon(Icons.add),
              label: const Text('Cargar zona'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.brand,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Botón compacto arriba a la derecha — acceso permanente al CRUD de
/// zonas (`AdminZonasDescargaScreen`). Se renderiza siempre que hay
/// al menos una zona; cuando no hay ninguna, el `_SinZonas` cubre el
/// caso con su propio CTA.
class _BotonGestionarZonas extends StatelessWidget {
  final VoidCallback onTap;
  const _BotonGestionarZonas({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: OutlinedButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Gestionar zonas'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.brand,
            side: BorderSide(
              color: AppColors.brand.withValues(alpha: 0.5),
            ),
            padding: const EdgeInsets.symmetric(
                horizontal: 14, vertical: 8),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: 8,
        children: zonas
            .map((z) => ChoiceChip(
                  label: Text(z.nombre),
                  selected: z.slug == seleccionada,
                  onSelected: (_) => onChanged(z.slug),
                ))
            .toList(),
      ),
    );
  }
}

// ─── KPIs ─────────────────────────────────────────────────────────

class _KpisZona extends StatelessWidget {
  final String slug;
  final DateTime desde;
  final DateTime hasta;
  const _KpisZona({
    required this.slug,
    required this.desde,
    required this.hasta,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.zonaDescargaHistorico)
          .where('slug_zona', isEqualTo: slug)
          .where('entrada_ts',
              isGreaterThanOrEqualTo: Timestamp.fromDate(desde))
          .where('entrada_ts',
              isLessThanOrEqualTo: Timestamp.fromDate(hasta))
          .snapshots(),
      builder: (ctx, snap) {
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
        return Row(
          children: [
            _KpiCard(
              label: 'Descargas',
              valor: '$count',
              color: AppColors.info,
              icon: Icons.local_shipping,
            ),
            const SizedBox(width: AppSpacing.sm),
            _KpiCard(
              label: 'Promedio',
              valor: '$promedio min',
              color: AppColors.warning,
              icon: Icons.timer,
            ),
            const SizedBox(width: AppSpacing.sm),
            _KpiCard(
              label: maxPat.isEmpty ? 'Más lenta' : 'Más lenta · $maxPat',
              valor: maxDur > 0 ? '$maxDur min' : '—',
              color: AppColors.error,
              icon: Icons.priority_high,
            ),
          ],
        );
      },
    );
  }
}

class _KpiCard extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;
  final IconData icon;
  const _KpiCard({
    required this.label,
    required this.valor,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 6),
            Text(valor,
                style: TextStyle(
                    color: color,
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(
                    color: Colors.white60, fontSize: 11)),
          ],
        ),
      ),
    );
  }
}

// ─── Cola en vivo ────────────────────────────────────────────────

class _ColaEnVivo extends StatelessWidget {
  final ZonaDescarga zona;
  const _ColaEnVivo({required this.zona});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.queue, color: AppColors.success, size: 18),
            const SizedBox(width: 6),
            Text(
              'COLA EN VIVO — ${zona.nombre.toUpperCase()}',
              style: const TextStyle(
                  color: AppColors.success,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.zonaDescargaCola)
              .where('slug_zona', isEqualTo: zona.slug)
              .snapshots(),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final docs = (snap.data?.docs ?? const []).toList()
              ..sort((a, b) {
                final ta = (a.data()['entrada_ts'] as Timestamp?);
                final tb = (b.data()['entrada_ts'] as Timestamp?);
                if (ta == null && tb == null) return 0;
                if (ta == null) return 1;
                if (tb == null) return -1;
                return ta.compareTo(tb);
              });
            // Filtro por estadía mínima (la cola del Firestore puede
            // incluir entradas recientes que aún no califican). Mostramos
            // todas igual pero las que no cumplen van con badge "esperando".
            if (docs.isEmpty) {
              return const AppCard(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      'No hay unidades en la zona ahora',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              );
            }
            return Column(
              children: List.generate(docs.length, (i) {
                final d = docs[i].data();
                return _FilaCola(
                  posicion: i + 1,
                  data: d,
                  estadiaMinMin: zona.estadiaMinMin,
                );
              }),
            );
          },
        ),
      ],
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
    final entrada = (data['entrada_ts'] as Timestamp?)?.toDate();
    final ahora = DateTime.now();
    final minDentro = entrada == null
        ? 0
        : ahora.difference(entrada).inMinutes;
    final cumple = minDentro >= estadiaMinMin;
    final patente = (data['patente'] ?? '?').toString();
    final chofer = (data['chofer_nombre'] ?? '').toString().trim();
    final dni = (data['chofer_dni'] ?? '').toString();
    final colorPos = posicion == 1
        ? AppColors.error
        : (posicion <= 3 ? AppColors.warning : Colors.white54);
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(
            color: colorPos.withValues(alpha: 0.5), width: 1),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: colorPos,
          child: Text(
            '#$posicion',
            style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold),
          ),
        ),
        title: Row(
          children: [
            Text(
              patente,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  letterSpacing: 1),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                chofer.isNotEmpty ? chofer : '(sin chofer iButton)',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: chofer.isNotEmpty
                      ? Colors.white70
                      : Colors.white38,
                  fontSize: 13,
                  fontStyle:
                      chofer.isNotEmpty ? null : FontStyle.italic,
                ),
              ),
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '${_textoTiempo(minDentro)}'
            '${entrada != null ? " · entró ${AppFormatters.formatearFechaHoraSinSegundos(entrada)}" : ""}'
            '${dni.isNotEmpty ? " · DNI $dni" : ""}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
        ),
        trailing: cumple
            ? null
            : Tooltip(
                message:
                    'Aún no cumple estadía mínima ($estadiaMinMin min). '
                    'Si se va antes no se cuenta como descarga.',
                child: const Icon(Icons.hourglass_empty,
                    color: Colors.white38, size: 18),
              ),
      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Row(
          children: [
            Icon(Icons.history, color: AppColors.brandSoft, size: 18),
            SizedBox(width: 6),
            Text(
              'DESCARGAS DEL RANGO',
              style: TextStyle(
                  color: AppColors.brandSoft,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
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
            if (snap.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.all(AppSpacing.xl),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            final docs = snap.data?.docs ?? const [];
            if (docs.isEmpty) {
              return const AppCard(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Center(
                    child: Text(
                      'Sin descargas en el rango seleccionado',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ),
              );
            }
            return Column(
              children: docs
                  .map((d) => _FilaHistorico(data: d.data()))
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class _FilaHistorico extends StatelessWidget {
  final Map<String, dynamic> data;
  const _FilaHistorico({required this.data});

  @override
  Widget build(BuildContext context) {
    final patente = (data['patente'] ?? '?').toString();
    final chofer = (data['chofer_nombre'] ?? '').toString().trim();
    final dur = ((data['duracion_min'] ?? 0) as num).toInt();
    final entrada = (data['entrada_ts'] as Timestamp?)?.toDate();
    final salida = (data['salida_ts'] as Timestamp?)?.toDate();
    final colorDur = dur > 90
        ? AppColors.error
        : (dur > 60 ? AppColors.warning : AppColors.success);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 2),
      color: Colors.white.withValues(alpha: 0.04),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        patente,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                            letterSpacing: 1),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          chofer.isNotEmpty
                              ? chofer
                              : '(sin chofer iButton)',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: chofer.isNotEmpty
                                ? Colors.white70
                                : Colors.white38,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (entrada != null)
                        'Entró ${AppFormatters.formatearFechaHoraSinSegundos(entrada)}',
                      if (salida != null)
                        'Salió ${AppFormatters.formatearFechaHoraSinSegundos(salida)}',
                    ].join(' · '),
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: colorDur.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: colorDur.withValues(alpha: 0.5)),
              ),
              child: Text(
                '$dur min',
                style: TextStyle(
                    color: colorDur,
                    fontWeight: FontWeight.bold,
                    fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
