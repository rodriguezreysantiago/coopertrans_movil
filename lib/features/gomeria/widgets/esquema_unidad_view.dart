import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_instalada.dart';

/// Vista esquemática de una unidad (tractor o enganche) desde arriba,
/// dibujada con CustomPainter. Cada cubierta se renderea en su posición
/// física real, con un patrón de banda de rodadura distinto según sea
/// dirección (chevrons) o tracción (tacos), y un color de borde según
/// el % de vida útil consumida.
///
/// Tap en cubierta → abre el flujo de acciones del operador (mismo
/// callback que la vista de listas previa).
///
/// Layout 100% real de la flota Coopertrans:
/// - Tractor 6×4 (10 cubiertas): 1 eje direccional + 2 ejes tracción dual.
/// - Enganche tridem (12 cubiertas): 3 ejes tracción dual.
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
    // Aspect ratio (ancho / alto). El enganche es más largo que el
    // tractor (3 ejes traseros + caja), por eso ratio menor.
    final aspect = tipo == TipoUnidadCubierta.tractor ? 0.58 : 0.42;
    return AspectRatio(
      aspectRatio: aspect,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final layout = _EsquemaLayout(tipo: tipo, size: size);
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (details) {
              final p = layout.posicionEnPunto(details.localPosition);
              if (p != null) onTapPosicion(p);
            },
            child: CustomPaint(
              size: size,
              painter: _EsquemaUnidadPainter(
                tipo: tipo,
                layout: layout,
                instaladas: instaladas,
                kmActualUnidad: kmActualUnidad,
              ),
            ),
          );
        },
      ),
    );
  }
}

// =============================================================================
// LAYOUT — coordenadas proporcionales reusadas por painter + hit-test
// =============================================================================

/// Calcula la geometría del esquema (silueta del chasis + posiciones de
/// cada cubierta) dado un [size]. Usado tanto por el painter (para
/// dibujar) como por el GestureDetector (para hit-test).
class _EsquemaLayout {
  final TipoUnidadCubierta tipo;
  final Size size;

  /// Mapa `codigo posición → Rect` de cada cubierta.
  late final Map<String, Rect> rectsCubiertas = _calcularRectsCubiertas();

  /// Silueta del chasis (cabina + cuerpo). Se dibuja como Path.
  late final Path siluetaChasis = _calcularSilueta();

  /// Centros de los ejes (línea horizontal fina que une las cubiertas
  /// del mismo eje, opcional decorativo).
  late final List<double> ysEjes = _calcularYsEjes();

  /// Centro y radio de la quinta rueda (solo tractor).
  late final ({Offset centro, double radio})? kingpin = _calcularKingpin();

  _EsquemaLayout({required this.tipo, required this.size});

  /// Devuelve la posición tappeada o null si el tap fue afuera.
  PosicionCubierta? posicionEnPunto(Offset punto) {
    for (final entry in rectsCubiertas.entries) {
      // Margen de 4 px alrededor del rect para que el tap sea cómodo.
      if (entry.value.inflate(4).contains(punto)) {
        return posicionPorCodigo[entry.key];
      }
    }
    return null;
  }

  // ---- cálculo de geometrías --------------------------------------------

  Map<String, Rect> _calcularRectsCubiertas() {
    final w = size.width;
    final h = size.height;

    // Dimensiones de cubierta (proporcionales al ancho del canvas).
    // Más altas que anchas para evocar el rectángulo de la rueda visto
    // desde arriba.
    final cubW = w * 0.10;
    final cubH = w * 0.13;
    // Gap entre las dos ruedas internas/externas de un par dual.
    final gapDual = w * 0.005;

    final mapa = <String, Rect>{};

    if (tipo == TipoUnidadCubierta.tractor) {
      // EJE 1 — DIRECCIÓN (2 cubiertas simples, fuera del chasis).
      final y1 = h * 0.30;
      mapa[posTractorDirIzq.codigo] =
          _rectCentrado(w * 0.16, y1, cubW, cubH);
      mapa[posTractorDirDer.codigo] =
          _rectCentrado(w * 0.84, y1, cubW, cubH);

      // EJE 2 — TRACCIÓN DUAL.
      final y2 = h * 0.62;
      _ponerDual(mapa, y2, cubW, cubH, gapDual,
          codIzqExt: posTractorTrac1IzqExt.codigo,
          codIzqInt: posTractorTrac1IzqInt.codigo,
          codDerInt: posTractorTrac1DerInt.codigo,
          codDerExt: posTractorTrac1DerExt.codigo);

      // EJE 3 — TRACCIÓN DUAL (eje neumático).
      final y3 = h * 0.86;
      _ponerDual(mapa, y3, cubW, cubH, gapDual,
          codIzqExt: posTractorTrac2IzqExt.codigo,
          codIzqInt: posTractorTrac2IzqInt.codigo,
          codDerInt: posTractorTrac2DerInt.codigo,
          codDerExt: posTractorTrac2DerExt.codigo);
    } else {
      // ENGANCHE — 3 ejes tracción dual.
      final ys = [h * 0.45, h * 0.65, h * 0.85];
      for (var i = 0; i < 3; i++) {
        final eje = i + 1;
        _ponerDual(mapa, ys[i], cubW, cubH, gapDual,
            codIzqExt: 'ENG${eje}_IZQ_EXT',
            codIzqInt: 'ENG${eje}_IZQ_INT',
            codDerInt: 'ENG${eje}_DER_INT',
            codDerExt: 'ENG${eje}_DER_EXT');
      }
    }
    return mapa;
  }

