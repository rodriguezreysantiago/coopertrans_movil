import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_instalada.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
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
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Banner de alertas — toma su altura natural (0 si no hay
            // alertas). El gap inferior está adentro del propio banner
            // para que cuando no hay alertas no quede espacio en blanco.
            const _AlertasFinDeVida(),
            // Hub principal — 4 accesos. Misma lógica que el hub de
            // Logística: columnas según el ancho disponible + ratio
            // calculado con LayoutBuilder, y GridView scrollable (nunca
            // corta ni desborda). Alineado a la izquierda llenando el ancho
            // — sin centrar ni capear, así no quedan tiles gigantes ni
            // márgenes vacíos en la web/escritorio.
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  final w = constraints.maxWidth;
                  // 4 tiles: desktop ancho -> 4 en una fila; tablet/medio
                  // -> 3; celular -> 2. (Mismos thresholds que Logística.)
                  final int columnas;
                  if (w >= 800) {
                    columnas = 4;
                  } else if (w >= 540) {
                    columnas = 3;
                  } else {
                    columnas = 2;
                  }
                  const totalTiles = 4;
                  final filas = (totalTiles / columnas).ceil();
                  const spacing = AppSpacing.md;
                  // clampMin 1.0 = piso cuadrado: con pocas filas evita que
                  // las tiles se estiren a lo alto (ícono arriba flotando +
                  // texto abajo con un hueco enorme). Quedan cuadradas-ish
                  // como las de Logística.
                  final ratio = computeGridRatio(
                    boxWidth: w,
                    boxHeight: constraints.maxHeight,
                    cols: columnas,
                    rows: filas,
                    spacing: spacing,
                    clampMin: 1.0,
                    clampMax: 1.6,
                    fallback: 1.05,
                  );
                  return GridView.count(
                    crossAxisCount: columnas,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: ratio,
                    children: const [
                      _HubTile(
                        titulo: 'UNIDADES',
                        subtitulo: 'Cambiar cubiertas por posición',
                        icono: Icons.local_shipping_outlined,
                        color: AppColors.warning,
                        ruta: AppRoutes.adminGomeriaUnidades,
                      ),
                      _HubTile(
                        titulo: 'STOCK',
                        subtitulo: 'Cubiertas + buscar por código',
                        icono: Icons.inventory_2_outlined,
                        color: AppColors.info,
                        ruta: AppRoutes.adminGomeriaStock,
                      ),
                      _HubTile(
                        titulo: 'RECAPADOS',
                        subtitulo: 'Envíos y recepciones',
                        icono: Icons.swap_horiz_outlined,
                        color: AppColors.brandSoft,
                        ruta: AppRoutes.adminGomeriaRecapados,
                      ),
                      _HubTile(
                        titulo: 'MARCAS Y MODELOS',
                        subtitulo: 'Catálogo (ABM)',
                        icono: Icons.category_outlined,
                        color: AppColors.brand,
                        ruta: AppRoutes.adminGomeriaMarcasModelos,
                      ),
                    ],
                  );
                },
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
      padding: const EdgeInsets.all(AppSpacing.xl),
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
                  style: AppType.heading,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  subtitulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label,
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
                ? AppColors.error
                : AppColors.warning;
            final etiqueta = criticas > 0
                ? '$criticas cubierta${criticas == 1 ? "" : "s"} pasaron su vida útil'
                : '${alertas.length} cubierta${alertas.length == 1 ? "" : "s"} próxima${alertas.length == 1 ? "" : "s"} a fin de vida';
            // Padding bottom: 16 ⇒ separa el banner del grid de tiles
            // sin agregar un SizedBox suelto en el padre (que quedaría
            // visible cuando no hay alertas).
            return Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.lg),
              child: InkWell(
                onTap: () => _abrirDetalle(context, alertas),
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: color),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, color: color, size: 28),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              etiqueta.toUpperCase(),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.eyebrow.copyWith(color: color),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'Tocá para ver el detalle.',
                              style: AppType.eyebrow,
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
      backgroundColor: AppColors.surface0,
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
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textHint,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.sm),
            child: Text(
              'CUBIERTAS PRÓXIMAS A FIN DE VIDA',
              style: AppType.heading,
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.xs, AppSpacing.md, AppSpacing.xl),
              itemCount: alertas.length,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) {
                final a = alertas[i];
                final color = a.porcentaje >= 100
                    ? AppColors.error
                    : AppColors.warning;
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
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Row(
                    children: [
                      Container(
                        width: 56,
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                          border: Border.all(color: color),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          '${a.porcentaje.toStringAsFixed(0)}%',
                          style: AppType.heading.copyWith(color: color, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${a.instalada.cubiertaCodigo} · ${a.instalada.unidadId}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.body.copyWith(
                                color: AppColors.textPrimary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              pos?.etiqueta ?? a.instalada.posicion,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppType.label,
                            ),
                            if (a.instalada.modeloEtiqueta != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                a.instalada.modeloEtiqueta!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.eyebrow,
                              ),
                            ],
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right,
                          color: AppColors.textDisabled),
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
