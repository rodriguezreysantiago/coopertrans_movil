import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../revisions/services/revision_service.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/notification_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/fecha_input_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/ocr_service.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../checklist/screens/user_checklist_form_screen.dart';

// Componentes visuales (header, card, boton upload, detalle equipo,
// boton OCR, etc) extraidos para mantener navegable este screen.
// Comparten privacidad via `part of`.
part 'user_mis_vencimientos_widgets.dart';

/// Pantalla del chofer: lista de sus vencimientos personales y de su equipo.
/// Permite iniciar trámites de renovación (subir comprobante + fecha).
class UserMisVencimientosScreen extends StatefulWidget {
  final String dniUser;
  const UserMisVencimientosScreen({super.key, required this.dniUser});

  @override
  State<UserMisVencimientosScreen> createState() =>
      _UserMisVencimientosScreenState();
}

class _UserMisVencimientosScreenState
    extends State<UserMisVencimientosScreen> {
  final RevisionService _revisionService = RevisionService();
  late final Stream<DocumentSnapshot> _empleadoStream;

  @override
  void initState() {
    super.initState();
    _empleadoStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(widget.dniUser)
        .snapshots();
    // Cuando el chofer abre la pantalla, reagendamos sus recordatorios
    // push locales (cancela los viejos primero para no acumular avisos
    // de papeles ya renovados). Es fire-and-forget: si falla el
    // permiso o la plataforma no soporta, no afecta la pantalla.
    unawaited(_reagendarRecordatoriosLocales());
  }

  Future<void> _reagendarRecordatoriosLocales() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(widget.dniUser)
          .get();
      if (!snap.exists) return;
      final data = snap.data();
      if (data == null) return;

      final avisos = <VencimientoAviso>[];
      final hoy = DateTime.now();
      AppDocsEmpleado.etiquetas.forEach((etiqueta, campoBase) {
        final fechaStr = data['VENCIMIENTO_$campoBase']?.toString();
        if (fechaStr == null || fechaStr.isEmpty) return;
        final fecha = AppFormatters.tryParseFecha(fechaStr);
        if (fecha == null) return;
        // Solo agendamos si el vencimiento es futuro — los pasados ya
        // perdieron sentido de aviso preventivo.
        if (fecha.isBefore(hoy)) return;
        avisos.add(VencimientoAviso(
          fecha: fecha,
          tipoDoc: etiqueta,
          campoBase: campoBase,
        ));
      });

      // Nota: NO agendamos push para Póliza ART ni Formulario 931. Esos
      // docs son responsabilidad de la empresa empleadora — el chofer
      // no puede hacer nada al respecto si vencen, sería ruido. Los ve
      // en MIS VENCIMIENTOS read-only y listo. La oficina los renueva
      // una vez por empresa desde "Empresas y seguros".

      await NotificationService.cancelarTodosLosRecordatorios();
      if (avisos.isNotEmpty) {
        await NotificationService.agendarRecordatoriosVencimientos(avisos);
      }
    } catch (e) {
      debugPrint('No se pudieron reagendar recordatorios: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // OPERACIONES
  // ---------------------------------------------------------------------------

  Future<void> _ejecutarTarea({
    required Future<void> Function() tarea,
    required String mensajeExito,
  }) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    AppLoadingDialog.show(context);

    try {
      await tarea();
      if (!mounted) return;
      AppLoadingDialog.hide(navigator);
      AppFeedback.successOn(messenger, mensajeExito);
    } catch (e, s) {
      if (!mounted) return;
      AppLoadingDialog.hide(navigator);
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo completar la operación. Probá de nuevo en unos segundos.',
        tecnico: e,
        stack: s,
      );
    }
  }

  void _iniciarTramite({
    required String etiqueta,
    required String campo,
    required String idDoc,
    required String coleccion,
    required String nombreUsuario,
  }) {
    final fechaCtrl = TextEditingController();
    final formKey = GlobalKey<FormState>();

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withAlpha(20)),
        ),
        title: Text(
          'Actualizar $etiqueta',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Ingresá la fecha que figura en el nuevo carnet o certificado:',
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: fechaCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  color: AppColors.accentGreen,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
                decoration: InputDecoration(
                  hintText: 'DD/MM/AAAA',
                  hintStyle: const TextStyle(
                      color: Colors.white24, letterSpacing: 2),
                  filled: true,
                  fillColor: Colors.black.withAlpha(80),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                maxLength: 10,
                inputFormatters: [FechaInputFormatter()],
                validator: (value) =>
                    (value == null || value.length < 10)
                        ? 'Fecha incompleta'
                        : null,
              ),
              // Botón "Detectar fecha desde foto" — solo aparece en
              // mobile (Android/iOS), donde ML Kit funciona. El OCR es
              // best-effort: si falla, el chofer tipea como siempre.
              if (OcrService.soportado) ...[
                const SizedBox(height: 12),
                _BotonDetectarFecha(
                  onFechaDetectada: (fecha) {
                    final dd = fecha.day.toString().padLeft(2, '0');
                    final mm = fecha.month.toString().padLeft(2, '0');
                    fechaCtrl.text = '$dd/$mm/${fecha.year}';
                  },
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR',
                style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              if (formKey.currentState!.validate()) {
                final partes = fechaCtrl.text.split('/');
                final fechaS = '${partes[2]}-${partes[1]}-${partes[0]}';
                Navigator.pop(dCtx);
                _selectorArchivo(
                  etiqueta: etiqueta,
                  campo: campo,
                  fechaS: fechaS,
                  idDoc: idDoc,
                  coleccion: coleccion,
                  nombreUsuario: nombreUsuario,
                );
              }
            },
            child: const Text('CONTINUAR',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _selectorArchivo({
    required String etiqueta,
    required String campo,
    required String fechaS,
    required String idDoc,
    required String coleccion,
    required String nombreUsuario,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sCtx) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(25)),
          border: const Border(
              top: BorderSide(color: AppColors.accentGreen, width: 2)),
        ),
        child: SafeArea(
          child: Wrap(children: [
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'FOTO DEL COMPROBANTE',
                style: TextStyle(
                  color: AppColors.accentGreen,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.white70),
              title: const Text('Tomar con la cámara',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w500)),
              onTap: () async {
                final img = await ImagePicker()
                    .pickImage(source: ImageSource.camera, imageQuality: 50);
                if (sCtx.mounted) Navigator.pop(sCtx);
                if (img != null) {
                  // readAsBytes() es cross-platform — funciona en Web, donde
                  // img.path es un blob URL no abrible como File.
                  final bytes = await img.readAsBytes();
                  _enviar(
                    etiqueta: etiqueta,
                    campo: campo,
                    archivoBytes: bytes,
                    nombreOriginal: img.name,
                    fecha: fechaS,
                    idDoc: idDoc,
                    coleccion: coleccion,
                    nombreUsuario: nombreUsuario,
                  );
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file, color: Colors.white70),
              title: const Text('Cargar foto o PDF de la galería',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.w500)),
              onTap: () async {
                // withData: true asegura que `bytes` venga poblado en todas
                // las plataformas (en Web `path` no existe).
                final res = await FilePicker.pickFiles(
                  type: FileType.custom,
                  allowedExtensions: const ['pdf', 'jpg', 'png', 'jpeg'],
                  withData: true,
                );
                if (sCtx.mounted) Navigator.pop(sCtx);
                final picked = res?.files.singleOrNull;
                if (picked != null && picked.bytes != null) {
                  _enviar(
                    etiqueta: etiqueta,
                    campo: campo,
                    archivoBytes: picked.bytes!,
                    nombreOriginal: picked.name,
                    fecha: fechaS,
                    idDoc: idDoc,
                    coleccion: coleccion,
                    nombreUsuario: nombreUsuario,
                  );
                }
              },
            ),
            const SizedBox(height: 25),
          ]),
        ),
      ),
    );
  }

  void _enviar({
    required String etiqueta,
    required String campo,
    required Uint8List archivoBytes,
    required String nombreOriginal,
    required String fecha,
    required String idDoc,
    required String coleccion,
    required String nombreUsuario,
  }) {
    // _ejecutarTarea devuelve Future<void>; lo descartamos explícito
    // por consistencia con el resto del código y por si en el futuro
    // _enviar pasa a ser async (el lint dispararía).
    unawaited(_ejecutarTarea(
      tarea: () async => _revisionService.registrarSolicitud(
        dni: idDoc,
        nombreUsuario: nombreUsuario,
        etiqueta: etiqueta,
        campo: campo,
        archivoBytes: archivoBytes,
        nombreOriginal: nombreOriginal,
        fechaS: fecha,
        coleccionDestino: coleccion,
      ),
      mensajeExito: 'Solicitud enviada. Aguarde aprobación de la oficina.',
    ));
  }

  // ---------------------------------------------------------------------------
  // BUILD
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Mis Vencimientos',
      body: StreamBuilder<DocumentSnapshot>(
        stream: _empleadoStream,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const AppLoadingState();
          }
          if (!snapshot.hasData || !snapshot.data!.exists) {
            return const AppErrorState(
              title: 'No se encontraron tus datos',
            );
          }

          // Cast defensivo: si el documento llegara con un shape
          // distinto al esperado, mostramos error en lugar de crash.
          final raw = snapshot.data!.data();
          if (raw is! Map<String, dynamic>) {
            return const AppErrorState(
              title: 'Datos corruptos',
              subtitle:
                  'El formato de tu legajo no es válido. Contactá a la oficina.',
            );
          }
          final data = raw;
          final nombreChofer = (data['NOMBRE'] ?? 'Chofer').toString();
          final pVehiculo = (data['VEHICULO'] ?? '').toString().trim();
          final pEnganche = (data['ENGANCHE'] ?? '').toString().trim();

          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            children: [
              const _SectionHeader('LICENCIAS Y CARNETS'),
              _CardVencimientoUser(
                titulo: 'Licencia de Conducir',
                fecha: data['VENCIMIENTO_LICENCIA_DE_CONDUCIR'],
                campo: 'VENCIMIENTO_LICENCIA_DE_CONDUCIR',
                urlArchivo: data['ARCHIVO_LICENCIA_DE_CONDUCIR'],
                idDoc: widget.dniUser,
                onUpload: () => _iniciarTramite(
                  etiqueta: 'LICENCIA DE CONDUCIR',
                  campo: 'VENCIMIENTO_LICENCIA_DE_CONDUCIR',
                  idDoc: widget.dniUser,
                  coleccion: 'EMPLEADOS',
                  nombreUsuario: nombreChofer,
                ),
              ),
              _CardVencimientoUser(
                titulo: 'Preocupacional',
                fecha: data['VENCIMIENTO_PREOCUPACIONAL'],
                campo: 'VENCIMIENTO_PREOCUPACIONAL',
                urlArchivo: data['ARCHIVO_PREOCUPACIONAL'],
                idDoc: widget.dniUser,
                onUpload: () => _iniciarTramite(
                  etiqueta: 'PREOCUPACIONAL',
                  campo: 'VENCIMIENTO_PREOCUPACIONAL',
                  idDoc: widget.dniUser,
                  coleccion: 'EMPLEADOS',
                  nombreUsuario: nombreChofer,
                ),
              ),
              _CardVencimientoUser(
                titulo: 'Manejo Defensivo',
                fecha: data['VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO'],
                campo: 'VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO',
                urlArchivo: data['ARCHIVO_CURSO_DE_MANEJO_DEFENSIVO'],
                idDoc: widget.dniUser,
                onUpload: () => _iniciarTramite(
                  etiqueta: 'CURSO MANEJO',
                  campo: 'VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO',
                  idDoc: widget.dniUser,
                  coleccion: 'EMPLEADOS',
                  nombreUsuario: nombreChofer,
                ),
              ),
              const SizedBox(height: 20),

              const _SectionHeader('COBERTURAS LABORALES'),
              // Estos 4 docs son a NIVEL EMPRESA — el mismo PDF lo
              // comparten todos los empleados de Vecchi Ariel o de
              // Sucesión Vecchi Carlos. El admin los carga una sola
              // vez desde la pantalla "Empresas y seguros". Acá el
              // chofer solo los VE (read-only). SCVO se rotula como
              // "Seguro de Vida" porque es como lo conocen los choferes.
              _CardVencimientoEmpresa(
                titulo: AppDocsEmpresa.etiquetaPolizaArt,
                cuitEmpresa: AppEmpresasEmpleadoras.cuitDeStringEmpresa(
                    (data['EMPRESA'] ?? '').toString()),
                campoFecha: AppDocsEmpresa.campoFechaPolizaArt,
                campoUrl: AppDocsEmpresa.campoArchivoPolizaArt,
              ),
              _CardVencimientoEmpresa(
                titulo: AppDocsEmpresa.etiquetaForm931,
                cuitEmpresa: AppEmpresasEmpleadoras.cuitDeStringEmpresa(
                    (data['EMPRESA'] ?? '').toString()),
                campoFecha: AppDocsEmpresa.campoFechaForm931,
                campoUrl: AppDocsEmpresa.campoArchivoForm931,
              ),
              _CardVencimientoEmpresa(
                titulo: AppDocsEmpresa.etiquetaScvoChofer,
                cuitEmpresa: AppEmpresasEmpleadoras.cuitDeStringEmpresa(
                    (data['EMPRESA'] ?? '').toString()),
                campoFecha: AppDocsEmpresa.campoFechaScvo,
                campoUrl: AppDocsEmpresa.campoArchivoScvo,
              ),
              _CardVencimientoEmpresa(
                titulo: AppDocsEmpresa.etiquetaLibreDeudaSindical,
                cuitEmpresa: AppEmpresasEmpleadoras.cuitDeStringEmpresa(
                    (data['EMPRESA'] ?? '').toString()),
                campoFecha: AppDocsEmpresa.campoFechaLibreDeudaSindical,
                campoUrl: AppDocsEmpresa.campoArchivoLibreDeudaSindical,
              ),
              const SizedBox(height: 20),

              const _SectionHeader('PAPELES Y CONTROLES DEL EQUIPO'),
              if (pVehiculo.isNotEmpty && pVehiculo != '-')
                _DetalleEquipo(
                  patente: pVehiculo,
                  tipo: 'CAMIÓN',
                  nombreChofer: nombreChofer,
                  onTramiteVehiculo: _iniciarTramite,
                )
              else
                const _CardInformativa(
                    'No tenés un camión asignado'),
              const SizedBox(height: 12),
              if (pEnganche.isNotEmpty && pEnganche != '-')
                _DetalleEquipo(
                  patente: pEnganche,
                  tipo: 'ENGANCHE',
                  nombreChofer: nombreChofer,
                  onTramiteVehiculo: _iniciarTramite,
                )
              else
                const _CardInformativa(
                    'No tenés batea/tolva asignada'),
              const SizedBox(height: 30),
            ],
          );
        },
      ),
    );
  }
}

