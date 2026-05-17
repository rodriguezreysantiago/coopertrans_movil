import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
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
  final FocusNode _buscarFocus = FocusNode();

  @override
  void dispose() {
    _buscarFocus.dispose();
    super.dispose();
  }

  void _abrirNueva() {
    Navigator.pushNamed(context, AppRoutes.adminLogisticaTarifaForm);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Tarifas',
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.accentGreen,
        onPressed: _abrirNueva,
        icon: const Icon(Icons.add),
        label: const Text('NUEVA TARIFA'),
      ),
      body: KeyboardShortcutsScope(
        onNuevo: _abrirNueva,
        buscarFocusNode: _buscarFocus,
        child: Column(
        children: [
          _BarraFiltros(
            filtroInicial: _filtro,
            soloActivas: _soloActivas,
            buscarFocus: _buscarFocus,
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
      ),
    );
  }

  /// Filtro token-based: exige que TODOS los tokens estén presentes
  /// en algún campo de la tarifa. Permite buscar "profertil olavarria"
  /// y matchear una tarifa con origen Profertil y destino Olavarría.
  /// Mismo patrón que `LogisticaUbicacionesScreen` y
  /// `LogisticaEmpresasScreen`.
  List<TarifaLogistica> _aplicarFiltro(
    List<TarifaLogistica> tarifas,
    String filtro,
  ) {
    final q = filtro.trim().toLowerCase();
    if (q.isEmpty) return tarifas;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return tarifas.where((t) {
      final hay = [
        t.empresaOrigenNombre,
        t.empresaDestinoNombre,
        t.ubicacionOrigenEtiqueta,
        t.ubicacionDestinoEtiqueta,
        t.dadorNombre ?? '',
        t.producto ?? '',
      ].join(' ').toLowerCase();
      for (final token in tokens) {
        if (!hay.contains(token)) return false;
      }
      return true;
    }).toList();
  }
}

class _BarraFiltros extends StatelessWidget {
  final String filtroInicial;
  final bool soloActivas;
  final FocusNode? buscarFocus;
  final ValueChanged<String> onCambioFiltro;
  final ValueChanged<bool> onCambioActivas;

  const _BarraFiltros({
    required this.filtroInicial,
    required this.soloActivas,
    required this.onCambioFiltro,
    required this.onCambioActivas,
    this.buscarFocus,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              focusNode: buscarFocus,
              onChanged: onCambioFiltro,
              decoration: const InputDecoration(
                hintText: 'Buscar por empresa, ubicación, dador o producto…',
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
          // Línea 1: tipo + flete + activa + botón eliminar
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
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: Text(
                    'INACTIVA',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.3,
                    ),
                  ),
                ),
              // Botón eliminar. El service chequea viajes en curso
              // (PLANEADO / EN_CURSO) que usan la tarifa antes de
              // borrar. Si hay alguno, muestra mensaje accionable.
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.accentRed),
                tooltip: 'Eliminar tarifa',
                onPressed: () => _confirmarEliminar(context),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ],
          ),
          if (tarifa.producto != null) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.inventory_2_outlined,
                    color: AppColors.accentAmber, size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    tarifa.producto!,
                    style: const TextStyle(
                      color: AppColors.accentAmber,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
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

  Future<void> _confirmarEliminar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final ruta =
        '${tarifa.empresaOrigenNombre} → ${tarifa.empresaDestinoNombre}';
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Eliminar tarifa?'),
        content: Text(
          '$ruta\n\n'
          'Esta acción no se puede deshacer. Si la tarifa está usada '
          'por algún viaje en curso (PLANEADO o EN CURSO), no se va '
          'a poder borrar. Los viajes históricos no se rompen.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentRed,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('ELIMINAR'),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await LogisticaService.eliminarTarifa(tarifa.id);
      AppFeedback.successOn(messenger, 'Tarifa eliminada.');
    } on StateError catch (e) {
      AppFeedback.errorOn(messenger, e.message);
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar la tarifa. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
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
    // Orden Santiago 2026-05-14: la UBICACIÓN va arriba en bold (es
    // lo más importante operativamente — define dónde físicamente
    // se carga/descarga). La empresa abajo, atenuada, como contexto.
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
          ubicacion,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          empresa,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 11,
          ),
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
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 2),
        // FittedBox: en mobile 3 columnas Expanded daban ~110 dp por
        // bloque. "$ 1.234.567,89" en fontSize 13 bold no entraba.
        // Con scaleDown se achica a la fuerza máxima que entre.
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '\$ ${AppFormatters.formatearMonto(monto)}',
            maxLines: 1,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        Text(
          sufijo,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
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
