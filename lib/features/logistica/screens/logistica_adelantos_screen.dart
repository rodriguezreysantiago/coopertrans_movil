import 'dart:io' show File, Platform, Process;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/adelanto_chofer.dart';
import '../services/adelantos_service.dart';
import '../services/recibos_adelanto_service.dart';

/// ABM de adelantos a chofer. Lista por fecha desc, alta vía dialog,
/// edición inline al tocar la card, eliminar con confirmación,
/// imprimir comprobante (asigna correlativo server-side la primera vez,
/// reusa el mismo en reimpresiones).
///
/// Decisión Santiago 2026-05-13: los adelantos viven en su propia
/// colección (ADELANTOS_CHOFER) — antes vivían como subcampos del
/// viaje, lo cual obligaba a crear viajes vacíos para registrar
/// adelantos de sueldo. Ahora son independientes.
class LogisticaAdelantosScreen extends StatefulWidget {
  const LogisticaAdelantosScreen({super.key});

  @override
  State<LogisticaAdelantosScreen> createState() =>
      _LogisticaAdelantosScreenState();
}

class _LogisticaAdelantosScreenState extends State<LogisticaAdelantosScreen> {
  String _filtro = '';

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Adelantos',
      floatingActionButton: Builder(
        builder: (ctx) => FloatingActionButton.extended(
          backgroundColor: AppColors.accentGreen,
          onPressed: () => _abrirAlta(ctx),
          icon: const Icon(Icons.add),
          label: const Text('NUEVO ADELANTO'),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: 'Buscar por chofer, observación…',
                border: const OutlineInputBorder(),
                isDense: true,
                suffixIcon: _filtro.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () => setState(() => _filtro = ''),
                      ),
              ),
              onChanged: (v) => setState(() => _filtro = v),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<AdelantoChofer>>(
              stream: AdelantosService.streamAdelantos(),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return AppEmptyState(
                    icon: Icons.error_outline,
                    title: 'Error cargando adelantos',
                    subtitle: snap.error.toString(),
                  );
                }
                final items = snap.data ?? const [];
                if (items.isEmpty) {
                  return const AppEmptyState(
                    icon: Icons.payments_outlined,
                    title: 'Sin adelantos cargados',
                    subtitle: 'Tocá "NUEVO ADELANTO" para registrar el primero.',
                  );
                }
                final filtrados = _aplicarFiltro(items);
                if (filtrados.isEmpty) {
                  return AppEmptyState(
                    icon: Icons.search_off,
                    title: 'Sin resultados',
                    subtitle:
                        'Ningún adelanto coincide con "$_filtro". Probá con '
                        'otra palabra o limpiá el filtro.',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                  itemCount: filtrados.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) =>
                      _CardAdelanto(adelanto: filtrados[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  List<AdelantoChofer> _aplicarFiltro(List<AdelantoChofer> items) {
    final q = _filtro.trim().toLowerCase();
    if (q.isEmpty) return items;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return items.where((a) {
      final hay = [
        a.choferNombre ?? '',
        a.choferDni,
        a.observacion ?? '',
        if (a.numeroRecibo != null) 'recibo n${a.numeroRecibo}',
      ].join(' ').toLowerCase();
      for (final t in tokens) {
        if (!hay.contains(t)) return false;
      }
      return true;
    }).toList();
  }

  Future<void> _abrirAlta(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const _AdelantoFormDialog(),
    );
  }
}

// =============================================================================
// CARD
// =============================================================================

class _CardAdelanto extends StatelessWidget {
  final AdelantoChofer adelanto;
  const _CardAdelanto({required this.adelanto});

  @override
  Widget build(BuildContext context) {
    final fechaFmt = AppFormatters.formatearFecha(adelanto.fecha);
    final montoFmt = AppFormatters.formatearMonto(adelanto.monto);
    final chofer = adelanto.choferNombre?.trim().isNotEmpty == true
        ? adelanto.choferNombre!.trim()
        : 'DNI ${adelanto.choferDni}';
    final yaImpreso = adelanto.numeroRecibo != null;

    return AppCard(
      onTap: () => showDialog(
        context: context,
        builder: (_) => _AdelantoFormDialog(adelanto: adelanto),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.payments_outlined,
                  size: 20, color: AppColors.accentGreen),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  chofer,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '\$ $montoFmt',
                style: const TextStyle(
                  color: AppColors.accentGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.accentRed),
                tooltip: 'Eliminar adelanto',
                onPressed: () => _confirmarEliminar(context),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      size: 12, color: Colors.white54),
                  const SizedBox(width: 4),
                  Text(
                    fechaFmt,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              // Chip de medio de pago. Color: amber para transferencia
              // (porque suele requerir más seguimiento — comprobante
              // bancario, etc.), teal para efectivo (entrega directa).
              _ChipMedioPago(medio: adelanto.medioPago),
              if (yaImpreso)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.receipt_long_outlined,
                        size: 12, color: AppColors.accentBlue),
                    const SizedBox(width: 4),
                    Text(
                      'Recibo N° ${adelanto.numeroRecibo!.toString().padLeft(6, '0')}',
                      style: const TextStyle(
                        color: AppColors.accentBlue,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
            ],
          ),
          if (adelanto.observacion != null &&
              adelanto.observacion!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              adelanto.observacion!,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: _BotonImprimirComprobante(adelanto: adelanto),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmarEliminar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Eliminar adelanto?'),
        content: Text(
          'Adelanto de \$${AppFormatters.formatearMonto(adelanto.monto)} '
          'a ${adelanto.choferNombre ?? "DNI ${adelanto.choferDni}"} '
          'del ${AppFormatters.formatearFecha(adelanto.fecha)}.\n\n'
          'Esta acción no se puede deshacer. '
          '${adelanto.numeroRecibo != null ? "El número de recibo ${adelanto.numeroRecibo} queda quemado." : ""}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accentRed,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('ELIMINAR'),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await AdelantosService.eliminarAdelanto(adelanto.id);
      AppFeedback.successOn(messenger, 'Adelanto eliminado.');
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al eliminar: $e');
    }
  }
}

// =============================================================================
// FORM DIALOG (alta + edición)
// =============================================================================

class _AdelantoFormDialog extends StatefulWidget {
  /// Si null → modo alta. Si trae uno → modo edición.
  final AdelantoChofer? adelanto;

  const _AdelantoFormDialog({this.adelanto});

  @override
  State<_AdelantoFormDialog> createState() => _AdelantoFormDialogState();
}

class _AdelantoFormDialogState extends State<_AdelantoFormDialog> {
  final _montoCtrl = TextEditingController();
  final _obsCtrl = TextEditingController();
  String? _choferDni;
  String? _choferNombre;
  DateTime _fecha = DateTime.now();
  // Default = efectivo (Santiago 2026-05-13). La mayoría de los
  // adelantos se entregan en mano.
  MedioPagoAdelanto _medioPago = MedioPagoAdelanto.efectivo;
  bool _guardando = false;
  // Si verdadero, ya guardamos el adelanto y estamos esperando que la
  // impresión salga (Cloud Function + PDF + envío a impresora). Lo
  // mostramos como "Imprimiendo…" para que el operador entienda por
  // qué el dialog no se cierra de inmediato.
  bool _imprimiendo = false;
  String? _error;

  bool get _esEdicion => widget.adelanto != null;

  @override
  void initState() {
    super.initState();
    final a = widget.adelanto;
    if (a != null) {
      _choferDni = a.choferDni;
      _choferNombre = a.choferNombre;
      _fecha = a.fecha;
      _montoCtrl.text = AppFormatters.formatearMiles(a.monto.toInt());
      _obsCtrl.text = a.observacion ?? '';
      _medioPago = a.medioPago;
    }
  }

  @override
  void dispose() {
    _montoCtrl.dispose();
    _obsCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text(_esEdicion ? 'Editar adelanto' : 'Nuevo adelanto'),
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ─── Chofer ───
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection(AppCollections.empleados)
                    .where('ROL', isEqualTo: 'CHOFER')
                    .snapshots(),
                builder: (ctx, snap) {
                  final docs = List<
                          QueryDocumentSnapshot<Map<String, dynamic>>>.from(
                    snap.data?.docs ?? const [],
                  )..sort((a, b) {
                      final na =
                          (a.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      final nb =
                          (b.data()['NOMBRE'] ?? '').toString().toUpperCase();
                      return na.compareTo(nb);
                    });
                  return DropdownButtonFormField<String>(
                    initialValue: _choferDni,
                    decoration: const InputDecoration(
                      labelText: 'Chofer *',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: docs.map((d) {
                      final dni = (d.data()['DNI'] ?? d.id).toString();
                      final nom = (d.data()['NOMBRE'] ?? dni).toString();
                      return DropdownMenuItem(
                        value: dni,
                        child: Text(nom, overflow: TextOverflow.ellipsis),
                      );
                    }).toList(),
                    onChanged: (val) {
                      if (val == null) return;
                      final doc = docs.firstWhere(
                        (d) => (d.data()['DNI'] ?? d.id).toString() == val,
                      );
                      setState(() {
                        _choferDni = val;
                        _choferNombre =
                            (doc.data()['NOMBRE'] ?? val).toString();
                      });
                    },
                  );
                },
              ),
              const SizedBox(height: 12),
              // ─── Fecha ───
              InkWell(
                onTap: _pickFecha,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Fecha *',
                    border: OutlineInputBorder(),
                    suffixIcon:
                        Icon(Icons.calendar_today_outlined, size: 18),
                  ),
                  child: Text(
                    AppFormatters.formatearFecha(_fecha),
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // ─── Monto ───
              TextField(
                controller: _montoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Monto *',
                  prefixText: '\$ ',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [AppFormatters.inputMiles],
              ),
              const SizedBox(height: 12),
              // ─── Medio de pago ───
              // Toggle entre efectivo (default) y transferencia. Aparece
              // en el comprobante impreso, donde el chofer firma.
              const Padding(
                padding: EdgeInsets.only(left: 4, bottom: 4),
                child: Text(
                  'Medio de pago',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
              SegmentedButton<MedioPagoAdelanto>(
                segments: const [
                  ButtonSegment(
                    value: MedioPagoAdelanto.efectivo,
                    label: Text('EFECTIVO'),
                    icon: Icon(Icons.payments_outlined, size: 16),
                  ),
                  ButtonSegment(
                    value: MedioPagoAdelanto.transferencia,
                    label: Text('TRANSFERENCIA'),
                    icon: Icon(Icons.account_balance_outlined, size: 16),
                  ),
                ],
                selected: {_medioPago},
                onSelectionChanged: (sel) =>
                    setState(() => _medioPago = sel.first),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(height: 12),
              // ─── Observación ───
              TextField(
                controller: _obsCtrl,
                decoration: const InputDecoration(
                  labelText: 'Observación / concepto',
                  hintText: 'Ej. combustible, adelanto sueldo, viático…',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: const TextStyle(color: AppColors.accentRed),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        FilledButton(
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    ),
                    if (_imprimiendo) ...[
                      const SizedBox(width: 8),
                      const Text('IMPRIMIENDO…'),
                    ],
                  ],
                )
              : Text(_esEdicion ? 'GUARDAR' : 'CREAR'),
        ),
      ],
    );
  }

  Future<void> _pickFecha() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(DateTime.now().year - 2),
      lastDate: DateTime(DateTime.now().year + 2),
    );
    if (d != null) setState(() => _fecha = d);
  }

  Future<void> _guardar() async {
    if (_choferDni == null || _choferDni!.isEmpty) {
      setState(() => _error = 'Seleccioná un chofer.');
      return;
    }
    final monto =
        AppFormatters.parsearMiles(_montoCtrl.text)?.toDouble() ?? 0;
    if (monto <= 0) {
      setState(() => _error = 'El monto debe ser mayor a 0.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      final dniActual = PrefsService.dni;
      final obs = _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text.trim();
      if (_esEdicion) {
        // Edición: NO re-imprime — si el operador necesita un nuevo
        // comprobante usa "REIMPRIMIR" en la card. Editar suele ser
        // para corregir un dato menor (observación, fecha, medio de
        // pago) y reimprimir con el mismo correlativo no aporta.
        await AdelantosService.actualizarAdelanto(
          adelantoId: widget.adelanto!.id,
          choferDni: _choferDni!,
          choferNombre: _choferNombre,
          fecha: _fecha,
          monto: monto,
          observacion: obs,
          medioPago: _medioPago,
          viajeId: widget.adelanto!.viajeId,
          actualizadoPorDni: dniActual,
        );
        if (mounted) Navigator.pop(context);
        return;
      }

      // ─── Modo alta ──────────────────────────────────────────────
      final adelantoId = await AdelantosService.crearAdelanto(
        choferDni: _choferDni!,
        choferNombre: _choferNombre,
        fecha: _fecha,
        monto: monto,
        observacion: obs,
        medioPago: _medioPago,
        creadoPorDni: dniActual,
        creadoPorNombre: PrefsService.nombre,
      );

      // Auto-imprimir el comprobante recién creado (Santiago
      // 2026-05-13: el flow físico es entregar la plata, firmar el
      // recibo, así que el operador siempre va a imprimir después de
      // crear — auto-hacerlo ahorra un click). Si la impresión falla
      // (Cloud Function caída, sin impresora, etc.), el adelanto ya
      // está en la base — el operador puede usar "REIMPRIMIR" desde
      // la lista.
      if (!mounted) return;
      setState(() => _imprimiendo = true);
      final adelantoLocal = AdelantoChofer(
        id: adelantoId,
        choferDni: _choferDni!,
        choferNombre: _choferNombre,
        fecha: _fecha,
        monto: monto,
        observacion: obs,
        medioPago: _medioPago,
      );
      await _ComprobantePrinter.imprimir(
        context: context,
        adelanto: adelantoLocal,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _guardando = false;
        _imprimiendo = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Z][a-z]+: '), '');
      });
    }
  }
}

// =============================================================================
// IMPRIMIR COMPROBANTE
// =============================================================================

/// Botón "Imprimir comprobante" — replica el flow del detalle de viaje
/// pero apuntando a `AdelantoChofer`. Asigna correlativo server-side la
/// primera vez (Cloud Function `asignarNumeroReciboAdelanto`),
/// reimpresión usa el mismo número. Imprime directo a la impresora
/// default del sistema con `Printing.directPrintPdf`. Si falla, abre el
/// PDF con el viewer del SO como fallback.
class _BotonImprimirComprobante extends StatefulWidget {
  final AdelantoChofer adelanto;
  const _BotonImprimirComprobante({required this.adelanto});

  @override
  State<_BotonImprimirComprobante> createState() =>
      _BotonImprimirComprobanteState();
}

class _BotonImprimirComprobanteState
    extends State<_BotonImprimirComprobante> {
  bool _generando = false;

  @override
  Widget build(BuildContext context) {
    final esReimpresion = widget.adelanto.numeroRecibo != null;
    return OutlinedButton.icon(
      onPressed: _generando ? null : _imprimir,
      icon: _generando
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.accentGreen),
            )
          : Icon(esReimpresion ? Icons.refresh : Icons.print_outlined,
              size: 18),
      label: Text(esReimpresion
          ? 'REIMPRIMIR COMPROBANTE'
          : 'IMPRIMIR COMPROBANTE'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentGreen,
        side: const BorderSide(color: AppColors.accentGreen),
        padding: const EdgeInsets.symmetric(vertical: 10),
        textStyle:
            const TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1),
      ),
    );
  }

  Future<void> _imprimir() async {
    setState(() => _generando = true);
    try {
      await _ComprobantePrinter.imprimir(
        context: context,
        adelanto: widget.adelanto,
      );
    } finally {
      if (mounted) setState(() => _generando = false);
    }
  }
}

