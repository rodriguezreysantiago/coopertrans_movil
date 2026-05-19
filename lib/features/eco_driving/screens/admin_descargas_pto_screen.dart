import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Pantalla "Descargas por unidad" — lista de eventos PTO (toma de fuerza)
/// del Vehicle Alerts API.
///
/// En la flota de Coopertrans, un evento PTO = batea levantada para
/// descargar carga. Cada evento queda registrado por Volvo con
/// timestamp, geo-coords, patente y un snapshot del chofer asignado.
///
/// **Iteración 2026-05-04**: el calendario ahora soporta tanto un
/// día específico como un rango (1/4 al 15/4). El toolbar siempre
/// queda visible aunque no haya datos del período — Santiago reportó
/// que cuando elegía un día sin PTO el calendario desaparecía y no
/// podía cambiar de fecha.
///
/// **Iteración 2026-05-19**: dedup client-side por (patente, ventana
/// de 15 min). Santiago reportó "no repetir tantas iguales si son
/// dentro de los mismos minutos". La PTO toggea on/off varias veces
/// en una misma descarga física (chofer subiendo y bajando la batea),
/// y Volvo manda un evento por cada activación. Agrupamos para que
/// el listado refleje "descargas" reales y no "activaciones de PTO".
class AdminDescargasPtoScreen extends StatefulWidget {
  const AdminDescargasPtoScreen({super.key});

  @override
  State<AdminDescargasPtoScreen> createState() =>
      _AdminDescargasPtoScreenState();
}

/// Ventana para agrupar eventos PTO consecutivos de la misma patente.
/// 15 min cubre toggles típicos de una descarga (subir/bajar batea, hueco
/// para reacomodar el camión) sin pegar dos descargas reales distintas
/// (cargar en cliente A → ir a cliente B suele tomar >> 15 min).
const Duration _ventanaDedupPto = Duration(minutes: 15);

/// Agrupa eventos por (patente, ventana de tiempo). Devuelve grupos
/// ordenados del más reciente al más viejo (por primer evento del grupo).
List<_GrupoPto> _agruparPorPatenteYVentana(
  List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
) {
  if (docs.isEmpty) return const [];
  // docs vienen ordenados por `creado_en` DESC (query). Para agrupar
  // necesitamos pasar por cada patente individualmente.
  final porPatente = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
  for (final d in docs) {
    final patente = (d.data()['patente'] ?? '').toString();
    final key = patente.isEmpty ? '(sin patente)' : patente;
    (porPatente[key] ??= []).add(d);
  }

  final grupos = <_GrupoPto>[];
  for (final entry in porPatente.entries) {
    // Lista ya en DESC dentro de cada patente (lo heredamos del orden
    // global). La invertimos para procesar cronológicamente y agrupar.
    final ascendente = entry.value.reversed.toList();
    _GrupoPto? actual;
    for (final doc in ascendente) {
      final ts = (doc.data()['creado_en'] as Timestamp?)?.toDate();
      if (ts == null) continue;
      if (actual == null ||
          ts.difference(actual.ultimoTs).abs() > _ventanaDedupPto) {
        actual = _GrupoPto(
          patente: entry.key,
          primero: doc,
          eventos: [doc],
          primerTs: ts,
          ultimoTs: ts,
        );
        grupos.add(actual);
      } else {
        actual.eventos.add(doc);
        actual.ultimoTs = ts;
      }
    }
  }
  // Orden final por primer evento DESC (más reciente arriba).
  grupos.sort((a, b) => b.primerTs.compareTo(a.primerTs));
  return grupos;
}

class _GrupoPto {
  final String patente;
  final QueryDocumentSnapshot<Map<String, dynamic>> primero;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> eventos;
  final DateTime primerTs;
  DateTime ultimoTs;

  _GrupoPto({
    required this.patente,
    required this.primero,
    required this.eventos,
    required this.primerTs,
    required this.ultimoTs,
  });

