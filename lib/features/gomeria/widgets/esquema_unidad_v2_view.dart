import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../constants/posiciones.dart';
import '../models/estado_posicion.dart';
import '../models/nivel_desgaste.dart';

/// Vista esquemática de una unidad (tractor o enganche) desde arriba para el
/// modelo NUEVO de gomería (rediseño 2026-05-29). Es la versión V2 de
/// `EsquemaUnidadView`: en vez del modelo viejo `CubiertaInstalada` consume la
/// lista de `EstadoPosicion` (montaje + % vida + semáforo de desgaste).
///
/// Pensada para gomeros que NO son usuarios técnicos: el render foto-realista
/// de la unidad + un círculo tappeable por posición, coloreado por el semáforo
/// y con el % de vida en el centro. Tocar una posición dispara el mismo flujo
/// de montar/retirar de la pantalla (callback `onTapPosicion`).
///
/// Diseño del marker:
/// - Ocupada: anillo + relleno tenue del color del semáforo (verde dentro de
///   vida / amarillo cerca del límite / rojo pasado / gris sin datos), con el
///   % de vida en grande al centro.
/// - Vacía: anillo gris discontinuo, sutil — "acá puede ir una cubierta" sin
///   tapar el render.
///
/// Las coordenadas (x, y) en [0..1] están calibradas contra los renders
/// `assets/gomeria/*.webp` (640×800 tractor, 533×800 enganche). Son las mismas
/// que usa el esquema viejo; si se reemplazan las imágenes, recalibrar ambos.
class EsquemaUnidadV2View extends StatelessWidget {
  final TipoUnidadCubierta tipo;
  final List<EstadoPosicion> estados;
  final ValueChanged<EstadoPosicion> onTapPosicion;

  const EsquemaUnidadV2View({
    super.key,
    required this.tipo,
    required this.estados,
    required this.onTapPosicion,
  });

  @override
  Widget build(BuildContext context) {
    final esTractor = tipo == TipoUnidadCubierta.tractor;
    // Aspect ratio = ancho / alto del PNG (los 2 son verticales).
    final aspect = esTractor ? 640 / 800 : 533 / 800;
    final assetPath = esTractor
        ? 'assets/gomeria/tractor_top.webp'
        : 'assets/gomeria/enganche_top.webp';
    final coordsPorCodigo = esTractor ? _coordsTractor : _coordsEnganche;

    // Indexar los estados por código de posición para ubicarlos sobre el render.
    final estadoPorCodigo = <String, EstadoPosicion>{
      for (final e in estados) e.posicion.codigo: e,
    };

    // Cap del alto contra la pantalla REAL (no el viewport, que es unbounded
    // dentro de un scroll): el esquema ocupa como mucho ~58% del alto y queda
    // centrado, sin estirarse en desktop.
    final screenH = MediaQuery.of(context).size.height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 520,
          maxHeight: screenH * 0.58,
        ),
        child: AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              // Marker ~11% del ancho: visible y con lugar para el número.
              final markerSize = w * 0.11;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      assetPath,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  ...coordsPorCodigo.entries.map((entry) {
                    final estado = estadoPorCodigo[entry.key];
                    if (estado == null) return const SizedBox.shrink();
                    final coords = entry.value;
                    return Positioned(
                      left: coords.dx * w - markerSize / 2,
                      top: coords.dy * h - markerSize / 2,
                      width: markerSize,
                      height: markerSize,
                      child: _MarkerV2(
                        estado: estado,
                        onTap: () => onTapPosicion(estado),
                      ),
                    );
                  }),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Color _colorNivel(NivelDesgaste n) {
  switch (n) {
    case NivelDesgaste.ok:
      return Colors.green;
    case NivelDesgaste.alerta:
      return Colors.orange;
    case NivelDesgaste.critico:
      return Colors.red;
    case NivelDesgaste.sinDatos:
      return Colors.grey;
  }
}

// =============================================================================
// COORDS (x, y) en [0..1] sobre el Stack — calibradas vs los renders .webp
// =============================================================================

const Map<String, Offset> _coordsTractor = {
  'DIR_IZQ': Offset(0.13, 0.36),
  'DIR_DER': Offset(0.87, 0.36),
  'TRAC1_IZQ_EXT': Offset(0.09, 0.59),
  'TRAC1_IZQ_INT': Offset(0.25, 0.59),
  'TRAC1_DER_INT': Offset(0.75, 0.59),
  'TRAC1_DER_EXT': Offset(0.91, 0.59),
  'TRAC2_IZQ_EXT': Offset(0.09, 0.78),
  'TRAC2_IZQ_INT': Offset(0.25, 0.78),
  'TRAC2_DER_INT': Offset(0.75, 0.78),
  'TRAC2_DER_EXT': Offset(0.91, 0.78),
};

const Map<String, Offset> _coordsEnganche = {
  'ENG1_IZQ_EXT': Offset(0.10, 0.62),
  'ENG1_IZQ_INT': Offset(0.27, 0.62),
  'ENG1_DER_INT': Offset(0.73, 0.62),
  'ENG1_DER_EXT': Offset(0.90, 0.62),
  'ENG2_IZQ_EXT': Offset(0.10, 0.75),
  'ENG2_IZQ_INT': Offset(0.27, 0.75),
  'ENG2_DER_INT': Offset(0.73, 0.75),
  'ENG2_DER_EXT': Offset(0.90, 0.75),
  'ENG3_IZQ_EXT': Offset(0.10, 0.88),
  'ENG3_IZQ_INT': Offset(0.27, 0.88),
  'ENG3_DER_INT': Offset(0.73, 0.88),
  'ENG3_DER_EXT': Offset(0.90, 0.88),
};

// =============================================================================
// MARKER — anillo + % vida al centro, tappeable
// =============================================================================

class _MarkerV2 extends StatelessWidget {
  final EstadoPosicion estado;
  final VoidCallback onTap;

