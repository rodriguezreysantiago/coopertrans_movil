import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_geo_utils.dart';
import '../services/logistica_service.dart';

/// Lista de tarifas con buscador. Cada tarifa = una "ruta con precio"
/// que el módulo de viajes (futuro) va a poder seleccionar como base.
class LogisticaTarifasScreen extends StatefulWidget {
  const LogisticaTarifasScreen({super.key});

  @override
  State<LogisticaTarifasScreen> createState() =>
      _LogisticaTarifasScreenState();
}

class _LogisticaTarifasScreenState extends State<LogisticaTarifasScreen> {
  String _filtro = '';
  bool _soloActivas = true;

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Tarifas',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.accentGreen,
          onPressed: () => Navigator.pushNamed(
            ctx,
            AppRoutes.adminLogisticaTarifaForm,
          ),
          icon: const Icon(Icons.add),
          label: const Text('NUEVA TARIFA'),
        ),
      ),
      body: Column(
        children: [
          _BarraFiltros(
            filtroInicial: _filtro,
            soloActivas: _soloActivas,
            onCambioFiltro: (v) => setState(() => _filtro = v),
            onCambioActivas: (v) => setState(() => _soloActivas = v),
          ),
          Expanded(
            // Stream externo: catálogo de ubicaciones. El interno
            // (tarifas) lo combina por id para mostrar distancia
            // geodésica en el card cuando ambas ubicaciones tienen
            // coords. Ubicaciones cambian poco (chico, no causa
            // jitter visual).
            child: StreamBuilder<List<UbicacionLogistica>>(
              stream: LogisticaService.streamUbicaciones(),
              builder: (ctx, ubicSnap) {
                final ubicacionesPorId = {
                  for (final u in (ubicSnap.data ?? const <UbicacionLogistica>[]))
                    u.id: u,
                };
                return StreamBuilder<List<TarifaLogistica>>(
                  stream: LogisticaService.streamTarifas(
                    soloActivas: _soloActivas,
                  ),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snap.hasError) {
                      return AppEmptyState(
                        icon: Icons.error_outline,
                        title: 'Error cargando la lista',
                        subtitle: snap.error.toString(),
                      );
                    }
                    final all = snap.data ?? const [];
                    final filtradas = _aplicarFiltro(all, _filtro);
                    if (filtradas.isEmpty) {
                      return AppEmptyState(
                        icon: Icons.price_change_outlined,
                        title: all.isEmpty
                            ? 'Sin tarifas cargadas'
                            : 'Sin coincidencias',
                        subtitle: all.isEmpty
                            ? 'Tocá + para armar la primera tarifa.'
                            : 'Probá con otro texto o limpiá el filtro.',
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                      itemCount: filtradas.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (_, i) => _CardTarifa(
                        tarifa: filtradas[i],
                        ubicacionesPorId: ubicacionesPorId,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<TarifaLogistica> _aplicarFiltro(
    List<TarifaLogistica> tarifas,
    String filtro,
  ) {
    if (filtro.trim().isEmpty) return tarifas;
    final f = filtro.trim().toUpperCase();
    return tarifas.where((t) {
      return t.empresaOrigenNombre.toUpperCase().contains(f) ||
          t.empresaDestinoNombre.toUpperCase().contains(f) ||
          t.ubicacionOrigenEtiqueta.toUpperCase().contains(f) ||
          t.ubicacionDestinoEtiqueta.toUpperCase().contains(f) ||
          (t.dadorNombre?.toUpperCase().contains(f) ?? false);
    }).toList();
  }
}

class _BarraFiltros extends StatelessWidget {
  final String filtroInicial;
  final bool soloActivas;
  final ValueChanged<String> onCambioFiltro;
  final ValueChanged<bool> onCambioActivas;

  const _BarraFiltros({
    required this.filtroInicial,
    required this.soloActivas,
    required this.onCambioFiltro,
    required this.onCambioActivas,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              onChanged: onCambioFiltro,
              decoration: const InputDecoration(
                hintText: 'Buscar empresa o ubicación...',
                prefixIcon: Icon(Icons.search, color: Colors.white54),
                isDense: true,
              ),
              style: const TextStyle(color: Colors.white),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(
            label: const Text('Activas'),
            selected: soloActivas,
            onSelected: onCambioActivas,
            selectedColor: AppColors.accentGreen.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }
}

class _CardTarifa extends StatelessWidget {
  final TarifaLogistica tarifa;
  final Map<String, UbicacionLogistica> ubicacionesPorId;
  const _CardTarifa({
    required this.tarifa,
    this.ubicacionesPorId = const {},
  });

  /// Par de coords origen-destino si las dos ubicaciones tienen
  /// lat/lng cargadas; null si falta alguna.
  ({LatLng origen, LatLng destino})? get _ods {
    final o = ubicacionesPorId[tarifa.ubicacionOrigenId];
    final d = ubicacionesPorId[tarifa.ubicacionDestinoId];
    if (o?.lat == null || o?.lng == null) return null;
    if (d?.lat == null || d?.lng == null) return null;
    return (
      origen: LatLng(o!.lat!, o.lng!),
      destino: LatLng(d!.lat!, d.lng!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final color =
        tarifa.activa ? AppColors.accentGreen : Colors.white24;
    return AppCard(
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaTarifaForm,
        arguments: {'tarifaId': tarifa.id},
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: tipo + flete + activa
          Row(
            children: [
              Icon(
                tarifa.tipoCarga == TipoCargaLogistica.terceros
                    ? Icons.handshake_outlined
                    : Icons.local_shipping_outlined,
                color: color,
                size: 22,
              ),
              const SizedBox(width: 8),
              _ChipTipo(tarifa: tarifa),
              const SizedBox(width: 6),
              _ChipFlete(flete: tarifa.flete),
              const Spacer(),
              if (!tarifa.activa)
                const Text(
                  'INACTIVA',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // Línea 2: origen → destino
          _RutaOrigenDestino(tarifa: tarifa, ods: _ods),
          const SizedBox(height: 10),
          // Línea 3: tarifas
          _TarifasMontos(tarifa: tarifa),
          if (tarifa.dadorNombre != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.business_outlined,
                    color: Colors.white54, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    'Dador: ${tarifa.dadorNombre}'
                    '${tarifa.porcentajeComisionDador != null ? " · ${tarifa.porcentajeComisionDador!.toStringAsFixed(1)}%" : ""}',
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _RutaOrigenDestino extends StatelessWidget {
  final TarifaLogistica tarifa;
  final ({LatLng origen, LatLng destino})? ods;
  const _RutaOrigenDestino({required this.tarifa, this.ods});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Punto(
            etiqueta: 'ORIGEN',
            empresa: tarifa.empresaOrigenNombre,
            ubicacion: tarifa.ubicacionOrigenEtiqueta,
            color: AppColors.accentBlue,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.arrow_forward,
                  color: Colors.white38, size: 18),
              if (ods != null) ...[
                const SizedBox(height: 2),
                _DistanciaTexto(origen: ods!.origen, destino: ods!.destino),
              ],
            ],
          ),
        ),
        Expanded(
          child: _Punto(
            etiqueta: 'DESTINO',
            empresa: tarifa.empresaDestinoNombre,
            ubicacion: tarifa.ubicacionDestinoEtiqueta,
            color: AppColors.accentTeal,
          ),
        ),
      ],
    );
  }
}

class _Punto extends StatelessWidget {
  final String etiqueta;
  final String empresa;
  final String ubicacion;
  final Color color;
  const _Punto({
    required this.etiqueta,
    required this.empresa,
    required this.ubicacion,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          etiqueta,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          empresa,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          ubicacion,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 11,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 2,
        ),
      ],
    );
  }
}

class _TarifasMontos extends StatelessWidget {
  final TarifaLogistica tarifa;
  const _TarifasMontos({required this.tarifa});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Expanded(
            child: _MontoBloque(
              etiqueta: 'TARIFA REAL',
              monto: tarifa.tarifaReal,
              sufijo: tarifa.unidadTarifa.sufijoMonto,
              color: AppColors.accentGreen,
            ),
          ),
          Container(
            width: 1,
            height: 28,
            color: Colors.white12,
          ),
          Expanded(
            child: _MontoBloque(
              etiqueta: 'CHOFER',
              monto: tarifa.tarifaChofer,
              sufijo: tarifa.unidadTarifa.sufijoMonto,
              color: AppColors.accentBlue,
            ),
          ),
          Container(
            width: 1,
            height: 28,
            color: Colors.white12,
          ),
          Expanded(
            child: _MontoBloque(
              etiqueta: 'BRUTO',
              monto: tarifa.diferenciaBruta,
              sufijo: tarifa.unidadTarifa.sufijoMonto,
              color: AppColors.accentOrange,
            ),
          ),
        ],
      ),
    );
  }
}

class _MontoBloque extends StatelessWidget {
  final String etiqueta;
  final double monto;
  final String sufijo;
  final Color color;
  const _MontoBloque({
    required this.etiqueta,
    required this.monto,
    required this.sufijo,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          etiqueta,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '\$ ${AppFormatters.formatearMonto(monto)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          sufijo,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10,
          ),
        ),
      ],
    );
  }
}

class _ChipTipo extends StatelessWidget {
  final TarifaLogistica tarifa;
  const _ChipTipo({required this.tarifa});

  @override
  Widget build(BuildContext context) {
    final esTerceros = tarifa.tipoCarga == TipoCargaLogistica.terceros;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (esTerceros ? AppColors.accentOrange : AppColors.accentBlue)
            .withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        tarifa.tipoCarga.etiqueta.toUpperCase(),
        style: TextStyle(
          color:
              esTerceros ? AppColors.accentOrange : AppColors.accentBlue,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

class _ChipFlete extends StatelessWidget {
  final FleteLogistica flete;
  const _ChipFlete({required this.flete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        flete.etiqueta.toUpperCase(),
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.0,
        ),
      ),
    );
  }
}

/// Texto de distancia entre dos puntos. Mientras espera la ruta real
/// de OSRM, muestra la distancia geodésica como fallback inmediato.
/// Cuando vuelve la ruta, refresca con km reales + tiempo estimado.
/// Si OSRM falla (sin red, par fuera del grafo), se queda con la
/// geodésica (mejor que nada).
class _DistanciaTexto extends StatelessWidget {
  final LatLng origen;
  final LatLng destino;
  const _DistanciaTexto({required this.origen, required this.destino});

  @override
  Widget build(BuildContext context) {
    final geodesicaKm = LogisticaGeoUtils.distanciaKm(origen, destino);
    return FutureBuilder<GeoRuta?>(
      future: LogisticaGeoUtils.obtenerRuta(origen, destino),
      builder: (ctx, snap) {
        final ruta = snap.data;
        if (ruta != null) {
          return Column(
            children: [
              Text(
                '${ruta.distanciaKm.toStringAsFixed(0)} km',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                ruta.duracionFormateada,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                ),
              ),
            ],
          );
        }
        return Text(
          '${geodesicaKm.toStringAsFixed(0)} km',
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 10,
            fontWeight: FontWeight.bold,
          ),
        );
      },
    );
  }
}
