import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../shared/utils/formatters.dart';
import '../models/adelanto_chofer.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Resultado de la asignación de número de recibo.
class AsignarReciboResult {
  final int numero;
  final bool esReimpresion;

  const AsignarReciboResult({
    required this.numero,
    required this.esReimpresion,
  });
}

/// Service que asigna número correlativo + genera el PDF del
/// comprobante de adelanto que se imprime al chofer.
///
/// **Diseño**:
///   - El número se incrementa **server-side** vía la Cloud Function
///     callable `asignarNumeroReciboAdelanto`, que corre un
///     `runTransaction` con Admin SDK sobre
///     `COUNTERS/recibos_adelanto.next`. Atómico, sin gaps, sin
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
/// **Por qué server-side y no client-side**: el plugin
/// `cloud_firestore` en Windows desktop tiene un bug conocido que
/// crashea con `abort()` C++ runtime cuando se combina
/// `runTransaction` + `tx.set(merge: true)` +
/// `FieldValue.serverTimestamp()` (ver memoria
/// `feedback_windows_cloud_firestore_bugs.md`). El Admin SDK en
/// Cloud Functions no tiene ese bug.
class RecibosAdelantoService {
  /// Endpoint del callable. Mismo patrón HTTPS directo que
  /// `AuthService.loginConDni` porque el plugin `cloud_functions` no
  /// tiene implementación nativa para Windows desktop — pegarle por
  /// HTTPS funciona en todas las plataformas.
  static const String _asignarReciboEndpoint =
      'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/asignarNumeroReciboAdelanto';

  static final Dio _dio = Dio();

  /// Asigna número correlativo al adelanto (si no tiene) y devuelve el
  /// número final que va a salir impreso + si es reimpresión.
  /// Idempotente: llamarla 2 veces sobre el mismo adelanto devuelve el
  /// mismo número, sin incrementar el counter dos veces.
  ///
  /// Lanza [StateError] si la function rechaza la operación
  /// (adelanto inexistente, monto inválido, sin permiso, etc.) con
  /// un mensaje listo para mostrar en UI.
  static Future<AsignarReciboResult> asignarNumeroSiFalta({
    required String adelantoId,
  }) async {
    // Firebase Auth ID token: la function lo valida y extrae
    // request.auth.token.rol para chequear permisos. Sin token, la
    // function devuelve permission-denied.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('Sesión expirada. Volvé a iniciar sesión.');
    }
    final idToken = await user.getIdToken();
    if (idToken == null || idToken.isEmpty) {
      throw StateError('No se pudo obtener el token de sesión.');
    }

