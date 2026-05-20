import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_instalada.dart';

/// Pantalla de entrada del módulo Gomería. Muestra:
///
/// - **Alertas activas** (en cabecera): cubiertas instaladas en
///   tractores que pasaron 80% de vida útil estimada — accionable
///   directo desde acá. Solo aplica a tractores por ahora; los enganches
///   no tienen odómetro propio (Fase 2 lo resuelve cruzando con
///   `ASIGNACIONES_ENGANCHE`).
/// - **Hub**: 4 accesos: Unidades (la pantalla principal del operador),
///   Stock (cubiertas + alta), Recapados, Marcas y Modelos.
///
/// Optimizada para tablet pegada en la pared del taller: tiles grandes,
/// labels legibles a 1m de distancia.
class GomeriaHubScreen extends StatelessWidget {
  const GomeriaHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gomería',
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner de alertas — toma su altura natural (0 si no hay
            // alertas). El gap inferior está adentro del propio banner
            // para que cuando no hay alertas no quede espacio en blanco.
            const _AlertasFinDeVida(),
            // Hub principal — 4 tiles. En pantallas con alto acotado
            // (mobile/tablet) llenan el alto disponible sin scroll. En la
            // web/escritorio el ancho se capea (Center + maxWidth) para que
            // las tarjetas no queden gigantes; y si el alto no alcanza para
            // 2 filas legibles, en lugar de cortarse/desbordar pasa a scroll.
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      const spacing = 16.0;
                      const cols = 2;
                      const rows = 2;
                      // Más chica que esto y el ícono + los textos no entran.
                      const minTileAlto = 150.0;
                      final anchoCelda =
                          (constraints.maxWidth - spacing * (cols - 1)) / cols;
                      final altoLlenando = constraints.maxHeight.isFinite
                          ? (constraints.maxHeight - spacing * (rows - 1)) / rows
                          : double.infinity;
                      // ¿Entran las 2 filas sin achicar las tiles de más?
                      final entra =
                          altoLlenando.isFinite && altoLlenando >= minTileAlto;
                      final altoCelda = entra ? altoLlenando : 200.0;
                      final ratio =
                          altoCelda > 0 ? anchoCelda / altoCelda : 1.0;
                      return GridView.count(
                        crossAxisCount: cols,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        childAspectRatio: ratio,
                        // Llena el alto cuando entra; si no, scrollea (sin
                        // desbordar ni cortar las tarjetas).
                        physics: entra
                            ? const NeverScrollableScrollPhysics()
                            : const BouncingScrollPhysics(),
                        shrinkWrap: !entra,
                        children: const [
                          _HubTile(
                            titulo: 'UNIDADES',
                            subtitulo: 'Cambiar cubiertas por posición',
                            icono: Icons.local_shipping_outlined,
                            color: AppColors.accentOrange,
                            ruta: AppRoutes.adminGomeriaUnidades,
                          ),
                          _HubTile(
                            titulo: 'STOCK',
                            subtitulo: 'Cubiertas + buscar por código',
                            icono: Icons.inventory_2_outlined,
                            color: AppColors.accentBlue,
                            ruta: AppRoutes.adminGomeriaStock,
                          ),
                          _HubTile(
                            titulo: 'RECAPADOS',
                            subtitulo: 'Envíos y recepciones',
                            icono: Icons.swap_horiz_outlined,
                            color: AppColors.accentTeal,
                            ruta: AppRoutes.adminGomeriaRecapados,
                          ),
                          _HubTile(
                            titulo: 'MARCAS Y MODELOS',
                            subtitulo: 'Catálogo (ABM)',
                            icono: Icons.category_outlined,
                            color: AppColors.accentPurple,
                            ruta: AppRoutes.adminGomeriaMarcasModelos,
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HubTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final Color color;
  final String ruta;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.color,
    required this.ruta,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Icon(icono, size: 36, color: color),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 12,
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

// =============================================================================
// ALERTAS — cubiertas próximas a fin de vida
// =============================================================================

/// Banner que muestra cubiertas instaladas en tractores que pasaron
/// 80% de su vida útil estimada (snapshot al instalar). Tap → abre
/// hoja con la lista detallada para que el operador decida cuáles
/// rotar / mandar a recapar.
///
/// Cruza dos streams: `CUBIERTAS_INSTALADAS where(hasta=null,
/// unidad_tipo=TRACTOR)` y `VEHICULOS where(TIPO=TRACTOR)`. La cantidad
/// de cubiertas activas en tractores está acotada por flota (10 ×
/// cant_tractores), así que el cruce client-side es trivial incluso
/// con flotas grandes.
class _AlertasFinDeVida extends StatelessWidget {
  const _AlertasFinDeVida();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.cubiertasInstaladas)
          .where('hasta', isNull: true)
          .where('unidad_tipo',
              isEqualTo: TipoUnidadCubierta.tractor.codigo)
          .snapshots(),
      builder: (ctx, instSnap) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.vehiculos)
              .where('TIPO', isEqualTo: 'TRACTOR')
              .snapshots(),
          builder: (ctx, vehSnap) {
            // Mapa patente → KM_ACTUAL.
            final kmPorUnidad = <String, double>{};
            for (final d in vehSnap.data?.docs ?? const []) {
              final km = (d.data()['KM_ACTUAL'] as num?)?.toDouble();
              if (km != null) kmPorUnidad[d.id] = km;
            }
            final instaladas = (instSnap.data?.docs ?? const [])
                .map(CubiertaInstalada.fromDoc);
            final alertas = <_Alerta>[];
            for (final i in instaladas) {
              final pct = i.porcentajeVidaConsumida(
                  kmActualUnidad: kmPorUnidad[i.unidadId]);
              if (pct != null && pct >= 80) {
                alertas.add(_Alerta(i, pct));
              }
            }
            if (alertas.isEmpty) return const SizedBox.shrink();
            // Orden por % desc — más urgentes arriba.
            alertas.sort((a, b) => b.porcentaje.compareTo(a.porcentaje));
            final criticas = alertas.where((a) => a.porcentaje >= 100).length;
            final color = criticas > 0
                ? AppColors.accentRed
                : AppColors.accentOrange;
            final etiqueta = criticas > 0
                ? '$criticas cubierta${criticas == 1 ? "" : "s"} pasaron su vida útil'
                : '${alertas.length} cubierta${alertas.length == 1 ? "" : "s"} próxima${alertas.length == 1 ? "" : "s"} a fin de vida';
            // Padding bottom: 16 ⇒ separa el banner del grid de tiles
            // sin agregar un SizedBox suelto en el padre (que quedaría
            // visible cuando no hay alertas).
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: InkWell(
              onTap: () => _abrirDetalle(context, alertas),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: color),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: color, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            etiqueta.toUpperCase(),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          const Text(
                            'Tocá para ver el detalle.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: color),
                  ],
                ),
              ),
              ),
            );
          },
        );
      },
    );
  }

  void _abrirDetalle(BuildContext context, List<_Alerta> alertas) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (ctx) => _AlertasSheet(alertas: alertas),
    );
  }
}