  int get cantidad => eventos.length;
  bool get esAgrupado => eventos.length > 1;
  Duration get duracion => ultimoTs.difference(primerTs);
}

class _AdminDescargasPtoScreenState extends State<AdminDescargasPtoScreen> {
  /// Rango seleccionado. `start == end` (mismo día) representa una
  /// fecha única — la UI lo etiqueta diferente. Default: hoy/hoy.
  late DateTimeRange _rango;
  String? _filtroPatente;

  @override
  void initState() {
    super.initState();
    final hoy = _truncarDia(DateTime.now());
    _rango = DateTimeRange(start: hoy, end: hoy);
  }

  static DateTime _truncarDia(DateTime dt) =>
      DateTime(dt.year, dt.month, dt.day);

  bool get _esHoy {
    final hoy = _truncarDia(DateTime.now());
    return _rango.start == hoy && _rango.end == hoy;
  }

  bool get _esUnDia => _rango.start == _rango.end;

  String get _etiquetaFecha {
    String fmt(DateTime d) =>
        '${d.day.toString().padLeft(2, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-${d.year}';
    if (_esHoy) return 'HOY (${fmt(_rango.start)})';
    if (_esUnDia) return fmt(_rango.start);
    return '${fmt(_rango.start)} al ${fmt(_rango.end)}';
  }

  /// Inicio del rango como Timestamp (00:00:00 del día start).
  Timestamp get _desdeTs => Timestamp.fromDate(_rango.start);

  /// Fin EXCLUSIVO del rango: 00:00 del día siguiente al end. Eso
  /// incluye todo el día `end` completo en la query `< _hastaTs`.
  Timestamp get _hastaTs =>
      Timestamp.fromDate(_rango.end.add(const Duration(days: 1)));