    try {
      final response = await _dio.post<Map<String, dynamic>>(
        _asignarReciboEndpoint,
        data: {
          // Protocolo callable: payload envuelto en `data`.
          'data': {'adelantoId': adelantoId},
        },
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          // Manejamos los errores body-down, no por excepciones.
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () =>
            throw TimeoutException('Sin conexión con el servidor.'),
      );

      if (response.statusCode == null || response.statusCode! >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        final message = (err?['message'] ?? '').toString();
        debugPrint(
            '🚨 asignarNumeroReciboAdelanto HTTP ${response.statusCode}: $message');
        throw StateError(
          message.isNotEmpty
              ? message
              : 'No se pudo asignar el número de recibo.',
        );
      }

      final result = response.data?['result'] as Map<String, dynamic>?;
      if (result == null) {
        throw StateError('Respuesta inválida del servidor.');
      }
      final numero = (result['numero'] as num?)?.toInt();
      final esReimpresion = result['esReimpresion'] as bool? ?? false;
      if (numero == null || numero <= 0) {
        throw StateError('El servidor no devolvió un número de recibo válido.');
      }

      return AsignarReciboResult(
        numero: numero,
        esReimpresion: esReimpresion,
      );
    } on TimeoutException {
      throw StateError(
          'Tiempo de espera agotado. Verificá la conexión e intentá de nuevo.');
    } on DioException catch (e) {
      debugPrint(
          '🚨 asignarNumeroReciboAdelanto Dio → type=${e.type} status=${e.response?.statusCode}');
      throw StateError(
          'No se pudo conectar con el servidor. Verificá la conexión.');
    } on StateError {
      rethrow;
    } catch (e, stack) {
      debugPrint('🚨 asignarNumeroReciboAdelanto error: $e');
      debugPrint(stack.toString());
      throw StateError('Error interno al asignar el número de recibo.');
    }
  }

  /// Genera el PDF del comprobante. Devuelve los bytes para que el
  /// caller los pase al package `printing` (preview + print) o los
  /// guarde a archivo / los comparta.
  ///
  /// Layout: hoja A4 vertical (210×297mm) dividida horizontalmente
  /// en 2 mitades idénticas. Cada mitad tiene encabezado, datos
  /// del adelanto, observación, y línea para firma.
  ///
  /// [esReimpresion] = true → marca cada mitad con sello "REIMPRESIÓN"
  /// para diferenciarla del original.
  static Future<Uint8List> generarPdf({
    required AdelantoChofer adelanto,
    required int numeroRecibo,
    required bool esReimpresion,
  }) async {
    // Cargar fuentes Roboto (Regular + Bold) desde assets/fonts/.
    // Roboto soporta el bloque Latin extendido completo (acentos
    // españoles, eñes, paréntesis, comillas tipográficas) — Helvetica
    // embedded del package `pdf` NO los garantiza y crashea cuando
    // intenta renderear glifos que no tiene. Con Roboto recuperamos
    // "REIMPRESIÓN", "Observación", "N°", "Pérez", etc. correctos.
    final robotoRegular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
    );
    final robotoBold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Bold.ttf'),
    );
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(
        base: robotoRegular,
        bold: robotoBold,
      ),
    );
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
                  adelanto: adelanto,
                  numeroRecibo: numeroRecibo,
                  fechaImpresion: fechaImpresion,
                  esReimpresion: esReimpresion,
                  copia: 'COPIA OFICINA',
                  logo: logo,
                ),
              ),
              // ─── Línea de corte (punteada) ───
              // Roboto soporta ✂ (U+2702), pero la fuente regular de
              // Google Fonts NO trae glifos symbol/emoji — el ícono
              // se renderea como cuadrado vacío. Para evitar eso,
              // dejamos texto descriptivo + guiones que sí soporta.
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 8),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text(
                      '- - - - - - - - - - - - - - - - - - - - - '
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
                  adelanto: adelanto,
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

  /// Genera UN solo PDF con el plan completo de N cuotas mensuales.
  /// Pedido Santiago 2026-05-19: cuando un adelanto se reparte en
  /// cuotas, el chofer firma 1 papel donde están detalladas todas
  /// las cuotas (#, fecha, monto). Estructura A4 con 2 mitades
  /// (COPIA OFICINA + COPIA CHOFER) — misma anatomía que el recibo
  /// individual pero con tabla de cuotas en lugar de un solo monto.
  ///
  /// `cuotas` debe estar ordenado por `cuotaNumero` ascendente. La
  /// primera cuota es la que "representa" al plan (su `numeroRecibo`
  /// se usa como N° impreso). Las demás cuotas se liquidan
  /// individualmente como cualquier adelanto, sin numero_recibo propio.
  static Future<Uint8List> generarPdfPlanCuotas({
    required List<AdelantoChofer> cuotas,
    required int numeroRecibo,
    required bool esReimpresion,
  }) async {
    if (cuotas.isEmpty) {
      throw ArgumentError('La lista de cuotas no puede estar vacía.');
    }
    final robotoRegular = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Regular.ttf'),
    );
    final robotoBold = pw.Font.ttf(
      await rootBundle.load('assets/fonts/Roboto-Bold.ttf'),
    );
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: robotoRegular, bold: robotoBold),
    );
    final fechaImpresion = DateTime.now();
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
              pw.Expanded(
                child: _MitadPlanCuotas.build(
                  cuotas: cuotas,
                  numeroRecibo: numeroRecibo,
                  fechaImpresion: fechaImpresion,
                  esReimpresion: esReimpresion,
                  copia: 'COPIA OFICINA',
                  logo: logo,
                ),
              ),
              pw.Container(
                margin: const pw.EdgeInsets.symmetric(vertical: 8),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.center,
                  children: [
                    pw.Text(
                      '- - - - - - - - - - - - - - - - - - - - - '
                      'CORTAR POR LA LÍNEA - - - - - - - - - - - - - - - - - - - - -',
                      style: const pw.TextStyle(
                        fontSize: 8, color: PdfColors.grey600,
                      ),
                    ),
                  ],
                ),
              ),
              pw.Expanded(
                child: _MitadPlanCuotas.build(
                  cuotas: cuotas,
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
    required AdelantoChofer adelanto,
    required int numeroRecibo,
    required DateTime fechaImpresion,
    required bool esReimpresion,
    required String copia,
    required pw.MemoryImage? logo,
  }) {
    final monto = adelanto.monto;
    final fechaAdelanto = adelanto.fecha;
    // Si la observación está vacía, usar em-dash (—) como placeholder.
    // Roboto soporta correctamente U+2014, ya no hace falta el guion
    // ASCII defensivo.
    final observacion =
        (adelanto.observacion ?? '').trim().isEmpty
            ? '—'
            : adelanto.observacion!.trim();
    final choferNombre = adelanto.choferNombre ?? adelanto.choferDni;
    final dniFmt = AppFormatters.formatearDNI(adelanto.choferDni);

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
          // cargarse), texto "TRANSPORTE SERVI-TOLVA" al lado. ───
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
                      'TRANSPORTE SERVI-TOLVA',
                      style: pw.TextStyle(
                        fontSize: 16,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text(
                      'Comprobante de adelanto',
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
                      // Roboto soporta ° (U+00B0) — recuperamos
                      // "N° 000123" más natural para el comprobante.
                      'N° ${numeroRecibo.toString().padLeft(6, '0')}',
                      style: pw.TextStyle(
                        fontSize: 13,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: AppSpacing.xs),
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
          pw.SizedBox(height: AppSpacing.md),
          pw.Divider(color: PdfColors.grey400, height: 1, thickness: 0.5),
          pw.SizedBox(height: 10),
          // ─── Datos del adelanto ───
          _Linea(
            label: 'Fecha del adelanto',
            valor: AppFormatters.formatearFecha(fechaAdelanto),
          ),
          _Linea(
            label: 'Empleado',
            valor: '$choferNombre  ·  DNI $dniFmt',
            destacado: true,
          ),
          _Linea(
            label: 'Monto entregado',
            valor: '\$ ${AppFormatters.formatearMonto(monto)}',
            destacado: true,
            grande: true,
          ),
          // ─── Medio de pago ─── (efectivo / transferencia)
          // Crítico para auditoría: el chofer firma el recibo donde
          // queda claro CÓMO recibió la plata. Si fue transferencia,
          // el comprobante bancario respalda; si fue efectivo, la
          // firma es la única evidencia.
          _Linea(
            label: 'Medio de pago',
            valor: adelanto.medioPago.etiqueta.toUpperCase(),
            destacado: true,
          ),
          pw.SizedBox(height: AppSpacing.sm),
          // ─── Observación ───
          pw.Text(
            'Observación / Concepto:',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
          pw.SizedBox(height: 3),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(AppSpacing.sm),
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
                    'Firma del empleado',
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

/// Builder de cada mitad del comprobante de PLAN DE CUOTAS (Santiago
/// 2026-05-19). Estructura idéntica al `_Mitad` regular pero el body
/// es una tabla con N cuotas en lugar de un único monto. El total
/// del plan se resalta abajo.
class _MitadPlanCuotas {
  static pw.Widget build({
    required List<AdelantoChofer> cuotas,
    required int numeroRecibo,
    required DateTime fechaImpresion,
    required bool esReimpresion,
    required String copia,
    required pw.MemoryImage? logo,
  }) {
    final primera = cuotas.first;
    final total = cuotas.fold<double>(0, (acc, c) => acc + c.monto);
    final reciboPad = numeroRecibo.toString().padLeft(6, '0');
    final obs = primera.observacion?.trim() ?? '';
    return pw.Container(
      padding: const pw.EdgeInsets.all(AppSpacing.md),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400, width: 0.6),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          // ─── Encabezado ────────────────────────────────────────
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (logo != null)
                pw.Container(
                  width: 50, height: 50,
                  child: pw.Image(logo),
                ),
              pw.SizedBox(width: AppSpacing.md),
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      'COMPROBANTE PLAN DE CUOTAS',
                      style: pw.TextStyle(
                        fontSize: 12, fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'Coopertrans Móvil',
                      style: const pw.TextStyle(
                        fontSize: 9, color: PdfColors.grey700,
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
                        horizontal: 6, vertical: 2),
                    decoration: pw.BoxDecoration(
                      color: copia == 'COPIA OFICINA'
                          ? PdfColors.blueGrey800
                          : PdfColors.green800,
                      borderRadius: pw.BorderRadius.circular(2),
                    ),
                    child: pw.Text(
                      copia,
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 8,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    'Recibo N° $reciboPad',
                    style: pw.TextStyle(
                      fontSize: 10, fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                  if (esReimpresion)
                    pw.Text(
                      'REIMPRESIÓN',
                      style: const pw.TextStyle(
                        fontSize: 7, color: PdfColors.red700,
                      ),
                    ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: AppSpacing.sm),
          // ─── Datos del chofer ──────────────────────────────────
          _Linea(label: 'Empleado',
              valor: primera.choferNombre?.trim().isNotEmpty == true
                  ? primera.choferNombre!
                  : 'DNI ${primera.choferDni}'),
          _Linea(label: 'DNI', valor: primera.choferDni),
          if (obs.isNotEmpty) _Linea(label: 'Concepto', valor: obs),
          _Linea(label: 'Medio de pago', valor: primera.medioPago.etiqueta),
          pw.SizedBox(height: 6),
          // ─── Tabla de cuotas ───────────────────────────────────
          pw.Table(
            columnWidths: const {
              0: pw.FlexColumnWidth(1.2),
              1: pw.FlexColumnWidth(3),
              2: pw.FlexColumnWidth(3),
            },
            border: pw.TableBorder.all(
                color: PdfColors.grey400, width: 0.5),
            children: [
              pw.TableRow(
                decoration:
                    const pw.BoxDecoration(color: PdfColors.blueGrey800),
                children: [
                  _cellHeader('CUOTA'),
                  _cellHeader('FECHA'),
                  _cellHeader('MONTO', align: pw.TextAlign.right),
                ],
              ),
              for (final c in cuotas)
                pw.TableRow(
                  children: [
                    _cellDato('${c.cuotaNumero ?? "?"}/'
                        '${c.cuotasTotal ?? cuotas.length}'),
                    _cellDato(_fmtFecha(c.fecha)),
                    _cellDato('\$ ${_fmtMonto(c.monto)}',
                        align: pw.TextAlign.right, bold: true),
                  ],
                ),
              // Fila TOTAL
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.amber50),
                children: [
                  _cellDato('TOTAL', bold: true),
                  _cellDato(''),
                  _cellDato('\$ ${_fmtMonto(total)}',
                      align: pw.TextAlign.right, bold: true),
                ],
              ),
            ],
          ),
          pw.Spacer(),
          // ─── Firma ─────────────────────────────────────────────
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Container(
                      height: 0.6, color: PdfColors.black,
                      margin: const pw.EdgeInsets.only(right: 30),
                    ),
                    pw.SizedBox(height: 2),
                    pw.Text('Firma del empleado',
                        style: const pw.TextStyle(
                            fontSize: 8, color: PdfColors.grey700)),
                  ],
                ),
              ),
              pw.SizedBox(width: AppSpacing.md),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text(
                    'Impreso ${_fmtFechaHora(fechaImpresion)}',
                    style: const pw.TextStyle(
                        fontSize: 7, color: PdfColors.grey600),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _cellHeader(String text,
      {pw.TextAlign align = pw.TextAlign.left}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: pw.Text(
        text, textAlign: align,
        style: pw.TextStyle(
          color: PdfColors.white,
          fontSize: 8,
          fontWeight: pw.FontWeight.bold,
        ),
      ),
    );
  }

  static pw.Widget _cellDato(String text,
      {pw.TextAlign align = pw.TextAlign.left, bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      child: pw.Text(
        text, textAlign: align,
        style: pw.TextStyle(
          fontSize: 9,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  static String _fmtFecha(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd-$mm-${d.year}';
  }

  static String _fmtFechaHora(DateTime d) {
    final hh = d.hour.toString().padLeft(2, '0');
    final mi = d.minute.toString().padLeft(2, '0');
    return '${_fmtFecha(d)} $hh:$mi';
  }

  static String _fmtMonto(double v) {
    // Formato AR: 1.234,56
    final entero = v.truncate();
    final dec = ((v - entero).abs() * 100).round().toString().padLeft(2, '0');
    final enteroStr = entero
        .toString()
        .replaceAllMapped(
            RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.');
    return '$enteroStr,$dec';
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
