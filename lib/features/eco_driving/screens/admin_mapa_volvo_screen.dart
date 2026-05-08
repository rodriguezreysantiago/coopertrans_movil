import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/constants/map_constants.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../utils/etiquetas_alerta_volvo.dart';
import '../widgets/evento_volvo_detalle_sheet.dart';

/// Pantalla "Mapa Volvo" — visualización geográfica de eventos del
/// Vehicle Alerts API sobre OpenStreetMap.
///
/// **Iteración 2 (2026-05-04)**: además del listado de pins, ahora
/// puede mostrar:
/// - **Ruta del chofer**: polyline que conecta los eventos en orden
///   cronológico cuando hay un filtro de patente activo. Ayuda a ver
///   el recorrido real del día y validar contra el remito.
/// - **Heatmap OVERSPEED**: capa de calor sobre los eventos de
///   exceso de velocidad — concentra los puntos en celdas geográficas
///   y dibuja círculos cuya intensidad aumenta con la densidad. Útil
///   para identificar TRAMOS recurrentes donde los choferes aceleran
///   (ej. "siempre pasan a 110 km/h en el km 17 de la 22").
///
/// Filtros: rango temporal (popup AppBar), tipos de evento, patente,
/// toggle de heatmap.
class AdminMapaVolvoScreen extends StatefulWidget {
  const AdminMapaVolvoScreen({super.key});

  @override
  State<AdminMapaVolvoScreen> createState() => _AdminMapaVolvoScreenState();
}

class _AdminMapaVolvoScreenState extends State<AdminMapaVolvoScreen> {
  // Bahía Blanca centro — operación de Vecchi.
  static const _centroInicial = LatLng(-38.7196, -62.2724);
  static const _zoomInicial = 8.0;

  int _diasRango = 30;
  String? _filtroTipo; // null = todos los tipos
  String? _filtroPatente; // null = todas las patentes
  /// Si está activo, dibuja la capa de heatmap con los OVERSPEED del
  /// rango. Aplicar a TODA la flota (ignora filtros de patente / tipo
  /// — el heatmap es vista agregada, no filtrada).
  bool _heatmapActivo = false;

  final _mapController = MapController();