// =============================================================================
// HELPER DE IMPRESIÓN (compartido entre botón manual + auto-imprimir al crear)
// =============================================================================

/// Encapsula el flow completo de imprimir un comprobante de adelanto:
///   1. Pedir / reusar correlativo via Cloud Function (idempotente).
///   2. Generar el PDF (A4 dos mitades).
///   3. Mandar a impresora default; si falla, fallback al viewer del SO.
///   4. Mostrar feedback al usuario via ScaffoldMessenger.
///
/// Se usa desde 2 lugares:
///   - Botón "IMPRIMIR / REIMPRIMIR COMPROBANTE" en la card (manual).
///   - Form de alta `_AdelantoFormDialog._guardar()` (automático al crear).
///
/// Los errores se reportan via SnackBar y NO se re-tiran al caller — para
/// que el form pueda cerrar el dialog igual aunque la impresión haya
/// fallado (el adelanto ya está creado, el operador puede reimprimir
/// manual desde la card). Devuelve `true` si pudo mandar a impresora,
/// `false` si terminó en el viewer o si falló.
class _ComprobantePrinter {
  static Future<bool> imprimir({
    required BuildContext context,
    required AdelantoChofer adelanto,
  }) async {
    // Capturamos el messenger ANTES del await para evitar usar el
    // BuildContext después de un async gap (lint rule).
    final messenger = ScaffoldMessenger.of(context);
    try {
      // 1. Asignar / reusar número correlativo (Cloud Function).
      final resultado = await RecibosAdelantoService.asignarNumeroSiFalta(
        adelantoId: adelanto.id,
      );
      final numero = resultado.numero;
      // 2. Generar PDF en memoria.
      final Uint8List pdfBytes = await RecibosAdelantoService.generarPdf(
        adelanto: adelanto,
        numeroRecibo: numero,
        esReimpresion: resultado.esReimpresion,
      );
      // 3. Imprimir directo o fallback a viewer.
      final nombreArchivo =
          'Comprobante-Adelanto-Nro-${numero.toString().padLeft(6, '0')}.pdf';
      final impresoOk = await _imprimirDirecto(pdfBytes, nombreArchivo);
      if (impresoOk) {
        AppFeedback.successOn(messenger,
            'Comprobante Nro. ${numero.toString().padLeft(6, '0')} '
            'enviado a la impresora.');
      } else {
        AppFeedback.successOn(messenger,
            'Comprobante Nro. ${numero.toString().padLeft(6, '0')} abierto. '
            'Imprimí desde el visor (Ctrl+P).');
      }
      return impresoOk;
    } catch (e) {
      AppFeedback.errorOn(messenger, 'Error al generar comprobante: $e');
      return false;
    }
  }

