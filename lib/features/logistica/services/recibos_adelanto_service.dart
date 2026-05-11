import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/constants/app_constants.dart';
import '../../../shared/utils/formatters.dart';
import '../models/viaje.dart';

/// Service que asigna número correlativo + genera el PDF del
/// comprobante de adelanto que se imprime al chofer.
///
/// **Diseño**:
///   - El número se incrementa con `runTransaction` sobre
///     `COUNTERS/recibos_adelanto.next` — atómico, sin gaps, sin
///     duplicados aún con impresiones simultáneas.
///   - El número se asigna SOLO en la primera impresión. Si el
///     viaje ya tiene `numeroReciboAdelanto`, se reusa (la
///     reimpresión muestra el mismo número, etiquetada
///     "REIMPRESIÓN" para distinguirla).
///   - El PDF tiene 2 mitades A4 idénticas (apaisado partido por
///     mitad horizontal): copia OFICINA arriba + copia CHOFER
///     abajo. El operador imprime, corta al medio, una queda en
///     oficina y la otra firmada se la lleva el chofer.
///
/// **Por qué Firestore transaction y no autoincrement de SQL**:
/// Firebase no tiene autoincrement nativo; las transactions sobre
/// un solo doc son la forma estándar y están garantizadas a no
/// duplicar (Firestore reintenta automáticamente conflictos).
class RecibosAdelantoService {
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  /// Doc del counter. Si no existe, lo crea con `next: 1` en la
  /// primera invocación.
  static DocumentReference<Map<String, dynamic>> get _counterDoc =>
      _db.collection(AppCollections.counters).doc('recibos_adelanto');

  static DocumentReference<Map<String, dynamic>> _viajeDoc(String id) =>
      _db.collection(AppCollections.viajesLogistica).doc(id);

  /// Asigna número correlativo al viaje (si no tiene) y devuelve el
  /// número final que va a salir impreso. Idempotente: llamarla 2
  /// veces sobre el mismo viaje devuelve el mismo número, sin
  /// incrementar el counter dos veces.
  ///
  /// Lanza si no hay adelanto cargado en el viaje (no tiene sentido
  /// imprimir comprobante sin adelanto).
  static Future<int> asignarNumeroSiFalta({
    required String viajeId,
  }) async {
    final viajeRef = _viajeDoc(viajeId);
    return await _db.runTransaction<int>((tx) async {
      final viajeSnap = await tx.get(viajeRef);
      if (!viajeSnap.exists) {
        throw StateError('El viaje $viajeId no existe.');
      }
      final data = viajeSnap.data()!;
      final monto = (data['adelanto_monto'] as num?)?.toDouble() ?? 0;
      if (monto <= 0) {
        throw StateError(
            'El viaje no tiene adelanto cargado — no hay nada que imprimir.');
      }
      final yaTiene = (data['numero_recibo_adelanto'] as num?)?.toInt();
      if (yaTiene != null) {
        // Reimpresión: mismo número, no incrementar counter.
        return yaTiene;
      }
      // Primera impresión: leer counter, incrementar, asignar al viaje.
      final counterSnap = await tx.get(_counterDoc);
      final next = (counterSnap.data()?['next'] as num?)?.toInt() ?? 1;
      tx.set(_counterDoc, {'next': next + 1}, SetOptions(merge: true));
      tx.update(viajeRef, {
        'numero_recibo_adelanto': next,
        'recibo_impreso_en': FieldValue.serverTimestamp(),
        'actualizado_en': FieldValue.serverTimestamp(),
      });
      return next;
    });
  }

  /// Genera el PDF del comprobante. Devuelve los bytes para que el
  /// caller los pase al package `printing` (preview + print) o los
  /// guarde a archivo / los comparta.
  ///
  /// Layout: hoja A4 vertical (210×297mm) dividida horizontalmente
  /// en 2 mitades idénticas. Cada mitad tiene encabezado, datos
  /// del viaje, observación, y línea para firma.
  ///
  /// [esReimpresion] = true → marca cada mitad con sello "REIMPRESIÓN"
  /// para diferenciarla del original.
  static Future<Uint8List> generarPdf({
    required Viaje viaje,
    required int numeroRecibo,
    required bool esReimpresion,
  }) async {
    final doc = pw.Document();
    final fechaImpresion = DateTime.now();

    // Cargar logo VAVG desde assets/brand/. Se carga UNA vez antes
    // de construir las páginas (vs. cargarlo dos veces, una por
    // mitad). Si falla la carga (ej. asset corrupto), seguimos sin
    // logo en lugar de romper el PDF entero — el comprobante sin
    // logo igual sirve para auditoría.
    pw.MemoryImage? logo;
    try {
      final bytes = await rootBundle.load('assets/brand/vavg_logo.png');
      logo = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {
      logo = null;
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(20),
        build: (ctx) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // ─── Mitad 1 (arriba) — copia OFICINA ───
              pw.Expanded(
                child: _Mitad.build(
                  viaje: viaje,
                  numeroRecibo: numeroRecibo,
                  fechaImpresion: fechaImpresion,
                  esReimpresion: esReimpresion,
                  copia: 'COPIA OFICINA',
                  logo: logo,
                ),
              ),
              // ─── Línea de corte (punteada) ───
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 8),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text(
                      '✂  - - - - - - - - - - - - - - - - - - - - - '
                      'CORTAR POR LA LÍNEA - - - - - - - - - - - - - - - - - - - - -',
                      style: const pw.TextStyle(
                        fontSize: 8,
                        color: PdfColors.grey600,
                      ),
                    ),
                  ],
                ),
              ),
              // ─── Mitad 2 (abajo) — copia CHOFER ───
              pw.Expanded(
                child: _Mitad.build(
                  viaje: viaje,
                  numeroRecibo: numeroRecibo,
                  fechaImpresion: fechaImpresion,
                  esReimpresion: esReimpresion,
                  copia: 'COPIA CHOFER',
                  logo: logo,
                ),
              ),
            ],
          );
        },
      ),
    );
    return doc.save();
  }
}