  const _MarkerV2({required this.estado, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final ocupada = estado.ocupada;
    final color = ocupada
        ? _colorNivel(estado.nivel)
        : Colors.white.withValues(alpha: 0.55);
    final pct = estado.porcentajeVida;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: color.withValues(alpha: 0.30),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: CustomPaint(
                painter: _MarkerPainterV2(color: color, ocupada: ocupada),
              ),
            ),
            // % de vida al centro de las ocupadas que tienen dato.
            if (ocupada && pct != null)
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Text(
                    '${pct.round()}',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.bold,
                      height: 1.0,
                      shadows: const [
                        Shadow(color: Colors.white, blurRadius: 3),
                      ],
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

class _MarkerPainterV2 extends CustomPainter {
  final Color color;
  final bool ocupada;

  _MarkerPainterV2({required this.color, required this.ocupada});

  @override
  void paint(Canvas canvas, Size size) {
    final centro = Offset(size.width / 2, size.height / 2);
    final radio = size.width / 2 - 1;

    if (ocupada) {
      // Halo para destacar el anillo sobre el render.
      final halo = Paint()
        ..color = color.withValues(alpha: 0.40)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(centro, radio, halo);

      // Relleno tenue: deja ver la rueda real teñida con el color de estado.
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.30);
      canvas.drawCircle(centro, radio - 1, fill);

      // Anillo sólido.
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.6
        ..color = color;
      canvas.drawCircle(centro, radio - 1, ring);
    } else {
      // Vacía: anillo gris discontinuo, sutil.
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color;
      _circuloDiscontinuo(canvas, centro, radio - 1, stroke);
    }
  }

  void _circuloDiscontinuo(
      Canvas canvas, Offset centro, double radio, Paint paint) {
    const dashArc = 0.35;
    const gapArc = 0.22;
    var ang = 0.0;
    while (ang < 2 * math.pi) {
      final path = Path()
        ..addArc(
          Rect.fromCircle(center: centro, radius: radio),
          ang,
          math.min(dashArc, 2 * math.pi - ang),
        );
      canvas.drawPath(path, paint);
      ang += dashArc + gapArc;
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerPainterV2 old) =>
      old.color != color || old.ocupada != ocupada;
}