  Future<void> _elegirFecha() async {
    final ahora = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: _rango,
      firstDate: DateTime(2024),
      lastDate: _truncarDia(ahora),
      helpText: 'Elegir fecha o rango de descargas',
      cancelText: 'CANCELAR',
      confirmText: 'VER',
      saveText: 'VER',
      locale: const Locale('es', 'AR'),
    );
    if (picked != null && mounted) {
      setState(() {
        _rango = DateTimeRange(
          start: _truncarDia(picked.start),
          end: _truncarDia(picked.end),
        );
        _filtroPatente = null;
      });
    }
  }

  void _irAHoy() {
    final hoy = _truncarDia(DateTime.now());
    setState(() {
      _rango = DateTimeRange(start: hoy, end: hoy);
      _filtroPatente = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Descargas (PTO)',
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(AppCollections.volvoAlertas)
            .where('tipo', isEqualTo: 'PTO')
            .where('creado_en', isGreaterThanOrEqualTo: _desdeTs)
            .where('creado_en', isLessThan: _hastaTs)
            .orderBy('creado_en', descending: true)
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return _bodyConToolbar(
              cantTotal: 0,
              cantVisibles: 0,
              cantGrupos: 0,
              patentes: const [],
              child: AppErrorState(
                title: 'No pudimos cargar las descargas',
                subtitle: snap.error.toString(),
              ),
            );
          }
          if (snap.connectionState == ConnectionState.waiting) {
            return _bodyConToolbar(
              cantTotal: 0,
              cantVisibles: 0,
              cantGrupos: 0,
              patentes: const [],
              child: const Center(
                child:
                    CircularProgressIndicator(color: AppColors.accentGreen),
              ),
            );
          }
          final docs = snap.data?.docs ?? const [];
          // Patentes únicas para el filtro (calculadas siempre, aunque
          // la lista esté vacía — mantiene el toolbar consistente).
          final patentes = <String>{
            for (final d in docs)
              if ((d.data()['patente'] ?? '').toString().isNotEmpty)
                d.data()['patente'].toString()
          }.toList()
            ..sort();
          // Filtrar in-memory por patente si hay filtro.
          final visiblesDocs = _filtroPatente == null
              ? docs
              : docs
                  .where((d) =>
                      (d.data()['patente'] ?? '').toString() ==
                      _filtroPatente)
                  .toList();
          // Dedup: agrupamos eventos consecutivos de la misma patente
          // dentro de `_ventanaDedupPto`. Cada grupo = una "descarga".
          final grupos = _agruparPorPatenteYVentana(visiblesDocs);

          if (grupos.isEmpty) {
            return _bodyConToolbar(
              cantTotal: docs.length,
              cantVisibles: 0,
              cantGrupos: 0,
              patentes: patentes,
              child: AppEmptyState(
                icon: Icons.local_shipping_outlined,
                title: docs.isEmpty
                    ? 'Sin descargas en $_etiquetaFecha'
                    : 'Sin descargas para esa patente',
                subtitle: docs.isEmpty
                    ? (_esHoy
                        ? 'Todavía no hubo eventos PTO hoy. Probá con otro día o un rango.'
                        : 'No hay eventos PTO en ese período. Elegí otra fecha o rango.')
                    : 'Cambiá el filtro de patente o ampliá el rango.',
              ),
            );
          }
          return _bodyConToolbar(
            cantTotal: docs.length,
            cantVisibles: visiblesDocs.length,
            cantGrupos: grupos.length,
            patentes: patentes,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
              itemCount: grupos.length,
              itemBuilder: (_, i) => _EventoPtoCard(grupo: grupos[i]),
            ),
          );
        },
      ),
    );
  }

  /// Helper que envuelve cualquier estado del body con el toolbar
  /// arriba — clave para que el calendario / filtros sigan siendo
  /// accesibles aunque la lista esté vacía o haya error.
  Widget _bodyConToolbar({
    required int cantTotal,
    required int cantVisibles,
    required int cantGrupos,
    required List<String> patentes,
    required Widget child,
  }) {
    return Column(
      children: [
        _Toolbar(
          totalEventos: cantTotal,
          visibles: cantVisibles,
          grupos: cantGrupos,
          patentes: patentes,
          filtroPatente: _filtroPatente,
          onFiltroChange: (p) => setState(() => _filtroPatente = p),
          etiquetaFecha: _etiquetaFecha,
          esHoy: _esHoy,
          onElegirFecha: _elegirFecha,
          onIrAHoy: _irAHoy,
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  final int totalEventos;
  final int visibles;
  final int grupos;
  final List<String> patentes;
  final String? filtroPatente;
  final ValueChanged<String?> onFiltroChange;
  final String etiquetaFecha;
  final bool esHoy;
  final VoidCallback onElegirFecha;
  final VoidCallback onIrAHoy;

  const _Toolbar({
    required this.totalEventos,
    required this.visibles,
    required this.grupos,
    required this.patentes,
    required this.filtroPatente,
    required this.onFiltroChange,
    required this.etiquetaFecha,
    required this.esHoy,
    required this.onElegirFecha,
    required this.onIrAHoy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Selector de fecha / rango — siempre visible. Tap abre
          // showDateRangePicker (un solo día = elegir mismo desde y
          // hasta).
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: onElegirFecha,
                icon:
                    const Icon(Icons.calendar_month_outlined, size: 18),
                label: Text(etiquetaFecha),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(
                    color: esHoy
                        ? AppColors.accentGreen
                        : Colors.white38,
                  ),
                ),
              ),
              if (!esHoy)
                TextButton.icon(
                  onPressed: onIrAHoy,
                  icon: const Icon(Icons.today_outlined, size: 18),
                  label: const Text('Ir a hoy'),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.accentGreen,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  totalEventos == 0
                      ? 'Sin eventos en este período'
                      : grupos == visibles
                          ? '$visibles de $totalEventos eventos PTO'
                          : '$grupos descargas ($visibles eventos agrupados '
                              'de $totalEventos)',
                  style:
                      const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
              // Botón "?" — abre cobertura PTO: cuántos Volvos reportaron
              // en este período vs cuántos hay en la flota. Útil para
              // saber si alguna unidad no tiene el sensor de PTO activado
              // en Volvo Connect.
              TextButton.icon(
                onPressed: () => _mostrarCoberturaPto(context, patentes),
                icon: const Icon(Icons.help_outline, size: 16),
                label: const Text('Cobertura'),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.accentBlue,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  visualDensity: VisualDensity.compact,
                  minimumSize: const Size(0, 30),
                ),
              ),
            ],
          ),
          // Filtro de patente solo se muestra si hay docs (sino chips
          // vacíos no aportan).
          if (patentes.isNotEmpty) ...[
            const SizedBox(height: 8),
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _ChipFiltro(
                    label: 'TODAS',
                    selected: filtroPatente == null,
                    onTap: () => onFiltroChange(null),
                  ),
                  const SizedBox(width: 6),
                  ...patentes.map((p) => Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _ChipFiltro(
                          label: p,
                          selected: filtroPatente == p,
                          onTap: () => onFiltroChange(p),
                        ),
                      )),
                ],
              ),
            ),
          ],
        ],
      ),
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
    final color = selected ? AppColors.accentGreen : Colors.white38;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentGreen.withAlpha(25)
              : Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: color.withAlpha(80)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}