class _Alerta {
  final CubiertaInstalada instalada;
  final double porcentaje;
  const _Alerta(this.instalada, this.porcentaje);
}

class _AlertasSheet extends StatelessWidget {
  final List<_Alerta> alertas;
  const _AlertasSheet({required this.alertas});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'CUBIERTAS PRÓXIMAS A FIN DE VIDA',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.5,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              itemCount: alertas.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) {
                final a = alertas[i];
                final color = a.porcentaje >= 100
                    ? AppColors.accentRed
                    : AppColors.accentOrange;
                final pos = a.instalada.posicionTipada;
                return AppCard(
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.pushNamed(
                      context,
                      AppRoutes.adminGomeriaUnidad,
                      arguments: {
                        'unidadId': a.instalada.unidadId,
                        'unidadTipo': TipoUnidadCubierta.tractor,
                        'tipoVehiculo': 'TRACTOR',
                        'modelo': '',
                      },
                    );
                  },
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: color),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${a.porcentaje.toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: color,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${a.instalada.cubiertaCodigo} · ${a.instalada.unidadId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              pos?.etiqueta ?? a.instalada.posicion,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                            if (a.instalada.modeloEtiqueta != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                a.instalada.modeloEtiqueta!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: Colors.white60, fontSize: 11),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: Colors.white38),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
