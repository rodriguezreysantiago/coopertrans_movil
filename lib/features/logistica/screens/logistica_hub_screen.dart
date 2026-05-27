import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/logistica_service.dart';

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
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _BannerInfo(),
            const SizedBox(height: 16),
            // El grid llena todo el alto disponible: número de columnas
            // según ancho + ratio de cada cell calculado según las
            // filas que toquen y el alto que sobre. Si no entra cómodo
            // (mobile chico + 3 filas), las cards se achican (clamp
            // 0.45..2.0); si tampoco así, el GridView scrollea por
            // dentro como fallback. Antes era ratio 1.05 fijo dentro
            // de SingleChildScrollView → scroll obligado siempre.
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
                  const spacing = 12.0;
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
                      titulo: 'TARIFAS',
                      subtitulo: 'Rutas con precio',
                      icono: Icons.price_change_outlined,
                      color: AppColors.success,
                      ruta: AppRoutes.adminLogisticaTarifas,
                      contador: _StreamCount(
                        coleccion:
                            LogisticaService.tarifasCol,
                        soloActivas: true,
                        color: AppColors.success,
                      ),
                    ),
                    _HubTile(
                      titulo: 'EMPRESAS',
                      subtitulo: 'Clientes y dadores',
                      icono: Icons.business_outlined,
                      color: AppColors.accentBlue,
                      ruta: AppRoutes.adminLogisticaEmpresas,
                      contador: _StreamCount(
                        coleccion:
                            LogisticaService.empresasCol,
                        soloActivas: true,
                        color: AppColors.accentBlue,
                      ),
                    ),
                    _HubTile(
                      titulo: 'UBICACIONES',
                      subtitulo: 'Carga / descarga',
                      icono: Icons.place_outlined,
                      color: AppColors.accentTeal,
                      ruta: AppRoutes.adminLogisticaUbicaciones,
                      contador: _StreamCount(
                        coleccion:
                            LogisticaService.ubicacionesCol,
                        soloActivas: true,
                        color: AppColors.accentTeal,
                      ),
                    ),
                    const _HubTile(
                      titulo: 'MAPA',
                      subtitulo: 'Vista geográfica',
                      icono: Icons.map_outlined,
                      color: AppColors.warning,
                      ruta: AppRoutes.adminLogisticaMapaTarifas,
                    ),
                    _HubTile(
                      titulo: 'VIAJES',
                      subtitulo: 'Ejecución de cada viaje',
                      icono: Icons.route_outlined,
                      color: AppColors.warning,
                      ruta: AppRoutes.adminLogisticaViajes,
                      contador: _StreamCount(
                        coleccion: FirebaseFirestore.instance
                            .collection(AppCollections.viajesLogistica),
                        soloActivas: false,
                        color: AppColors.warning,
                        campoActivo: 'activo',
                      ),
                    ),
                    _HubTile(
                      titulo: 'ADELANTOS',
                      subtitulo: 'Entregas al chofer',
                      icono: Icons.payments_outlined,
                      color: AppColors.accentBlue,
                      ruta: AppRoutes.adminLogisticaAdelantos,
                      // Adelantos no tiene flag "activa" — todos los
                      // docs son activos. Mostramos count total.
                      contador: _StreamCount(
                        coleccion: FirebaseFirestore.instance
                            .collection(AppCollections.adelantosChofer),
                        soloActivas: false,
                        color: AppColors.accentBlue,
                      ),
                    ),
                    const _HubTile(
                      titulo: 'LIQUIDACIÓN',
                      subtitulo: 'Resumen mensual + facturación',
                      icono: Icons.account_balance_wallet_outlined,
                      color: AppColors.success,
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
/// módulo y por qué hay catálogos antes que viajes.
class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.4)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline,
              color: AppColors.success, size: 26),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'BASE DEL FUTURO PLANEAMIENTO DE VIAJES',
                  style: TextStyle(
                    color: AppColors.success,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Cargá empresas y ubicaciones, después armá tarifas '
                  '(rutas con precio). Cuando arranque el módulo de '
                  'viajes, cada viaje va a apuntar a una tarifa.',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
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
  final Widget? contador;

  const _HubTile({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.color,
    required this.ruta,
    this.contador,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => Navigator.pushNamed(context, ruta),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icono, size: 26, color: color),
              const Spacer(),
              if (contador != null) contador!,
            ],
          ),
          const SizedBox(height: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                titulo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                subtitulo,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                ),
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
  final Color color;
  final String campoActivo;

  const _StreamCount({
    required this.coleccion,
    required this.soloActivas,
    required this.color,
    this.campoActivo = 'activa',
  });

  Stream<int> _stream() {
    Query<Map<String, dynamic>> q = coleccion;
    if (soloActivas) q = q.where(campoActivo, isEqualTo: true);
    // .limit(999) cap defensivo — para mostrar el conteo no necesitamos
    // más, y limita el costo de lectura aunque haya miles de docs.
    return q
        .limit(999)
        .snapshots()
        .map((s) => s.docs.length);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<int>(
      stream: _stream(),
      builder: (ctx, snap) {
        final count = snap.data;
        final texto = count == null
            ? '—'
            : (count >= 999 ? '999+' : count.toString());
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Text(
            texto,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
      },
    );
  }
}
