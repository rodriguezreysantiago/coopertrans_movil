import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../../shared/utils/app_feedback.dart';

/// Helper compartido para guardar y abrir reportes Excel desde la app.
///
/// Encapsula 3 cosas que antes estaban duplicadas en cada report_*.dart:
/// 1. **Nombre único**: agrega `_HHmmss` al nombre default — antes el
///    nombre solo tenía `yyyy_MM_dd`, así que dos reportes generados el
///    mismo día se sobrescribían en silencio (Santiago: "los nombres
///    aparentemente se sobreescriben si sacas 2 el mismo día").
/// 2. **File picker en Windows**: muestra un diálogo nativo para que
///    el usuario elija dónde guardar el .xlsx (antes iba siempre a un
///    directorio temporal opaco). Si cancela, fallback a `Downloads`.
/// 3. **Apertura post-guardado**: en Windows abre el archivo con la app
///    por defecto (Excel), en Android/iOS comparte vía SharePlus.
///
/// Devuelve `true` si el archivo se guardó (o se abrió en mobile),
/// `false` si el usuario canceló o hubo un error (ya logueado por feedback).
class ReportSaveHelper {
  ReportSaveHelper._();

  /// Calcula el nombre default del archivo agregando timestamp único:
  /// `Flota_2026_05_03_143022.xlsx` — `prefix_yyyy_MM_dd_HHmmss.xlsx`.
  ///
  /// Si tu reporte tiene un sufijo extra (ej. rango de fechas), pasalo
  /// con `sufijoExtra` y queda como `prefix_yyyy_MM_dd_HHmmss_sufijo.xlsx`.
  static String nombreUnico(String prefix, {String? sufijoExtra}) {
    final ts = DateFormat('yyyy_MM_dd_HHmmss').format(DateTime.now());
    final extra = sufijoExtra == null ? '' : '_$sufijoExtra';
    return '$prefix${'_'}$ts$extra.xlsx';
  }

  /// Guarda el `.xlsx` en disco y lo abre / comparte según la plataforma.
  ///
  /// Comportamiento:
  /// - **Windows**: muestra `FilePicker.platform.saveFile()` con el
  ///   nombre default. Si el usuario elige path, guarda ahí y abre con
  ///   la app default (Excel). Si cancela, devuelve false (no escribe
  ///   nada — el usuario decidió no exportar).
  /// - **Android / iOS / macOS / Linux**: guarda en directorio temporal
  ///   y comparte vía `SharePlus` (mismo flujo histórico).
  ///
  /// Mensajes de error / éxito se muestran vía [messenger] (capturalo
  /// ANTES del `await` con `ScaffoldMessenger.of(context)`).
  static Future<bool> guardarYAbrir({
    required List<int> bytes,
    required String nombreDefault,
    required ScaffoldMessengerState messenger,
    String? textoCompartir,
  }) async {
    try {
      // file_picker 11.x con `bytes` requerido en saveFile sobre Windows
      // — el plugin internamente escribe el archivo y devuelve el path.
      // Lo casteamos a Uint8List si hace falta (excel.save() devuelve
      // List<int>).
      final bytesU8 =
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

      if (Platform.isWindows) {
        // Diálogo nativo de Windows. Devuelve null si el usuario cancela.
        // En 11.x hay que pasar `bytes` para que la implementación de
        // Windows pueda escribir el archivo en el path elegido.
        final destino = await FilePicker.saveFile(
          dialogTitle: 'Guardar reporte',
          fileName: nombreDefault,
          type: FileType.custom,
          allowedExtensions: const ['xlsx'],
          bytes: bytesU8,
        );
        if (destino == null) {
          AppFeedback.infoOn(messenger, 'Exportación cancelada.');
          return false;
        }
        final path = destino.toLowerCase().endsWith('.xlsx')
            ? destino
            : '$destino.xlsx';
        // saveFile en algunas implementaciones SOLO retorna el path
        // pero no escribe los bytes (depende del backend) — escribimos
        // a mano para garantizar portabilidad.
        if (!File(path).existsSync() ||
            File(path).lengthSync() == 0) {
          File(path).writeAsBytesSync(bytesU8);
        }
        // Abrir con la app default (Excel típicamente). Process.run no
        // bloquea hasta cerrar Excel; lanza el proceso y vuelve.
        await Process.run('cmd', ['/c', 'start', '', path]);
        AppFeedback.successOn(messenger, 'Reporte guardado: $path');
        return true;
      }

      // Mobile / desktop no-Windows: temp + share (flujo original).
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$nombreDefault';
      File(path).writeAsBytesSync(bytesU8);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path)],
          text: textoCompartir ?? 'Reporte — Coopertrans Móvil',
        ),
      );
      return true;
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo guardar el reporte. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
      return false;
    }
  }
}
