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
class AdminDescargasPtoScreen extends StatefulWidget {
  const AdminDescargasPtoScreen({super.key});

  @override
  State<AdminDescargasPtoScreen> createState() =>
      _AdminDescargasPtoScreenState();
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
          final visibles = _filtroPatente == null
              ? docs
              : docs
                  .where((d) =>
                      (d.data()['patente'] ?? '').toString() ==
                      _filtroPatente)
                  .toList();

          if (visibles.isEmpty) {
            return _bodyConToolbar(
              cantTotal: docs.length,
              cantVisibles: 0,
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
            cantVisibles: visibles.length,
            patentes: patentes,
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 80),
              itemCount: visibles.length,
              itemBuilder: (_, i) => _EventoPtoCard(
                data: visibles[i].data(),
              ),
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
    required List<String> patentes,
    required Widget child,
  }) {
    return Column(
      children: [
        _Toolbar(
          totalEventos: cantTotal,
          visibles: cantVisibles,
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
          Text(
            totalEventos == 0
                ? 'Sin eventos en este período'
                : '$visibles de $totalEventos descargas',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
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
  final Map<String, dynamic> data;

  const _EventoPtoCard({required this.data});

  @override
  Widget build(BuildContext context) {
    final creado = (data['creado_en'] as Timestamp?)?.toDate();
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
              if (creado != null)
                Text(
                  AppFormatters.formatearFechaHoraSinSegundos(creado),
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
