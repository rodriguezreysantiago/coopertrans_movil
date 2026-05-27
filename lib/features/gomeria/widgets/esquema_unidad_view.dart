import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_instalada.dart';

/// Vista esquemática de una unidad (tractor o enganche) desde arriba.
/// Usa render foto-realista (PNG B/N en `assets/gomeria/`) como fondo
/// y overlay tappeable de cubiertas como `Positioned` widgets.
///
/// Cada cubierta se posiciona en coordenadas relativas (% del ancho/
/// alto del Stack) calibradas contra las posiciones reales de las
/// ruedas en la imagen. El tap abre el dialog de instalación / acciones
/// (mismo callback que la versión vieja).
///
/// Diseño visual:
/// - Cubierta ocupada: anillo coloreado por % vida útil consumida
///   (verde <80% / naranja 80-99% / rojo ≥100%) con glow para resaltar
///   sobre el render. Centro semi-transparente para ver la rueda real
///   abajo.
/// - Cubierta vacía: anillo gris discontinuo, casi imperceptible
///   (señal sutil "acá puede ir una cubierta" sin estorbar).
/// - Badge "L" en la esquina superior izquierda del marker → cubierta
///   cohort 1 legacy (sin datos previos confiables).
class EsquemaUnidadView extends StatelessWidget {
  final TipoUnidadCubierta tipo;
  final Map<String, CubiertaInstalada> instaladas;
  final double? kmActualUnidad;
  final ValueChanged<PosicionCubierta> onTapPosicion;

  const EsquemaUnidadView({
    super.key,
    required this.tipo,
    required this.instaladas,
    required this.kmActualUnidad,
    required this.onTapPosicion,
  });

