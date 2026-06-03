// lib/features/logistica/screens/logistica_hub_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — hub del módulo Logística en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - las rutas de navegación de cada tile (AppRoutes.adminLogistica*),
//   - los contadores en vivo (`_StreamCount`): mismos streams
//     (`LogisticaService.tarifasCol/empresasCol/ubicacionesCol`,
//     `AppCollections.viajesLogistica/adelantosChofer`), mismo filtro
//     `soloActivas` / `campoActivo`, mismo cap `.limit(999)`,
//   - el set de 7 tiles y su orden.
//
// Layout Núcleo: banner informativo (AppCard glow + eyebrow) + grid bento
// de tiles (icon chip indigo · única tinta de navegación · arrow_outward ·
// contador en vivo como AppBadge brand en la esquina). Mismo patrón que
// `icm_hub_screen.dart`.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/logistica_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Hub del módulo Logística. 4 catálogos + 1 vista de mapa que arman
/// la base del futuro sistema de planeamiento de viajes:
///
/// - **EMPRESAS**: clientes (origen/destino del flete) + dadores de
///   transporte (otros transportistas que nos ceden cargas).
/// - **UBICACIONES**: puntos físicos de carga/descarga (silos, plantas,
///   puertos). Reusables entre tarifas.
/// - **TARIFAS**: rutas con precio (origen → destino, tarifa real +
///   tarifa chofer). El corazón del módulo.
/// - **MAPA**: vista geográfica de las tarifas activas con coords.
/// - **VIAJES**: ejecución y liquidación. Cada viaje apunta a una
///   tarifa snapshot inmutable + chofer + unidad.
///
/// Layout responsivo: en pantallas anchas (Windows desktop, iPad
/// landscape) muestra hasta 5 columnas con tiles compactos. En
/// celulares portrait, 2 columnas. Cada tile incluye contador en
/// vivo (StreamBuilder con la colección correspondiente).
class LogisticaHubScreen extends StatelessWidget {
  const LogisticaHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Logística',
      body: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BannerInfo(),
            const SizedBox(height: AppSpacing.lg),
            // El grid llena todo el alto disponible: número de columnas
            // según ancho + ratio de cada cell calculado según las
            // filas que toquen y el alto que sobre. Si no entra cómodo
            // (mobile chico + 3 filas), las cards se achican (clamp
            // 0.45..2.0); si tampoco así, el GridView scrollea por
            // dentro como fallback.
            Expanded(
              child: LayoutBuilder(
                builder: (ctx, constraints) {
                  // Decidir cuántas columnas según el ancho disponible.
                  // Threshold testeados a ojo en Windows desktop +
                  // tablet portrait + celular Android (Galaxy A8).
                  final w = constraints.maxWidth;
                  final int columnas;
                  if (w >= 1100) {
                    columnas = 5;
                  } else if (w >= 800) {
                    columnas = 4;
                  } else if (w >= 540) {
                    columnas = 3;
                  } else {
                    columnas = 2;
                  }
                  // 7 tiles: TARIFAS, EMPRESAS, UBICACIONES, MAPA,
                  // VIAJES, ADELANTOS, LIQUIDACIÓN. Si se suma o saca uno,
                  // ajustar acá Y la lista de _HubTile abajo.
                  const totalTiles = 7;
                  final filas = (totalTiles / columnas).ceil();
                  const spacing = AppSpacing.mdDense;
                  // Helper compartido — clamp 0.45..2.0 + fallback
                  // 1.05 (cuadrado-ish) si los constraints son
                  // inválidos (alto cero, etc).
                  final ratio = computeGridRatio(
                    boxWidth: constraints.maxWidth,
                    boxHeight: constraints.maxHeight,
                    cols: columnas,
                    rows: filas,
                    spacing: spacing,
                    fallback: 1.05,
                  );
                  return GridView.count(
                    crossAxisCount: columnas,
                    crossAxisSpacing: spacing,
                    mainAxisSpacing: spacing,
                    childAspectRatio: ratio,
                    children: [
                      _HubTile(
                        titulo: 'Tarifas',
                        subtitulo: 'Rutas con precio',
                        icono: Icons.price_change_outlined,
                        ruta: AppRoutes.adminLogisticaTarifas,
                        contador: _StreamCount(
                          coleccion: LogisticaService.tarifasCol,
                          soloActivas: true,
                        ),
                      ),
                      _HubTile(
                        titulo: 'Empresas',
                        subtitulo: 'Clientes y dadores',
                        icono: Icons.business_outlined,
                        ruta: AppRoutes.adminLogisticaEmpresas,
                        contador: _StreamCount(
                          coleccion: LogisticaService.empresasCol,
                          soloActivas: true,
                        ),
                      ),
                      _HubTile(
                        titulo: 'Ubicaciones',
                        subtitulo: 'Carga / descarga',
                        icono: Icons.place_outlined,
                        ruta: AppRoutes.adminLogisticaUbicaciones,
                        contador: _StreamCount(
                          coleccion: LogisticaService.ubicacionesCol,
                          soloActivas: true,
                        ),
                      ),
                      const _HubTile(
                        titulo: 'Mapa',
                        subtitulo: 'Vista geográfica',
                        icono: Icons.map_outlined,
                        ruta: AppRoutes.adminLogisticaMapaTarifas,
                      ),
                      _HubTile(
                        titulo: 'Viajes',
                        subtitulo: 'Ejecución de cada viaje',
                        icono: Icons.route_outlined,
                        ruta: AppRoutes.adminLogisticaViajes,
                        contador: _StreamCount(
                          coleccion: FirebaseFirestore.instance
                              .collection(AppCollections.viajesLogistica),
                          soloActivas: false,
                          campoActivo: 'activo',
                        ),
                      ),
                      _HubTile(
                        titulo: 'Adelantos',
                        subtitulo: 'Entregas al chofer',
                        icono: Icons.payments_outlined,
                        ruta: AppRoutes.adminLogisticaAdelantos,
                        // Adelantos no tiene flag "activa" — todos los
                        // docs son activos. Mostramos count total.
                        contador: _StreamCount(
                          coleccion: FirebaseFirestore.instance
                              .collection(AppCollections.adelantosChofer),
                          soloActivas: false,
                        ),
                      ),
                      const _HubTile(
                        titulo: 'Liquidación',
                        subtitulo: 'Resumen mensual + facturación',
                        icono: Icons.account_balance_wallet_outlined,
                        ruta: AppRoutes.adminLogisticaLiquidacion,
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

/// Banner informativo en la cabecera del hub. Aclara para qué sirve el
/// módulo y por qué hay catálogos antes que viajes. Card glow del sistema
/// (gesto firma) con eyebrow brand.
class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      glow: true,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Icon(Icons.insights_outlined, size: 16, color: c.brand),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const AppEyebrow('Base del futuro planeamiento de viajes'),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Cargá empresas y ubicaciones, después armá tarifas '
                  '(rutas con precio). Cuando arranque el módulo de '
                  'viajes, cada viaje va a apuntar a una tarifa.',
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile de navegación bento: icon chip indigo (única tinta) + título + sub +
/// contador en vivo en la esquina. Alineado a la izquierda — patrón de tile
/// de acción del sistema. El acento de color es siempre brand; lo semántico
/// queda para dots/badges de datos, no para chrome de navegación.
class _HubTile extends StatelessWidget {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final String ruta;
  final Widget? contador;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.ruta,
    this.contador,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(icono, size: 16, color: c.brand),
              ),
              const Spacer(),
              if (contador != null)
                contador!
              else
                Icon(Icons.arrow_outward, size: 14, color: c.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: AppType.h5.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                subtitulo,
                style: AppType.monoSm.copyWith(color: c.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Contador en vivo para el corner del tile. Muestra "30" si
/// soloActivas=true y hay 30 docs con activa==true. Se actualiza
/// solo cuando cambia la colección.
///
/// `campoActivo` permite usar este widget contra colecciones que usan
/// `activo` (Viajes) en lugar de `activa` (Empresas/Ubicaciones/Tarifas).
class _StreamCount extends StatelessWidget {
  final CollectionReference<Map<String, dynamic>> coleccion;
  final bool soloActivas;
  final String campoActivo;

  const _StreamCount({
    required this.coleccion,
    required this.soloActivas,
    this.campoActivo = 'activa',
  });

  Stream<int> _stream() {
    Query<Map<String, dynamic>> q = coleccion;
    if (soloActivas) q = q.where(campoActivo, isEqualTo: true);
    // .limit(999) cap defensivo — para mostrar el conteo no necesitamos
    // más, y limita el costo de lectura aunque haya miles de docs.
    return q.limit(999).snapshots().map((s) => s.docs.length);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<int>(
      stream: _stream(),
      builder: (ctx, snap) {
        final count = snap.data;
        final texto = count == null
            ? '—'
            : (count >= 999 ? '999+' : count.toString());
        return AppBadge(
          text: texto,
          color: c.brand,
          size: AppBadgeSize.sm,
        );
      },
    );
  }
}
