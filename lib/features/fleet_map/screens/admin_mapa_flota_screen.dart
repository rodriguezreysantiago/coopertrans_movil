import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/widgets/app_widgets.dart';

/// Pantalla "Mapa flota en vivo" del admin.
///
/// Muestra la última posición conocida de TODA la flota (no solo Volvo)
/// según Sitrack — toda la flota tiene Sitrack, así que es la fuente
/// más completa para "dónde está cada tractor ahora". Volvo Vehicle
/// Alerts solo da posición cuando dispara un evento puntual.
///
/// Datos: lee de `SITRACK_POSICIONES` que la Cloud Function
/// `sitrackPosicionPoller` (cron 5 min) actualiza llamando al endpoint
/// `/v2/report` de Sitrack. El doc id es la patente, así que no
/// historizamos — es snapshot.
///
/// UX:
/// - Marker por tractor coloreado según ignición (verde si motor ON,
///   gris si OFF) y frescura del último reporte (rojo si > 1h).
/// - Tap en marker → bottom sheet con datos del tractor + chofer
///   (si está identificado por iButton) + odómetro + link a Maps.
class AdminMapaFlotaScreen extends StatefulWidget {
  const AdminMapaFlotaScreen({super.key});

  @override
  State<AdminMapaFlotaScreen> createState() => _AdminMapaFlotaScreenState();
}

class _AdminMapaFlotaScreenState extends State<AdminMapaFlotaScreen> {
  // Bahía Blanca centro — operación de Vecchi.
  static const _centroInicial = LatLng(-38.7196, -62.2724);
  static const _zoomInicial = 8.0;

  /// Filtro por estado del motor. null = todos.
  bool? _filtroIgnicionOn; // null=todos, true=ON, false=OFF
  /// Si true, oculta tractores con > 1h sin reportar.
  bool _ocultarStale = false;
  /// Si true, muestra SOLO los tractores con drift detectado.
  /// El cron del poller marca `drift_tipo` en cada doc cuando el chofer
  /// que reporta Sitrack (iButton) no coincide con la asignación activa
  /// del sistema. Útil para que el admin atienda solo los inconsistentes.
  bool _soloDrift = false;