  @override
  Widget build(BuildContext context) {
    final esTractor = tipo == TipoUnidadCubierta.tractor;
    // Aspect ratio = ancho / alto del PNG (los 2 son verticales).
    // Tractor: 640/800 (~0.80). Enganche: 533/800 (~0.67).
    final aspect = esTractor ? 640 / 800 : 533 / 800;
    final assetPath = esTractor
        ? 'assets/gomeria/tractor_top.webp'
        : 'assets/gomeria/enganche_top.webp';
    final mapaPos = esTractor ? _posicionesTractor : _posicionesEnganche;

    // Cap del tamaño usando el alto REAL de la pantalla, no el alto
    // del viewport (que es unbounded porque el padre es un
    // SingleChildScrollView). Sin este cap, el AspectRatio toma todo
    // el ancho disponible y la imagen sale gigante en desktop:
    // 1500 px ancho / 0.67 ≈ 2240 px alto. Con el cap, el esquema
    // ocupa como mucho ~65% del alto de pantalla y queda centrado.
    //
    // El maxWidth 600 es defensivo para pantallas ultra-anchas: en la
    // práctica el ratio vertical hace que el limitante sea siempre el
    // alto, pero evita que en algún caso raro el esquema se estire.
    final screenH = MediaQuery.of(context).size.height;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 600,
          maxHeight: screenH * 0.65,
        ),
        child: AspectRatio(
          aspectRatio: aspect,
          child: LayoutBuilder(
            builder: (ctx, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              // Tamaño del marker proporcional al ancho. ~9% es un buen
              // balance: visible sin tapar la rueda completa.
              final markerSize = w * 0.095;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Fondo: render foto-realista de la unidad.
                  Positioned.fill(
                    child: Image.asset(
                      assetPath,
                      fit: BoxFit.contain,
                      filterQuality: FilterQuality.medium,
                    ),
                  ),
                  // Overlay de cubiertas, una por posición física.
                  ...mapaPos.entries.map((e) {
                    final pos = posicionPorCodigo[e.key]!;
                    final instalada = instaladas[e.key];
                    final coords = e.value;
                    return Positioned(
                      left: coords.dx * w - markerSize / 2,
                      top: coords.dy * h - markerSize / 2,
                      width: markerSize,
                      height: markerSize,
                      child: _MarkerCubierta(
                        posicion: pos,
                        instalada: instalada,
                        kmActualUnidad: kmActualUnidad,
                        onTap: () => onTapPosicion(pos),
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

// =============================================================================
// MAPAS DE POSICIONES — coords (x, y) en [0..1] sobre el Stack
// =============================================================================
//
// Calibradas visualmente contra los renders foto-realistas en
// `assets/gomeria/*.webp` (640×800 tractor, 533×800 enganche). Si las
// imágenes se reemplazan, recalibrar.

const Map<String, Offset> _posicionesTractor = {
  // Eje 1 — DIRECCIÓN (2 cubiertas simples, fuera del chasis).
  'DIR_IZQ': Offset(0.13, 0.36),
  'DIR_DER': Offset(0.87, 0.36),
  // Eje 2 — TRACCIÓN DUAL (4 cubiertas).
  'TRAC1_IZQ_EXT': Offset(0.09, 0.59),
  'TRAC1_IZQ_INT': Offset(0.25, 0.59),
  'TRAC1_DER_INT': Offset(0.75, 0.59),
  'TRAC1_DER_EXT': Offset(0.91, 0.59),
  // Eje 3 — TRACCIÓN DUAL (4 cubiertas).
  'TRAC2_IZQ_EXT': Offset(0.09, 0.78),
  'TRAC2_IZQ_INT': Offset(0.25, 0.78),
  'TRAC2_DER_INT': Offset(0.75, 0.78),
  'TRAC2_DER_EXT': Offset(0.91, 0.78),
};

const Map<String, Offset> _posicionesEnganche = {
  // 3 ejes tracción dual (4 cubiertas cada uno = 12).
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
// MARKER — anillo + badge, tappeable
// =============================================================================

class _MarkerCubierta extends StatelessWidget {
  final PosicionCubierta posicion;
  final CubiertaInstalada? instalada;
  final double? kmActualUnidad;
  final VoidCallback onTap;

  const _MarkerCubierta({
    required this.posicion,
    required this.instalada,
    required this.kmActualUnidad,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ocupada = instalada != null;
    final color = ocupada
        ? _colorVida(instalada!.porcentajeVidaConsumida(
            kmActualUnidad: kmActualUnidad))
        : Colors.white.withValues(alpha: 0.55);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        splashColor: color.withValues(alpha: 0.30),
        child: CustomPaint(
          painter: _MarkerPainter(
            color: color,
            ocupada: ocupada,
            esLegacy: instalada?.legacyInicial == true,
          ),
        ),
      ),
    );
  }

  Color _colorVida(double? pct) {
    if (pct == null) return AppColors.success;
    if (pct >= 100) return AppColors.accentRed;
    if (pct >= 80) return AppColors.warning;
    return AppColors.success;
  }
}

class _MarkerPainter extends CustomPainter {
  final Color color;
  final bool ocupada;
  final bool esLegacy;

  _MarkerPainter({
    required this.color,
    required this.ocupada,
    required this.esLegacy,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centro = Offset(size.width / 2, size.height / 2);
    final radio = size.width / 2 - 1;

    if (ocupada) {
      // Halo glow externo para que el ring se destaque sobre el render.
      final halo = Paint()
        ..color = color.withValues(alpha: 0.40)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawCircle(centro, radio, halo);

      // Centro semi-transparente: deja ver la rueda foto-realista de
      // fondo, pero teñida con el color de estado.
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = color.withValues(alpha: 0.28);
      canvas.drawCircle(centro, radio - 1, fill);

      // Anillo sólido del color del estado.
      final ring = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = color;
      canvas.drawCircle(centro, radio - 1, ring);

      // Badge "L" — esquina superior izquierda.
      if (esLegacy) {
        _pintarBadgeLegacy(canvas, size);
      }
    } else {
      // Vacía: anillo discontinuo gris claro, sutil. Indica que ahí
      // PUEDE ir una cubierta sin estorbar el render del fondo.
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color;
      _dibujarCirculoDiscontinuo(canvas, centro, radio - 1, stroke);
    }
  }

  void _pintarBadgeLegacy(Canvas canvas, Size size) {
    final r = size.width * 0.20;
    // Esquina superior izquierda, ligeramente afuera del ring para
    // evitar tapar el centro.
    final centro = Offset(size.width * 0.18, size.height * 0.18);
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.black.withValues(alpha: 0.78);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9
      ..color = Colors.white.withValues(alpha: 0.95);
    canvas.drawCircle(centro, r, fill);
    canvas.drawCircle(centro, r, stroke);
    final tp = TextPainter(
      text: TextSpan(
        text: 'L',
        style: TextStyle(
          color: Colors.white,
          fontSize: r * 1.5,
          fontWeight: FontWeight.bold,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset(centro.dx - tp.width / 2, centro.dy - tp.height / 2),
    );
  }

  void _dibujarCirculoDiscontinuo(
      Canvas canvas, Offset centro, double radio, Paint paint) {
    const dashArc = 0.35; // radianes por dash
    const gapArc = 0.22; // radianes por gap
    var ang = 0.0;
    while (ang < 2 * math.pi) {
      final start = ang;
      final end = math.min(ang + dashArc, 2 * math.pi);
      final path = Path()
        ..addArc(
          Rect.fromCircle(center: centro, radius: radio),
          start,
          end - start,
        );
      canvas.drawPath(path, paint);
      ang += dashArc + gapArc;
    }
  }

  @override
  bool shouldRepaint(covariant _MarkerPainter old) {
    return old.color != color ||
        old.ocupada != ocupada ||
        old.esLegacy != esLegacy;
  }
}
