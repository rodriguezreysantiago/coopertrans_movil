// lib/features/expirations/screens/admin_vencimientos_menu_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — menú de auditoría de vencimientos en bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - las rutas de navegación de cada tile (AppRoutes / rutas string),
//   - el badge en vivo de REVISIONES (mismo stream que el tab "Vencimientos"
//     del shell: REVISIONES con estado=PENDIENTE, .limit(100)),
//   - el set de 6 tiles y su orden + el corte por grupo ("auditoría" vs
//     "POR EMPRESA EMPLEADORA").
//
// Layout Núcleo (mismo lenguaje que `icm_hub_screen.dart` /
// `logistica_hub_screen.dart`): header eyebrow + h2 + bajada, grilla bento
// de tiles (icon chip indigo · única tinta de navegación · arrow_outward),
// y un segundo bloque etiquetado para el ABM por empresa empleadora. El
// badge de REVISIONES es semántico (rojo = bandeja con cosas esperando
// acción): mantiene el "rojo afuera = rojo adentro" del shell.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Menú principal de auditoría de vencimientos.
class AdminVencimientosMenuScreen extends StatelessWidget {
  const AdminVencimientosMenuScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Auditoría de Vencimientos',
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          // ─── Header ───
          const AppEyebrow('Auditoría preventiva · 60 días'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Vencimientos',
            style: AppType.h2.copyWith(color: c.text),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Control proactivo de documentación próxima a vencer.',
            style: AppType.bodySm.copyWith(color: c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xl),

          // ─── Auditorías por persona / unidad ───
          // REVISIONES movido acá 2026-05-24 (estaba como tab propio del
          // shell). Conceptualmente vive con vencimientos: el chofer carga
          // un trámite que vence pronto, el admin lo aprueba o lo rechaza
          // desde acá. Va primero porque es la acción más urgente del día
          // (cosas en bandeja esperando aprobación).
          //
          // Badge con el mismo stream que el tab "Vencimientos" del shell
          // (admin_shell.dart línea ~103): así el rojo afuera y el rojo
          // adentro apuntan al mismo lugar y se sabe qué responder.
          _TileGrid(tiles: [
            _MenuTileData(
              titulo: 'Revisiones',
              subtitulo: 'Aprobar/rechazar trámites cargados por choferes',
              icono: Icons.fact_check_outlined,
              ruta: AppRoutes.adminRevisiones,
              badgeStream: FirebaseFirestore.instance
                  .collection(AppCollections.revisiones)
                  .where('estado', isEqualTo: 'PENDIENTE')
                  .limit(100)
                  .snapshots(),
            ),
            const _MenuTileData(
              titulo: 'Calendario mensual',
              subtitulo: 'Vista global con todos los vencimientos por día',
              icono: Icons.event_note,
              ruta: '/vencimientos_calendario',
            ),
            const _MenuTileData(
              titulo: 'Vencimientos de personal',
              subtitulo: 'Seguimiento de carnets, preocupacional y ART',
              icono: Icons.person_search,
              ruta: '/vencimientos_choferes',
            ),
            const _MenuTileData(
              titulo: 'Vencimientos de tractores',
              subtitulo: 'Control de RTO y seguros de camiones',
              icono: Icons.local_shipping,
              ruta: '/vencimientos_chasis',
            ),
            const _MenuTileData(
              titulo: 'Vencimientos de enganches',
              subtitulo: 'Auditoría de bateas, tolvas, bivuelcos y tanques',
              icono: Icons.grid_view,
              ruta: '/vencimientos_acoplados',
            ),
          ]),

          // ─── ABM por empresa empleadora ───
          // Visualmente separado: arriba son auditorías por persona /
          // unidad; este es ABM de docs comunes a todos los empleados de
          // una misma razón social (Póliza ART y Formulario 931).
          const SizedBox(height: AppSpacing.xl),
          const AppEyebrow('Por empresa empleadora'),
          const SizedBox(height: AppSpacing.md),
          const _TileGrid(tiles: [
            _MenuTileData(
              titulo: 'Empresas y seguros',
              subtitulo: 'Póliza ART y Formulario 931 por razón social',
              icono: Icons.business_outlined,
              ruta: AppRoutes.adminEmpresasEmpleadoras,
            ),
          ]),

          const SizedBox(height: AppSpacing.xxl),
          const Center(
            child: AppEyebrow('${AppTexts.appName} — Gestión de Flota'),
          ),
        ],
      ),
    );
  }
}