  static Future<bool> _imprimirDirecto(
      Uint8List bytes, String nombreArchivo) async {
    try {
      final printers = await Printing.listPrinters();
      if (printers.isEmpty) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return false;
      }
      final printer = printers.firstWhere(
        (p) => p.isDefault,
        orElse: () => printers.first,
      );
      final ok = await Printing.directPrintPdf(
        printer: printer,
        onLayout: (_) async => bytes,
        name: nombreArchivo,
      );
      if (!ok) {
        await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
        return false;
      }
      return true;
    } catch (e, stack) {
      debugPrint('⚠️ Printing.directPrintPdf falló: $e');
      debugPrint(stack.toString());
      await _abrirPdfConViewerSistema(bytes, nombreArchivo: nombreArchivo);
      return false;
    }
  }

  static Future<void> _abrirPdfConViewerSistema(
    List<int> bytes, {
    required String nombreArchivo,
  }) async {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/$nombreArchivo');
    await file.writeAsBytes(bytes, flush: true);
    if (!kIsWeb && Platform.isWindows) {
      await Process.start(
        'cmd',
        ['/c', 'start', '', file.path],
        runInShell: true,
      );
    } else {
      await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
    }
  }
}

/// Chip compacto para mostrar el medio de pago del adelanto en la
/// card de la lista. Efectivo → teal (entrega directa); transferencia
/// → amber (suele requerir comprobante bancario adjunto).
class _ChipMedioPago extends StatelessWidget {
  final MedioPagoAdelanto medio;
  const _ChipMedioPago({required this.medio});

  @override
  Widget build(BuildContext context) {
    final esEfectivo = medio == MedioPagoAdelanto.efectivo;
    final color = esEfectivo ? AppColors.accentTeal : AppColors.accentAmber;
    final icono = esEfectivo
        ? Icons.payments_outlined
        : Icons.account_balance_outlined;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, size: 11, color: color),
          const SizedBox(width: 4),
          Text(
            medio.etiqueta.toUpperCase(),
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
            ),
          ),
        ],
      ),
    );
  }
}