/// Builder de cada mitad del comprobante. Encabezado + body + firma.
/// Ambas mitades son idénticas en datos; solo cambia el sello "COPIA
/// OFICINA" / "COPIA CHOFER" en la esquina superior derecha.
class _Mitad {
  static pw.Widget build({
    required Viaje viaje,
    required int numeroRecibo,
    required DateTime fechaImpresion,
    required bool esReimpresion,
    required String copia,
    required pw.MemoryImage? logo,
  }) {
    final monto = viaje.adelantoMonto ?? 0;
    final fechaAdelanto = viaje.adelantoFecha ?? viaje.fechaCarga ?? fechaImpresion;
    final observacion =
        (viaje.adelantoObservacion ?? '').trim().isEmpty
            ? '—'
            : viaje.adelantoObservacion!.trim();
    final choferNombre = viaje.choferNombre ?? viaje.choferDni;
    final dniFmt = AppFormatters.formatearDNI(viaje.choferDni);

    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.black, width: 1),
        borderRadius: pw.BorderRadius.circular(4),
      ),
      padding: const pw.EdgeInsets.all(14),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ─── Encabezado: logo + razón social + N° recibo + tipo
          // de copia. Logo VAVG arriba a la izquierda (si pudo
          // cargarse), texto "TRANSPORTE COOPER-TRANS" al lado. ───
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null) ...[
                pw.SizedBox(
                  width: 60,
                  height: 36,
                  child: pw.Image(logo, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(width: 10),
              ],
              pw.Expanded(
                flex: 3,
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'TRANSPORTE COOPER-TRANS',
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Comprobante de adelanto a chofer',
                      style: const pw.TextStyle(
                        fontSize: 9,
                        color: PdfColors.grey700,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: pw.BoxDecoration(
                      border: pw.Border.all(color: PdfColors.black, width: 1),
                    ),
                    child: pw.Text(
                      'N° ${numeroRecibo.toString().padLeft(6, '0')}',
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 4),
                  pw.Text(
                    copia,
                    style: pw.TextStyle(
                      fontSize: 9,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.grey800,
                    ),
                  ),
                  if (esReimpresion) ...[
                    pw.SizedBox(height: 2),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                          horizontal: 4, vertical: 1),
                      decoration: pw.BoxDecoration(
                        color: PdfColors.amber200,
                        border:
                            pw.Border.all(color: PdfColors.orange900, width: 0.5),
                      ),
                      child: pw.Text(
                        'REIMPRESIÓN',
                        style: pw.TextStyle(
                          fontSize: 7,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColors.orange900,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 12),
          pw.Divider(color: PdfColors.grey400, height: 1, thickness: 0.5),
          pw.SizedBox(height: 10),
          // ─── Datos del adelanto ───
          _Linea(
            label: 'Fecha del adelanto',
            valor: AppFormatters.formatearFecha(fechaAdelanto),
          ),
          _Linea(
            label: 'Chofer',
            valor: '$choferNombre  ·  DNI $dniFmt',
            destacado: true,
          ),
          _Linea(
            label: 'Monto entregado',
            valor: '\$ ${AppFormatters.formatearMonto(monto)}',
            destacado: true,
            grande: true,
          ),
          pw.SizedBox(height: 8),
          // ─── Observación ───
          pw.Text(
            'Observación / Concepto:',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 3),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(2),
            ),
            child: pw.Text(
              observacion,
              style: const pw.TextStyle(fontSize: 10),
            ),
          ),
          pw.Spacer(),
          // ─── Firma del chofer (única — la de "quien entrega" se
          // sacó 2026-05-12 a pedido del operador: el comprobante
          // queda firmado solo por quien recibe el adelanto, que es
          // lo que se necesita para auditoría) ───
          pw.Center(
            child: pw.SizedBox(
              width: 180,
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Container(
                    height: 1,
                    color: PdfColors.black,
                  ),
                  pw.SizedBox(height: 3),
                  pw.Text(
                    'Firma del chofer',
                    style: const pw.TextStyle(
                      fontSize: 8,
                      color: PdfColors.grey700,
                    ),
                  ),
                  pw.Text(
                    choferNombre,
                    style: const pw.TextStyle(fontSize: 9),
                  ),
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 6),
          // Pie con timestamp de impresión (chiquito, esquina inferior).
          pw.Align(
            alignment: pw.Alignment.bottomRight,
            child: pw.Text(
              'Impreso ${AppFormatters.formatearFechaHoraSinSegundos(fechaImpresion)}',
              style: const pw.TextStyle(
                fontSize: 7,
                color: PdfColors.grey600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Linea extends pw.StatelessWidget {
  final String label;
  final String valor;
  final bool destacado;
  final bool grande;

  _Linea({
    required this.label,
    required this.valor,
    this.destacado = false,
    this.grande = false,
  });

  @override
  pw.Widget build(pw.Context context) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.SizedBox(
            width: 110,
            child: pw.Text(
              label,
              style: const pw.TextStyle(
                fontSize: 9,
                color: PdfColors.grey700,
              ),
            ),
          ),
          pw.Expanded(
            child: pw.Text(
              valor,
              style: pw.TextStyle(
                fontSize: grande ? 14 : 10,
                fontWeight: destacado || grande
                    ? pw.FontWeight.bold
                    : pw.FontWeight.normal,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