class _EventoPtoCard extends StatelessWidget {
  final _GrupoPto grupo;

  const _EventoPtoCard({required this.grupo});

  /// Devuelve "HH:mm – HH:mm" si el grupo dura > 1 min, sino "HH:mm".
  String _rangoHorario() {
    final p = grupo.primerTs;
    final u = grupo.ultimoTs;
    String hhmm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
    if (grupo.duracion.inMinutes <= 0) {
      return AppFormatters.formatearFechaHoraSinSegundos(p);
    }
    final fechaDia = '${p.day.toString().padLeft(2, '0')}-'
        '${p.month.toString().padLeft(2, '0')}-${p.year}';
    return '$fechaDia · ${hhmm(p)} – ${hhmm(u)}';
  }

  @override
  Widget build(BuildContext context) {
    final data = grupo.primero.data();
    final patente = (data['patente'] ?? '—').toString();
    final choferNombre = (data['chofer_nombre'] ?? '').toString();
    final choferDni = (data['chofer_dni'] ?? '').toString();
    final chofer = choferNombre.isNotEmpty
        ? choferNombre
        : choferDni.isNotEmpty
            ? 'DNI $choferDni'
            : 'Chofer no asignado';

    final gps = data['posicion_gps'] as Map<String, dynamic>?;
    final lat = (gps?['lat'] as num?)?.toDouble();
    final lng = (gps?['lng'] as num?)?.toDouble();

    final detalle = data['detalle_pto'] as Map<String, dynamic>?;

    return AppCard(
      borderColor: AppColors.accentGreen.withAlpha(40),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_shipping,
                  color: AppColors.accentGreen, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  patente,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (grupo.esAgrupado)
                Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentGreen.withAlpha(40),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.accentGreen.withAlpha(80),
                    ),
                  ),
                  child: Text(
                    'x${grupo.cantidad}',
                    style: const TextStyle(
                      color: AppColors.accentGreen,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              Text(
                _rangoHorario(),
                style: const TextStyle(
                    color: Colors.white54, fontSize: 11),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.person_outline,
                  color: Colors.white60, size: 14),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  chofer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
          if (detalle != null) ...[
            const SizedBox(height: 6),
            _detalleRow('Duración',
                '${detalle['duracion_segundos'] ?? '—'} segundos'),
            _detalleRow('Modo', (detalle['modo'] ?? '—').toString()),
          ],
          if (lat != null && lng != null) ...[
            const SizedBox(height: 8),
            InkWell(
              onTap: () => _abrirMapa(lat, lng),
              child: Row(
                children: [
                  const Icon(Icons.location_on_outlined,
                      color: AppColors.accentBlue, size: 14),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      'Ver en Google Maps · '
                      '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 11,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detalleRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: Colors.white54, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style:
                  const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _abrirMapa(double lat, double lng) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }
}

/// Abre un bottom sheet con la cobertura de PTO: cuántos Volvos
/// reportaron en este período vs cuántos hay en la flota. Si alguno no
/// reportó, lo lista — Santiago puede confirmar si es esperable (camión
/// en taller, sin batea) o pedir alta del sensor PTO en Volvo Connect.
void _mostrarCoberturaPto(BuildContext context, List<String> patentesQueReportaron) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (sCtx) => _CoberturaPtoSheet(
      patentesQueReportaron: patentesQueReportaron.toSet(),
    ),
  );
}

class _CoberturaPtoSheet extends StatelessWidget {
  final Set<String> patentesQueReportaron;

  const _CoberturaPtoSheet({required this.patentesQueReportaron});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: 0.7,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: FutureBuilder<QuerySnapshot<Map<String, dynamic>>>(
          // Solo Volvos — los otros tractores no tienen Vehicle Alerts
          // API conectada, así que no se puede saber si tienen PTO.
          future: FirebaseFirestore.instance
              .collection(AppCollections.vehiculos)
              .where('MARCA', isEqualTo: 'VOLVO')
              .get(),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                child: CircularProgressIndicator(
                    color: AppColors.accentGreen),
              );
            }
            if (snap.hasError) {
              return Center(
                child: Text(
                  'No pudimos cargar la flota Volvo:\n${snap.error}',
                  style: const TextStyle(color: Colors.white70),
                ),
              );
            }
            final docs = snap.data?.docs ?? const [];
            // Solo Volvos activos (no dados de baja).
            final volvosActivos = <String>[];
            for (final d in docs) {
              final patente = d.id.toUpperCase();
              final activo = (d.data()[AppActivo.campo] ?? true) as bool;
              if (activo && patente.isNotEmpty) {
                volvosActivos.add(patente);
              }
            }
            volvosActivos.sort();
            final reportaron = volvosActivos
                .where((p) => patentesQueReportaron.contains(p))
                .toList();
            final noReportaron = volvosActivos
                .where((p) => !patentesQueReportaron.contains(p))
                .toList();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.help_outline,
                        color: AppColors.accentBlue, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Cobertura PTO en el período',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white70),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.accentBlue.withAlpha(20),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: AppColors.accentBlue.withAlpha(60),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${reportaron.length} de ${volvosActivos.length} Volvos reportaron PTO',
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              noReportaron.isEmpty
                                  ? 'Todas las unidades Volvo reportaron al menos un evento.'
                                  : '${noReportaron.length} unidades sin eventos PTO en el período.',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Importante: que una unidad no reporte PTO puede ser '
                  'porque (a) no salió a descargar en el período, '
                  '(b) el sensor de PTO no está conectado / habilitado en '
                  'Volvo Connect, o (c) es un tractor sin batea (capacidad '
                  'distinta). Verificá en taller antes de pedir alta.',
                  style: TextStyle(color: Colors.white60, fontSize: 11),
                ),
                const SizedBox(height: 12),
                if (noReportaron.isNotEmpty) ...[
                  const Text(
                    'No reportaron en este período:',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ListView(
                      children: noReportaron
                          .map((p) => Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 3),
                                child: Row(
                                  children: [
                                    const Icon(Icons.remove_circle_outline,
                                        color: Colors.orangeAccent,
                                        size: 14),
                                    const SizedBox(width: 8),
                                    Text(
                                      p,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontFamily: 'monospace',
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ] else ...[
                  const Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.check_circle_outline,
                            color: AppColors.accentGreen,
                            size: 48,
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Cobertura total',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}