  DateTime get _desde => DateTime.now().subtract(Duration(days: _diasRango));

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mapa Volvo',
      actions: [
        PopupMenuButton<int>(
          icon: const Icon(Icons.calendar_today),
          tooltip: 'Rango temporal',
          initialValue: _diasRango,
          onSelected: (v) => setState(() => _diasRango = v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 7, child: Text('Últimos 7 días')),
            PopupMenuItem(value: 15, child: Text('Últimos 15 días')),
            PopupMenuItem(value: 30, child: Text('Últimos 30 días')),
            PopupMenuItem(value: 60, child: Text('Últimos 60 días')),
            PopupMenuItem(value: 90, child: Text('Últimos 90 días')),
          ],
        ),
      ],
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection(AppCollections.volvoAlertas)
            .where('creado_en',
                isGreaterThanOrEqualTo: Timestamp.fromDate(_desde))
            .orderBy('creado_en', descending: true)
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
          final docsConGps = allDocs.where(_tieneGpsValido).toList();
          final tiposDisponibles = <String>{
            for (final d in docsConGps)
              if ((d.data()['tipo'] ?? '').toString().isNotEmpty)
                d.data()['tipo'].toString()
          }.toList()
            ..sort();
          final patentesDisponibles = <String>{
            for (final d in docsConGps)
              if ((d.data()['patente'] ?? '').toString().isNotEmpty)
                d.data()['patente'].toString()
          }.toList()
            ..sort();

          final visibles = docsConGps.where((d) {
            final data = d.data();
            if (_filtroTipo != null &&
                (data['tipo'] ?? '').toString() != _filtroTipo) {
              return false;
            }
            if (_filtroPatente != null &&
                (data['patente'] ?? '').toString() != _filtroPatente) {
              return false;
            }
            return true;
          }).toList();

          // Ruta del chofer: solo se calcula si hay patente filtrada.
          // Ordenamos cronológico ascendente para que la polyline siga
          // el orden real del día.
          List<_PuntoRuta> puntosRuta = const [];
          if (_filtroPatente != null) {
            puntosRuta = _construirRuta(visibles);
          }

          // Heatmap OVERSPEED: clusterizamos los OVERSPEED del rango
          // (siempre toda la flota — el heatmap muestra patrones
          // agregados que no tienen sentido filtrar por patente).
          List<_CeldaHeatmap> celdasHeatmap = const [];
          if (_heatmapActivo) {
            celdasHeatmap = _construirHeatmap(docsConGps);
          }

          return Column(
            children: [
              _Toolbar(
                totalEventos: allDocs.length,
                conGps: docsConGps.length,
                visibles: visibles.length,
                tipos: tiposDisponibles,
                patentes: patentesDisponibles,
                filtroTipo: _filtroTipo,
                filtroPatente: _filtroPatente,
                heatmapActivo: _heatmapActivo,
                rutaActiva: puntosRuta.isNotEmpty,
                onTipoChange: (v) => setState(() => _filtroTipo = v),
                onPatenteChange: (v) => setState(() => _filtroPatente = v),
                onHeatmapToggle: (v) => setState(() => _heatmapActivo = v),
                rangoDias: _diasRango,
              ),
              Expanded(
                child: _Mapa(
                  controller: _mapController,
                  centroInicial: _centroInicial,
                  zoomInicial: _zoomInicial,
                  docs: visibles,
                  puntosRuta: puntosRuta,
                  celdasHeatmap: celdasHeatmap,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  static bool _tieneGpsValido(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final gps = d.data()['posicion_gps'];
    if (gps is! Map) return false;
    final lat = gps['lat'];
    final lng = gps['lng'];
    return lat is num && lng is num;
  }

  /// Convierte los docs filtrados a `_PuntoRuta` ordenados ascendente
  /// por timestamp. Cada punto lleva la velocidad si el doc la trae —
  /// la usamos para colorear el segmento que SALE de él.
  static List<_PuntoRuta> _construirRuta(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final puntos = <_PuntoRuta>[];
    for (final d in docs) {
      final data = d.data();
      final gps = data['posicion_gps'] as Map?;
      final lat = (gps?['lat'] as num?)?.toDouble();
      final lng = (gps?['lng'] as num?)?.toDouble();
      final ts = data['creado_en'] as Timestamp?;
      if (lat == null || lng == null || ts == null) continue;
      // Velocidad puede venir en distintos campos según subtipo de
      // alerta. Probamos los dos más frecuentes.
      double? vel;
      final velRaw = data['velocidad'] ?? data['velocidad_kmh'];
      if (velRaw is num) vel = velRaw.toDouble();
      puntos.add(_PuntoRuta(
        punto: LatLng(lat, lng),
        timestamp: ts.toDate(),
        velocidad: vel,
      ));
    }
    puntos.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return puntos;
  }

  /// Cluster simple en celdas de ~0.005° de lado (~550m a -38° lat).
  /// Solo cuenta eventos OVERSPEED. Devuelve una celda por bucket con
  /// el centro y la cantidad — el caller mapea la cantidad a alpha.
  static List<_CeldaHeatmap> _construirHeatmap(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    const tamCelda = 0.005;
    final buckets = <String, _CeldaHeatmap>{};
    for (final d in docs) {
      final data = d.data();
      final tipo = (data['tipo'] ?? '').toString().toUpperCase();
      if (tipo != 'OVERSPEED') continue;
      final gps = data['posicion_gps'] as Map?;
      final lat = (gps?['lat'] as num?)?.toDouble();
      final lng = (gps?['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) continue;
      // Snapeamos a la celda truncando a múltiplos de tamCelda.
      final celdaLat = (lat / tamCelda).floor() * tamCelda;
      final celdaLng = (lng / tamCelda).floor() * tamCelda;
      final key = '$celdaLat,$celdaLng';
      final actual = buckets[key];
      if (actual == null) {
        buckets[key] = _CeldaHeatmap(
          centro: LatLng(celdaLat + tamCelda / 2, celdaLng + tamCelda / 2),
          cuenta: 1,
        );
      } else {
        buckets[key] = _CeldaHeatmap(
          centro: actual.centro,
          cuenta: actual.cuenta + 1,
        );
      }
    }
    return buckets.values.toList();
  }
}

// =============================================================================
// MODELOS LIVIANOS PARA LAS CAPAS NUEVAS
// =============================================================================

/// Punto de la ruta del chofer (ordenable por timestamp).
class _PuntoRuta {
  final LatLng punto;
  final DateTime timestamp;
  /// Velocidad en km/h cuando está disponible. Define el color del
  /// segmento que sale de este punto al siguiente.
  final double? velocidad;

  const _PuntoRuta({
    required this.punto,
    required this.timestamp,
    required this.velocidad,
  });
}

/// Celda agregada del heatmap (centro + cantidad de eventos OVERSPEED).
class _CeldaHeatmap {
  final LatLng centro;
  final int cuenta;
  const _CeldaHeatmap({required this.centro, required this.cuenta});
}

// =============================================================================
// TOOLBAR (filtros + contador + toggles de capas)
// =============================================================================

class _Toolbar extends StatelessWidget {
  final int totalEventos;
  final int conGps;
  final int visibles;
  final List<String> tipos;
  final List<String> patentes;
  final String? filtroTipo;
  final String? filtroPatente;
  final bool heatmapActivo;
  final bool rutaActiva;
  final ValueChanged<String?> onTipoChange;
  final ValueChanged<String?> onPatenteChange;
  final ValueChanged<bool> onHeatmapToggle;
  final int rangoDias;

  const _Toolbar({
    required this.totalEventos,
    required this.conGps,
    required this.visibles,
    required this.tipos,
    required this.patentes,
    required this.filtroTipo,
    required this.filtroPatente,
    required this.heatmapActivo,
    required this.rutaActiva,
    required this.onTipoChange,
    required this.onPatenteChange,
    required this.onHeatmapToggle,
    required this.rangoDias,
  });

  @override
  Widget build(BuildContext context) {
    final sinGps = totalEventos - conGps;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: Colors.black.withAlpha(80),
        border: Border(
          bottom: BorderSide(color: Colors.white.withAlpha(20)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$visibles de $conGps eventos georref. '
                  '(${sinGps > 0 ? "$sinGps sin GPS · " : ""}rango $rangoDias d)'
                  '${rutaActiva ? " · ruta activa" : ""}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 11),
                ),
              ),
              // Toggle heatmap OVERSPEED. Visible siempre — independiente
              // de filtros (el heatmap muestra agregado de la flota).
              _ToggleChip(
                label: 'HEATMAP',
                icono: Icons.local_fire_department,
                activo: heatmapActivo,
                colorActivo: AppColors.accentRed,
                onChange: onHeatmapToggle,
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Filtros de tipo (chip horizontal scrolleable).
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _Chip(
                  label: 'TODOS',
                  selected: filtroTipo == null,
                  onTap: () => onTipoChange(null),
                ),
                const SizedBox(width: 4),
                for (final t in tipos)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    // El chip muestra la etiqueta legible (ej. "Exceso de
                    // velocidad") pero filtra por el codigo crudo. Para
                    // eventos GENERIC se va a ver "Evento generico" en el
                    // chip — no podemos desambiguar por subtipo en el
                    // filtro hasta que se haga refactor del filtro
                    // para soportarlo (feature aparte).
                    child: _Chip(
                      label: etiquetaAlertaVolvo(t),
                      selected: filtroTipo == t,
                      onTap: () => onTipoChange(t),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // Filtros de patente.
          SizedBox(
            height: 30,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _Chip(
                  label: 'TODAS',
                  selected: filtroPatente == null,
                  onTap: () => onPatenteChange(null),
                ),
                const SizedBox(width: 4),
                for (final p in patentes)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: _Chip(
                      label: p,
                      selected: filtroPatente == p,
                      onTap: () => onPatenteChange(p),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _Chip({
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
          color: activo ? colorActivo.withAlpha(35) : Colors.white.withAlpha(8),
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
  final List<_PuntoRuta> puntosRuta;
  final List<_CeldaHeatmap> celdasHeatmap;

  const _Mapa({
    required this.controller,
    required this.centroInicial,
    required this.zoomInicial,
    required this.docs,
    required this.puntosRuta,
    required this.celdasHeatmap,
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
        // Capa heatmap (debajo de la ruta y los markers para no taparlos).
        if (celdasHeatmap.isNotEmpty) _capaHeatmap(),
        // Capa ruta (línea coloreada por velocidad). Va debajo de los
        // markers para que los pins queden tappables.
        if (puntosRuta.length >= 2) _capaRuta(),
        MarkerLayer(
          markers: docs
              .map((d) => _markerDeDoc(context, d))
              .whereType<Marker>()
              .toList(),
        ),
        const RichAttributionWidget(
          attributions: [
            TextSourceAttribution('© OpenStreetMap'),
          ],
        ),
      ],
    );
  }

  /// Heatmap como `CircleLayer` — cada celda es un círculo cuya alpha
  /// crece con la cantidad de OVERSPEED en esa celda. Mapeamos
  /// `cuenta → alpha` con un cap a 5+ eventos = full opaco.
  Widget _capaHeatmap() {
    final maxCuenta = celdasHeatmap.map((c) => c.cuenta).reduce(
          (a, b) => a > b ? a : b,
        );
    return CircleLayer(
      circles: celdasHeatmap.map((c) {
        // Normalizamos 1..max a 0.2..0.8 — siempre algo de transparencia
        // para que se vea el mapa abajo.
        final intensidad = (c.cuenta / (maxCuenta == 0 ? 1 : maxCuenta))
            .clamp(0.0, 1.0);
        final alpha = (50 + intensidad * 150).round().clamp(50, 200);
        return CircleMarker(
          point: c.centro,
          // Radio físico en metros — escala con el zoom solo (no
          // depende de pixels). 250m ≈ tamaño del bucket /2 — los
          // círculos vecinos se solapan formando una mancha.
          radius: 250,
          useRadiusInMeter: true,
          color: AppColors.accentRed.withAlpha(alpha),
          borderStrokeWidth: 0,
        );
      }).toList(),
    );
  }

  /// Ruta del chofer como secuencia de polylines coloreadas por
  /// velocidad. Cada par consecutivo es un Polyline propio con su
  /// color — más simple que un gradiente real y suficiente para
  /// visualizar tramos peligrosos en rojo.
  Widget _capaRuta() {
    final segmentos = <Polyline>[];
    for (var i = 0; i < puntosRuta.length - 1; i++) {
      final a = puntosRuta[i];
      final b = puntosRuta[i + 1];
      // Color del segmento según velocidad del PUNTO DE ORIGEN.
      // Si no hay velocidad reportada (caso común para tipos no-OVERSPEED),
      // gris neutro — la línea sigue sirviendo para ver la traza.
      final color = _colorVelocidad(a.velocidad);
      segmentos.add(Polyline(
        points: [a.punto, b.punto],
        color: color,
        strokeWidth: 4,
      ));
    }
    return PolylineLayer(polylines: segmentos);
  }

  static Color _colorVelocidad(double? vel) {
    if (vel == null) return Colors.white38;
    if (vel > 100) return AppColors.accentRed;
    if (vel > 80) return AppColors.accentOrange;
    return AppColors.accentGreen;
  }

  Marker? _markerDeDoc(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final data = doc.data();
    final gps = data['posicion_gps'];
    if (gps is! Map) return null;
    final lat = (gps['lat'] as num?)?.toDouble();
    final lng = (gps['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;

    final severidad = (data['severidad'] ?? '').toString().toUpperCase();
    final atendida = data['atendida'] == true;
    final color = atendida
        ? Colors.white38
        : severidad == 'HIGH'
            ? AppColors.accentRed
            : severidad == 'MEDIUM'
                ? AppColors.accentOrange
                : AppColors.accentGreen;

    return Marker(
      point: LatLng(lat, lng),
      width: 28,
      height: 28,
      alignment: Alignment.center,
      child: GestureDetector(
        onTap: () => _mostrarDetalle(context, doc),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color.withAlpha(220),
            border: Border.all(color: Colors.black.withAlpha(120), width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(80),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: const Icon(
            Icons.warning_amber_rounded,
            color: Colors.black,
            size: 14,
          ),
        ),
      ),
    );
  }

  void _mostrarDetalle(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => EventoVolvoDetalleSheet(
        alertId: doc.id,
        data: doc.data(),
      ),
    );
  }
}

// =============================================================================
// HELPER: formato de fecha para etiquetas
// =============================================================================

// Exportado para reuso en el bottom sheet del detalle.
String formatearFechaHoraEvento(Timestamp? ts) {
  if (ts == null) return '—';
  return DateFormat('dd/MM HH:mm').format(ts.toDate());
}