/// Datos de un tile del menú. Inmutable, sin lógica — el render lo hace
/// `_MenuTile`.
class _MenuTileData {
  final String titulo;
  final String subtitulo;
  final IconData icono;
  final String ruta;

  /// Si está seteado, se renderiza un badge rojo con el count del stream en
  /// la esquina del tile (sólo cuando count > 0) — mismo patrón que
  /// `admin_shell.dart` usa en el rail. El rojo (no brand) es deliberado:
  /// es bandeja de cosas esperando acción, no un contador neutro.
  final Stream<QuerySnapshot>? badgeStream;

  const _MenuTileData({
    required this.titulo,
    required this.subtitulo,
    required this.icono,
    required this.ruta,
    this.badgeStream,
  });
}

/// Grilla bento responsive de tiles del menú. Mismo cálculo de columnas +
/// ratio que los hubs Núcleo (`responsive_grid.dart`), pero con
/// `shrinkWrap` porque vive dentro de un ListView con dos bloques.
class _TileGrid extends StatelessWidget {
  final List<_MenuTileData> tiles;
  const _TileGrid({required this.tiles});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        // Desktop/tablet anchos hasta 4 columnas; mobile portrait 1.
        final int columnas;
        if (w >= 1100) {
          columnas = 4;
        } else if (w >= 800) {
          columnas = 3;
        } else if (w >= 540) {
          columnas = 2;
        } else {
          columnas = 1;
        }
        const spacing = AppSpacing.mdDense;
        final filas = (tiles.length / columnas).ceil();
        // Alto estimado por celda: el grid no llena el viewport (es
        // shrinkWrap dentro de un ListView), así que fijamos un ratio
        // según el ancho real de la celda y un alto objetivo cómodo
        // (~120 px para que entren icono + título + sub sin overflow).
        final cellWidth = (w - spacing * (columnas - 1)) / columnas;
        final ratio = computeGridRatio(
          boxWidth: w,
          boxHeight: filas * 120 + spacing * (filas - 1),
          cols: columnas,
          rows: filas,
          spacing: spacing,
          fallback: cellWidth > 0 ? (cellWidth / 120).clamp(0.45, 2.0) : 1.6,
        );
        return GridView.count(
          crossAxisCount: columnas,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: spacing,
          mainAxisSpacing: spacing,
          childAspectRatio: ratio,
          children: [
            for (final t in tiles) _MenuTile(data: t),
          ],
        );
      },
    );
  }
}

/// Tile de navegación bento: icon chip indigo (única tinta) + título + sub.
/// Alineado a la izquierda — patrón de tile de acción del sistema
/// (`icm_hub_screen.dart` / `logistica_hub_screen.dart`). El acento de
/// color es siempre brand; lo semántico queda para el badge de datos.
class _MenuTile extends StatelessWidget {
  final _MenuTileData data;
  const _MenuTile({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => Navigator.pushNamed(context, data.ruta),
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
                child: Icon(data.icono, size: 16, color: c.brand),
              ),
              const Spacer(),
              if (data.badgeStream != null)
                _BadgeCount(stream: data.badgeStream!)
              else
                Icon(Icons.arrow_outward, size: 14, color: c.textMuted),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                data.titulo,
                style: AppType.h5.copyWith(color: c.text),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                data.subtitulo,
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

/// Badge rojo en la esquina del tile con el count del stream. Sólo se
/// muestra cuando hay >= 1 (igual que el badge del rail en `admin_shell`):
/// si no hay pendientes, no ensucia el tile.
class _BadgeCount extends StatelessWidget {
  final Stream<QuerySnapshot> stream;
  const _BadgeCount({required this.stream});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (ctx, snap) {
        final count = snap.data?.docs.length ?? 0;
        if (count == 0) {
          // Sin pendientes → flecha neutra, igual que un tile sin badge.
          return Icon(Icons.arrow_outward, size: 14, color: c.textMuted);
        }
        return AppBadge(
          text: count > 99 ? '99+' : '$count',
          color: c.error,
          solid: true,
          size: AppBadgeSize.sm,
        );
      },
    );
  }
}