  void _ponerDual(
    Map<String, Rect> mapa,
    double y,
    double cubW,
    double cubH,
    double gap, {
    required String codIzqExt,
    required String codIzqInt,
    required String codDerInt,
    required String codDerExt,
  }) {
    final w = size.width;
    // Posiciones x (centros) de las 4 cubiertas de un eje dual.
    // Las internas pegadas al chasis, las externas afuera.
    final xIzqExt = w * 0.10;
    final xIzqInt = w * 0.10 + cubW + gap;
    final xDerInt = w * 0.90 - cubW - gap;
    final xDerExt = w * 0.90;
    mapa[codIzqExt] = _rectCentrado(xIzqExt, y, cubW, cubH);
    mapa[codIzqInt] = _rectCentrado(xIzqInt, y, cubW, cubH);
    mapa[codDerInt] = _rectCentrado(xDerInt, y, cubW, cubH);
    mapa[codDerExt] = _rectCentrado(xDerExt, y, cubW, cubH);
  }

  Rect _rectCentrado(double cx, double cy, double w, double h) {
    return Rect.fromCenter(center: Offset(cx, cy), width: w, height: h);
  }

  Path _calcularSilueta() {
    final w = size.width;
    final h = size.height;
    final path = Path();

    if (tipo == TipoUnidadCubierta.tractor) {
      // Cabina (parte superior, más ancha y con esquinas más
      // redondeadas) — desde y=0.02 hasta y=0.22.
      final cabina = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.27, h * 0.02, w * 0.46, h * 0.20),
        const Radius.circular(8),
      );
      // Chasis principal (parte inferior, más angosto, hasta el final).
      final chasis = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.32, h * 0.20, w * 0.36, h * 0.78),
        const Radius.circular(4),
      );
      path
        ..addRRect(cabina)
        ..addRRect(chasis);
    } else {
      // Enganche — caja larga + trompa pequeña arriba para evocar la
      // conexión a la quinta rueda.
      final trompa = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.42, h * 0.02, w * 0.16, h * 0.06),
        const Radius.circular(3),
      );
      final caja = RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.18, h * 0.08, w * 0.64, h * 0.90),
        const Radius.circular(6),
      );
      path
        ..addRRect(caja)
        ..addRRect(trompa);
    }
    return path;
  }

  List<double> _calcularYsEjes() {
    if (tipo == TipoUnidadCubierta.tractor) {
      return [size.height * 0.30, size.height * 0.62, size.height * 0.86];
    } else {
      return [size.height * 0.45, size.height * 0.65, size.height * 0.85];
    }
  }

  ({Offset centro, double radio})? _calcularKingpin() {
    if (tipo != TipoUnidadCubierta.tractor) return null;
    return (
      centro: Offset(size.width * 0.50, size.height * 0.74),
      radio: size.width * 0.05,
    );
  }
}

// =============================================================================
// PAINTER
// =============================================================================

class _EsquemaUnidadPainter extends CustomPainter {
  final TipoUnidadCubierta tipo;
  final _EsquemaLayout layout;
  final Map<String, CubiertaInstalada> instaladas;
  final double? kmActualUnidad;

  _EsquemaUnidadPainter({
    required this.tipo,
    required this.layout,
    required this.instaladas,
    required this.kmActualUnidad,
  });

  @override
  void paint(Canvas canvas, Size size) {
    _pintarChasis(canvas);
    _pintarEjes(canvas);
    _pintarKingpin(canvas);
    _pintarCubiertas(canvas);
  }