  final _mapController = MapController();

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mapa flota en vivo',
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(AppCollections.sitrackPosiciones)
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.accentGreen),
            );
          }
          if (snap.hasError) {
            return AppErrorState(
              title: 'No pudimos cargar el mapa',
              subtitle: snap.error.toString(),
            );
          }

          final allDocs = snap.data?.docs ?? const [];
          final ahora = DateTime.now();

          // Filtros aplicados client-side (la colección es chica, ~55
          // docs; no justifica indices ni queries compuestas).
          final visibles = allDocs.where((d) {
            final data = d.data();
            final ignition = data['ignition'] == true;
            final driftTipo = (data['drift_tipo'] ?? '').toString();
            if (_soloDrift && driftTipo.isEmpty) return false;
            if (_filtroIgnicionOn != null && ignition != _filtroIgnicionOn) {
              return false;
            }
            if (_ocultarStale) {
              final reportTs = (data['report_date'] as Timestamp?)?.toDate();
              if (reportTs == null) return false;
              if (ahora.difference(reportTs).inMinutes > 60) return false;
            }
            // Tiene que tener lat/lng válidos.
            final lat = (data['lat'] as num?)?.toDouble();
            final lng = (data['lng'] as num?)?.toDouble();
            if (lat == null || lng == null) return false;
            return true;
          }).toList();

          // Conteos para la toolbar
          int conIgnicionOn = 0;
          int conIgnicionOff = 0;
          int stale = 0;
          int drifts = 0;
          for (final d in allDocs) {
            final data = d.data();
            if (data['ignition'] == true) {
              conIgnicionOn++;
            } else {
              conIgnicionOff++;
            }
            final reportTs = (data['report_date'] as Timestamp?)?.toDate();
            if (reportTs == null ||
                ahora.difference(reportTs).inMinutes > 60) {
              stale++;
            }
            if ((data['drift_tipo'] ?? '').toString().isNotEmpty) {
              drifts++;
            }
          }

          return Column(
            children: [
              _Toolbar(
                total: allDocs.length,
                conIgnicionOn: conIgnicionOn,
                conIgnicionOff: conIgnicionOff,
                stale: stale,
                drifts: drifts,
                visibles: visibles.length,
                filtroIgnicion: _filtroIgnicionOn,
                ocultarStale: _ocultarStale,
                soloDrift: _soloDrift,
                onFiltroIgnicion: (v) =>
                    setState(() => _filtroIgnicionOn = v),
                onOcultarStaleToggle: (v) =>
                    setState(() => _ocultarStale = v),
                onSoloDriftToggle: (v) => setState(() => _soloDrift = v),
              ),
              Expanded(
                child: _Mapa(
                  controller: _mapController,
                  centroInicial: _centroInicial,
                  zoomInicial: _zoomInicial,
                  docs: visibles,
                  ahora: ahora,
                  onMarkerTap: (doc) => _abrirDetalle(doc),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _abrirDetalle(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _DetalleSheet(
        patente: doc.id,
        data: doc.data(),
      ),
    );
  }
}

// =============================================================================
// TOOLBAR — chips de filtros + contadores
// =============================================================================

class _Toolbar extends StatelessWidget {
  final int total;
  final int conIgnicionOn;
  final int conIgnicionOff;
  final int stale;
  final int drifts;
  final int visibles;
  final bool? filtroIgnicion;
  final bool ocultarStale;
  final bool soloDrift;
  final ValueChanged<bool?> onFiltroIgnicion;
  final ValueChanged<bool> onOcultarStaleToggle;
  final ValueChanged<bool> onSoloDriftToggle;

  const _Toolbar({
    required this.total,
    required this.conIgnicionOn,
    required this.conIgnicionOff,
    required this.stale,
    required this.drifts,
    required this.visibles,
    required this.filtroIgnicion,
    required this.ocultarStale,
    required this.soloDrift,
    required this.onFiltroIgnicion,
    required this.onOcultarStaleToggle,
    required this.onSoloDriftToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(80),
        border: Border(
          bottom: BorderSide(color: Colors.white.withAlpha(15)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _ContadorMini(
                  label: 'TOTAL',
                  valor: '$total',
                  color: AppColors.accentBlue),
              const SizedBox(width: 12),
              _ContadorMini(
                  label: 'EN MARCHA',
                  valor: '$conIgnicionOn',
                  color: AppColors.accentGreen),
              const SizedBox(width: 12),
              _ContadorMini(
                  label: 'APAGADOS',
                  valor: '$conIgnicionOff',
                  color: Colors.white54),
              const SizedBox(width: 12),
              _ContadorMini(
                  label: '> 1H',
                  valor: '$stale',
                  color: AppColors.accentRed),
              const SizedBox(width: 12),
              _ContadorMini(
                  label: 'DRIFT',
                  valor: '$drifts',
                  color: drifts > 0
                      ? AppColors.accentOrange
                      : Colors.white38),
              const Spacer(),
              Text(
                'Mostrando $visibles',
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _ChipFiltro(
                  label: 'TODOS',
                  selected: filtroIgnicion == null,
                  onTap: () => onFiltroIgnicion(null),
                ),
                const SizedBox(width: 4),
                _ChipFiltro(
                  label: 'EN MARCHA',
                  selected: filtroIgnicion == true,
                  onTap: () => onFiltroIgnicion(true),
                ),
                const SizedBox(width: 4),
                _ChipFiltro(
                  label: 'APAGADOS',
                  selected: filtroIgnicion == false,
                  onTap: () => onFiltroIgnicion(false),
                ),
                const SizedBox(width: 12),
                _ToggleChip(
                  label: 'OCULTAR > 1H',
                  icono: Icons.timer_off_outlined,
                  activo: ocultarStale,
                  colorActivo: AppColors.accentRed,
                  onChange: onOcultarStaleToggle,
                ),
                const SizedBox(width: 4),
                _ToggleChip(
                  label: 'SOLO DRIFT',
                  icono: Icons.warning_amber_outlined,
                  activo: soloDrift,
                  colorActivo: AppColors.accentOrange,
                  onChange: onSoloDriftToggle,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ContadorMini extends StatelessWidget {
  final String label;
  final String valor;
  final Color color;

  const _ContadorMini({
    required this.label,
    required this.valor,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: color.withAlpha(180),
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
        Text(
          valor,
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
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
    final color = selected ? AppColors.accentGreen : Colors.white38;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.accentGreen.withAlpha(25)
              : Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withAlpha(80)),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final IconData icono;
  final bool activo;
  final Color colorActivo;
  final ValueChanged<bool> onChange;

  const _ToggleChip({
    required this.label,
    required this.icono,
    required this.activo,
    required this.colorActivo,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    final color = activo ? colorActivo : Colors.white54;
    return InkWell(
      onTap: () => onChange(!activo),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:
              activo ? colorActivo.withAlpha(35) : Colors.white.withAlpha(8),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withAlpha(120)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icono, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// MAPA
// =============================================================================

class _Mapa extends StatelessWidget {
  final MapController controller;
  final LatLng centroInicial;
  final double zoomInicial;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
  final DateTime ahora;
  final ValueChanged<QueryDocumentSnapshot<Map<String, dynamic>>> onMarkerTap;

  const _Mapa({
    required this.controller,
    required this.centroInicial,
    required this.zoomInicial,
    required this.docs,
    required this.ahora,
    required this.onMarkerTap,
  });

  @override
  Widget build(BuildContext context) {
    return FlutterMap(
      mapController: controller,
      options: MapOptions(
        initialCenter: centroInicial,
        initialZoom: zoomInicial,
        minZoom: 4,
        maxZoom: 18,
      ),
      children: [
        TileLayer(
          urlTemplate: MapConstants.tileUrl,
          subdomains: MapConstants.tileSubdomains,
          userAgentPackageName: MapConstants.userAgent,
        ),
        // Agrupamos pins muy cerca (radio chico de 40px) para evitar
        // superposición cuando varios tractores están en el mismo
        // predio (acopio, base operativa). A zoom alto se separan.
        MarkerClusterLayerWidget(
          options: MarkerClusterLayerOptions(
            maxClusterRadius: 40,
            size: const Size(38, 38),
            alignment: Alignment.center,
            padding: const EdgeInsets.all(50),
            markers: docs.map((d) => _markerDeDoc(d)).toList(),
            builder: (ctx, markers) => Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.accentPurple,
              ),
              child: Center(
                child: Text(
                  markers.length.toString(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
        const RichAttributionWidget(
          attributions: [
            TextSourceAttribution('© OpenStreetMap'),
          ],
        ),
      ],
    );
  }

  Marker _markerDeDoc(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    final lat = (data['lat'] as num).toDouble();
    final lng = (data['lng'] as num).toDouble();
    final ignition = data['ignition'] == true;
    final reportTs = (data['report_date'] as Timestamp?)?.toDate();
    final minDesdeReporte =
        reportTs == null ? null : ahora.difference(reportTs).inMinutes;
    final tieneDrift = (data['drift_tipo'] ?? '').toString().isNotEmpty;

    final color = _colorMarker(
      ignition: ignition,
      minStale: minDesdeReporte,
      tieneDrift: tieneDrift,
    );

    return Marker(
      point: LatLng(lat, lng),
      width: 36,
      height: 36,
      child: GestureDetector(
        onTap: () => onMarkerTap(doc),
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            // Borde más grueso/contrastado si hay drift, para que salte
            // a la vista incluso cuando hay muchos markers cerca.
            border: Border.all(
              color: tieneDrift ? Colors.white : Colors.white,
              width: tieneDrift ? 3 : 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(120),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            tieneDrift ? Icons.warning_amber : Icons.local_shipping,
            color: Colors.white,
            size: tieneDrift ? 20 : 18,
          ),
        ),
      ),
    );
  }

  /// Naranja si tiene drift (chofer físico ≠ asignado). Rojo si > 60 min
  /// sin reportar. Verde si motor ON. Gris si motor OFF.
  /// Drift gana sobre stale, y stale gana sobre ignición.
  static Color _colorMarker({
    required bool ignition,
    required int? minStale,
    required bool tieneDrift,
  }) {
    if (tieneDrift) return AppColors.accentOrange;
    if (minStale != null && minStale > 60) return AppColors.accentRed;
    if (ignition) return AppColors.accentGreen;
    return Colors.white60;
  }
}

// =============================================================================
// SHEET DE DETALLE
// =============================================================================

class _DetalleSheet extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> data;

  const _DetalleSheet({required this.patente, required this.data});

  @override
  Widget build(BuildContext context) {
    final ignition = data['ignition'] == true;
    final speed = (data['speed'] as num?)?.toDouble();
    final odometer = (data['odometer'] as num?)?.toDouble();
    final hourmeter = (data['hourmeter'] as num?)?.toDouble();
    final reportTs = (data['report_date'] as Timestamp?)?.toDate();
    final ignitionTs = (data['ignition_date'] as Timestamp?)?.toDate();
    final lat = (data['lat'] as num?)?.toDouble();
    final lng = (data['lng'] as num?)?.toDouble();
    final location = (data['location'] ?? '').toString();
    final driverDni = (data['driver_dni'] ?? '').toString();
    final driverApellido = (data['driver_apellido'] ?? '').toString();
    final driverNombre = (data['driver_nombre'] ?? '').toString();
    final eventName = (data['event_name'] ?? '').toString();
    final driftTipo = (data['drift_tipo'] ?? '').toString();
    final asignacionDni = (data['asignacion_dni'] ?? '').toString();
    final asignacionNombre = (data['asignacion_nombre'] ?? '').toString();
    final fmt = DateFormat('dd/MM HH:mm');

    final choferTexto = driverDni.isEmpty
        ? '— (sin identificar)'
        : [driverApellido, driverNombre]
            .where((s) => s.isNotEmpty)
            .join(' ')
            .trim()
            .replaceAll(RegExp(r'\s+'), ' ')
            .ifEmpty('DNI $driverDni');

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border.all(
          color: ignition
              ? AppColors.accentGreen.withAlpha(60)
              : Colors.white24,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  patente,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              _BadgeIgnicion(on: ignition),
            ],
          ),
          if (driftTipo.isNotEmpty) ...[
            const SizedBox(height: 12),
            _DriftBanner(
              tipo: driftTipo,
              sitrackDni: driverDni,
              sitrackApellido: driverApellido,
              asignacionDni: asignacionDni,
              asignacionNombre: asignacionNombre,
            ),
          ],
          const SizedBox(height: 16),
          _Fila(
            label: 'Chofer',
            valor: choferTexto,
            icono: Icons.person_outline,
            colorIcono: driverDni.isEmpty ? Colors.white38 : AppColors.accentGreen,
          ),
          if (driverDni.isNotEmpty)
            _Fila(label: 'DNI', valor: driverDni),
          _Fila(
            label: 'Velocidad',
            valor: speed == null ? '—' : '${speed.toStringAsFixed(0)} km/h',
            icono: Icons.speed,
          ),
          _Fila(
            label: 'Odómetro',
            valor: odometer == null
                ? '—'
                : '${_formatearMiles(odometer)} km',
            icono: Icons.straighten,
          ),
          if (hourmeter != null)
            _Fila(
              label: 'Horómetro',
              valor: '${hourmeter.toStringAsFixed(1)} h',
              icono: Icons.access_time,
            ),
          // Telemetría Volvo Connect (combustible, AdBlue, autonomía).
          // Vive en el doc VEHICULOS — no en SITRACK_POSICIONES — porque
          // la pobla `vehiculo_manager.actualizarTelemetria` cuando el
          // admin entra a la pantalla de unidades. Solo aparece si hay
          // dato (las unidades sin Volvo Connect quedan sin estos campos).
          _TelemetriaVolvoFila(patente: patente),
          _Fila(
            label: 'Último reporte',
            valor: reportTs == null ? '—' : fmt.format(reportTs),
            icono: Icons.update,
          ),
          if (ignitionTs != null)
            _Fila(
              label: 'Ignición desde',
              valor: fmt.format(ignitionTs),
            ),
          if (eventName.isNotEmpty)
            _Fila(
              label: 'Evento',
              valor: eventName,
              icono: Icons.bolt,
            ),
          if (location.isNotEmpty) ...[
            const SizedBox(height: 8),
            _Fila(
              label: 'Dirección',
              valor: location,
              icono: Icons.place_outlined,
              esLargo: true,
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white54,
                    side: BorderSide(color: Colors.white.withAlpha(40)),
                  ),
                  child: const Text('Cerrar'),
                ),
              ),
              if (lat != null && lng != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => _abrirMaps(lat, lng),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Ver en Maps'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accentBlue.withAlpha(180),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _abrirMaps(double lat, double lng) async {
    final uri = Uri.parse('https://www.google.com/maps?q=$lat,$lng');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Formato AR: 12.345.678 (separador de miles con punto).
  static String _formatearMiles(double n) {
    final i = n.round();
    final s = i.toString();
    final buf = StringBuffer();
    var c = 0;
    for (var k = s.length - 1; k >= 0; k--) {
      buf.write(s[k]);
      c++;
      if (c == 3 && k != 0) {
        buf.write('.');
        c = 0;
      }
    }
    return buf.toString().split('').reversed.join();
  }
}

class _Fila extends StatelessWidget {
  final String label;
  final String valor;
  final IconData? icono;
  final Color? colorIcono;
  final bool esLargo;

  const _Fila({
    required this.label,
    required this.valor,
    this.icono,
    this.colorIcono,
    this.esLargo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment:
            esLargo ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          if (icono != null) ...[
            Icon(icono, size: 14, color: colorIcono ?? Colors.white38),
            const SizedBox(width: 6),
          ] else ...[
            const SizedBox(width: 20),
          ],
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              valor,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: esLargo ? 3 : 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _BadgeIgnicion extends StatelessWidget {
  final bool on;

  const _BadgeIgnicion({required this.on});

  @override
  Widget build(BuildContext context) {
    final color = on ? AppColors.accentGreen : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(120)),
      ),
      child: Text(
        on ? 'EN MARCHA' : 'APAGADO',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

extension _StringIfEmpty on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Bloque de telemetría Volvo Connect (combustible / AdBlue / autonomía)
/// para una patente. Lee de VEHICULOS/{patente} una sola vez al abrir
/// el sheet — no necesita stream porque los valores cambian con baja
/// frecuencia (cron cada ~6h o sync manual desde la pantalla de
/// unidades). Si la unidad no tiene Volvo Connect (campos ausentes),
/// el widget no renderiza nada — silencioso.
class _TelemetriaVolvoFila extends StatelessWidget {
  final String patente;
  const _TelemetriaVolvoFila({required this.patente});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      future: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .get(),
      builder: (ctx, snap) {
        if (!snap.hasData || snap.data?.data() == null) {
          return const SizedBox.shrink();
        }
        final data = snap.data!.data()!;
        final combustible = (data['NIVEL_COMBUSTIBLE'] as num?)?.toDouble();
        final adblue = (data['NIVEL_ADBLUE'] as num?)?.toDouble();
        final autonomia = (data['AUTONOMIA_KM'] as num?)?.toDouble();

        if (combustible == null && adblue == null && autonomia == null) {
          // Unidad sin Volvo Connect → no mostramos placeholder.
          return const SizedBox.shrink();
        }

        return Column(
          children: [
            if (combustible != null)
              _Fila(
                label: 'Combustible',
                valor: '${combustible.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.local_gas_station,
                colorIcono: _colorPorcentaje(combustible),
              ),
            if (adblue != null)
              _Fila(
                label: 'AdBlue',
                valor: '${adblue.clamp(0, 100).toStringAsFixed(0)} %',
                icono: Icons.water_drop_outlined,
                colorIcono: _colorPorcentaje(adblue),
              ),
            if (autonomia != null)
              _Fila(
                label: 'Autonomía',
                valor: '${autonomia.toStringAsFixed(0)} km',
                icono: Icons.timeline,
              ),
          ],
        );
      },
    );
  }

  /// Verde >50%, naranja 20-50%, rojo <20%. Mismo criterio que el
  /// listado de unidades.
  static Color _colorPorcentaje(double pct) {
    if (pct > 50) return AppColors.accentGreen;
    if (pct >= 20) return AppColors.accentOrange;
    return AppColors.accentRed;
  }
}

/// Banner naranja en el sheet del tractor cuando el chofer físico
/// (Sitrack, vía iButton) no coincide con la asignación activa del
/// sistema. El cron `sitrackPosicionPoller` setea `drift_tipo` con
/// uno de tres valores que determinan el copy mostrado.
class _DriftBanner extends StatelessWidget {
  final String tipo;
  final String sitrackDni;
  final String sitrackApellido;
  final String asignacionDni;
  final String asignacionNombre;

  const _DriftBanner({
    required this.tipo,
    required this.sitrackDni,
    required this.sitrackApellido,
    required this.asignacionDni,
    required this.asignacionNombre,
  });

  @override
  Widget build(BuildContext context) {
    String titulo;
    String detalle;
    switch (tipo) {
      case 'CHOFER_DISTINTO':
        titulo = 'Chofer distinto al asignado';
        final fisico = sitrackApellido.isNotEmpty
            ? '$sitrackApellido (DNI $sitrackDni)'
            : 'DNI $sitrackDni';
        final asignado = asignacionNombre.isNotEmpty
            ? '$asignacionNombre (DNI $asignacionDni)'
            : 'DNI $asignacionDni';
        detalle = 'Sistema: $asignado.\nFísico (iButton): $fisico.';
        break;
      case 'SIN_ASIGNACION':
        final fisico = sitrackApellido.isNotEmpty
            ? '$sitrackApellido (DNI $sitrackDni)'
            : 'DNI $sitrackDni';
        titulo = 'Manejando sin estar asignado';
        detalle = 'El tractor no tiene asignación activa, pero $fisico '
            'está identificado en él via iButton.';
        break;
      case 'CHOFER_NO_IDENTIFICADO':
        final asignado = asignacionNombre.isNotEmpty
            ? '$asignacionNombre (DNI $asignacionDni)'
            : 'DNI $asignacionDni';
        titulo = 'Chofer no se identificó';
        detalle = 'Sistema asignado: $asignado.\n'
            'El motor está encendido pero nadie pasó el iButton.';
        break;
      default:
        titulo = 'Inconsistencia detectada';
        detalle = 'Tipo: $tipo';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.accentOrange.withAlpha(30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.accentOrange.withAlpha(120)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber,
              color: AppColors.accentOrange, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    color: AppColors.accentOrange,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detalle,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