  // ---- chasis -----------------------------------------------------------

  void _pintarChasis(Canvas canvas) {
    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawPath(layout.siluetaChasis, fill);
    canvas.drawPath(layout.siluetaChasis, stroke);
  }

  // ---- ejes (líneas finas que unen cubiertas del mismo eje) ------------

  void _pintarEjes(Canvas canvas) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..strokeWidth = 1.3;
    for (final y in layout.ysEjes) {
      canvas.drawLine(
        Offset(layout.size.width * 0.06, y),
        Offset(layout.size.width * 0.94, y),
        paint,
      );
    }
  }

  // ---- quinta rueda (solo tractor) -------------------------------------

  void _pintarKingpin(Canvas canvas) {
    final kp = layout.kingpin;
    if (kp == null) return;
    final fill = Paint()
      ..color = Colors.white.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(kp.centro, kp.radio, fill);
    canvas.drawCircle(kp.centro, kp.radio, stroke);
    // Cruz interna de la quinta rueda.
    canvas.drawLine(
      Offset(kp.centro.dx - kp.radio * 0.7, kp.centro.dy),
      Offset(kp.centro.dx + kp.radio * 0.7, kp.centro.dy),
      stroke,
    );
    canvas.drawLine(
      Offset(kp.centro.dx, kp.centro.dy - kp.radio * 0.7),
      Offset(kp.centro.dx, kp.centro.dy + kp.radio * 0.7),
      stroke,
    );
  }

  // ---- cubiertas -------------------------------------------------------

  void _pintarCubiertas(Canvas canvas) {
    layout.rectsCubiertas.forEach((codigo, rect) {
      final pos = posicionPorCodigo[codigo]!;
      final instalada = instaladas[codigo];
      _pintarCubierta(canvas, rect, pos, instalada);
    });
  }

  void _pintarCubierta(
    Canvas canvas,
    Rect rect,
    PosicionCubierta posicion,
    CubiertaInstalada? instalada,
  ) {
    final esDireccional = posicion.tipoUsoRequerido == TipoUsoCubierta.direccion;
    final ocupada = instalada != null;
    final color = ocupada
        ? _colorVida(instalada.porcentajeVidaConsumida(
            kmActualUnidad: kmActualUnidad))
        : Colors.white.withValues(alpha: 0.30);

    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(3));

    // Fill semitransparente (más fuerte si está ocupada).
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = ocupada
          ? color.withValues(alpha: 0.16)
          : Colors.white.withValues(alpha: 0.03);
    canvas.drawRRect(rrect, fill);

    // Stroke con el color de estado. Discontinuo si está vacía.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ocupada ? 1.6 : 1.0
      ..color = color;
    if (ocupada) {
      canvas.drawRRect(rrect, stroke);
    } else {
      _dibujarRRectDiscontinuo(canvas, rrect, stroke);
    }

    // Patrón interno de banda de rodadura (solo si está ocupada — una
    // cubierta vacía no tiene goma).
    if (ocupada) {
      if (esDireccional) {
        _patronDireccional(canvas, rect, color);
      } else {
        _patronTraccion(canvas, rect, color);
      }
      // Badge "L" para cohort 1 legacy: el operador necesita saber que
      // de esta cubierta no tenemos modelo/vidas/km previos reales.
      if (instalada.legacyInicial) {
        _badgeLegacy(canvas, rect);
      }
    }
  }

  /// Badge pequeño "L" en la esquina superior izquierda — marca cubiertas
  /// del seed inicial (cohort 1) cuyos datos previos son desconocidos.
  void _badgeLegacy(Canvas canvas, Rect rect) {
    final radio = rect.width * 0.18;
    final centro = Offset(rect.left + radio, rect.top + radio);
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.black.withValues(alpha: 0.65);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(centro, radio, fill);
    canvas.drawCircle(centro, radio, stroke);
    final tp = TextPainter(
      text: TextSpan(
        text: 'L',
        style: TextStyle(
          color: Colors.white,
          fontSize: radio * 1.5,
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

  /// Patrón direccional: 3 chevrons en V apilados verticalmente.
  /// Los chevrons del lado derecho del eje van invertidos para que el
  /// patrón sea simétrico-espejado entre IZQ/DER (como las cubiertas
  /// reales que se montan girando el costado).
  void _patronDireccional(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    final path = Path();
    const cant = 3;
    final paddingY = rect.height * 0.18;
    final usefulH = rect.height - paddingY * 2;
    final stepY = usefulH / cant;
    final padX = rect.width * 0.20;
    final cx = rect.center.dx;
    for (var i = 0; i < cant; i++) {
      final yTop = rect.top + paddingY + stepY * i;
      final yBot = yTop + stepY * 0.55;
      path.moveTo(rect.left + padX, yTop);
      path.lineTo(cx, yBot);
      path.lineTo(rect.right - padX, yTop);
    }
    canvas.drawPath(path, paint);
  }

  /// Patrón tracción: 4 bloques tipo "tacos" apilados, alternados en x
  /// para evocar el dibujo agresivo de las cubiertas de tracción.
  void _patronTraccion(Canvas canvas, Rect rect, Color color) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.85)
      ..style = PaintingStyle.fill;
    const cant = 4;
    final paddingY = rect.height * 0.10;
    final usefulH = rect.height - paddingY * 2;
    final stepY = usefulH / cant;
    final tacoH = stepY * 0.55;
    final tacoW = rect.width * 0.42;
    for (var i = 0; i < cant; i++) {
      final yTop = rect.top + paddingY + stepY * i + (stepY - tacoH) / 2;
      // Alterna el x entre izquierda y derecha para evocar el patrón.
      final xLeft = i.isEven
          ? rect.left + rect.width * 0.10
          : rect.right - rect.width * 0.10 - tacoW;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(xLeft, yTop, tacoW, tacoH),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  /// Dibuja un RRect con stroke discontinuo (dashed) para evocar
  /// "vacante / sin cubierta" en posiciones libres.
  void _dibujarRRectDiscontinuo(Canvas canvas, RRect rrect, Paint paint) {
    const dashLen = 4.0;
    const gapLen = 3.0;
    // Aproximación: dibujamos 4 lados como líneas dasheadas. Las
    // esquinas redondeadas se aproximan con un arco continuo (no
    // dasheado) para que no quede feo.
    final inner = rrect.deflate(0); // mismo
    final r = inner.tlRadiusX;
    final l = inner.left;
    final t = inner.top;
    final ri = inner.right;
    final b = inner.bottom;

    // Top
    _drawDashedLine(canvas, Offset(l + r, t), Offset(ri - r, t), paint, dashLen, gapLen);
    // Right
    _drawDashedLine(canvas, Offset(ri, t + r), Offset(ri, b - r), paint, dashLen, gapLen);
    // Bottom
    _drawDashedLine(canvas, Offset(ri - r, b), Offset(l + r, b), paint, dashLen, gapLen);
    // Left
    _drawDashedLine(canvas, Offset(l, b - r), Offset(l, t + r), paint, dashLen, gapLen);

    // Esquinas redondeadas (continuas, finas)
    final corner = Path()
      ..moveTo(l + r, t)
      ..arcToPoint(Offset(l, t + r), radius: Radius.circular(r), clockwise: false)
      ..moveTo(ri - r, t)
      ..arcToPoint(Offset(ri, t + r), radius: Radius.circular(r), clockwise: true)
      ..moveTo(ri, b - r)
      ..arcToPoint(Offset(ri - r, b), radius: Radius.circular(r), clockwise: true)
      ..moveTo(l, b - r)
      ..arcToPoint(Offset(l + r, b), radius: Radius.circular(r), clockwise: false);
    canvas.drawPath(corner, paint);
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint,
      double dashLen, double gapLen) {
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist <= 0) return;
    final ux = dx / dist;
    final uy = dy / dist;
    var travelled = 0.0;
    while (travelled < dist) {
      final start = Offset(a.dx + ux * travelled, a.dy + uy * travelled);
      final endTravel = math.min(travelled + dashLen, dist);
      final end = Offset(a.dx + ux * endTravel, a.dy + uy * endTravel);
      canvas.drawLine(start, end, paint);
      travelled += dashLen + gapLen;
    }
  }

  // ---- color por % vida útil consumida (mismo umbral que la lista) ----

  Color _colorVida(double? pct) {
    if (pct == null) return AppColors.accentGreen;
    if (pct >= 100) return AppColors.accentRed;
    if (pct >= 80) return AppColors.accentOrange;
    return AppColors.accentGreen;
  }

  @override
  bool shouldRepaint(covariant _EsquemaUnidadPainter old) {
    return old.tipo != tipo ||
        old.kmActualUnidad != kmActualUnidad ||
        !identical(old.instaladas, instaladas);
  }
}
