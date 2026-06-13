// Cache OFFLINE de archivos de documentos (PDF/fotos) para "Mis papeles".
//
// Por qué: el chofer en un control de ruta puede estar SIN señal y necesita
// mostrar el RTO / seguro / ART. Firestore ya cachea los DATOS de los
// vencimientos (fechas), pero los ARCHIVOS (Firebase Storage) no. Este service
// los baja a disco la primera vez que hay red (o al abrir la pantalla con
// conexión) y los sirve desde el cache local cuando no hay red.
//
// Manual (dio + path_provider, ya en pubspec) — sin libs nuevas. Solo móvil:
// en web/desktop el navegador/SO maneja el cache y no persistimos (kIsWeb).
//
// Clave de cache = sha256(url) → estable entre corridas (String.hashCode NO lo
// es). Una re-subida del admin genera una URL nueva (token nuevo) → clave nueva
// → se vuelve a bajar; las viejas se podan por antigüedad.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';

class PapelesOfflineService {
  PapelesOfflineService._();

  static const _subdir = 'papeles_cache';
  static const Duration _maxEdad = Duration(days: 180);
  static Directory? _dirCache;

  static Future<Directory> _dir() async {
    if (_dirCache != null) return _dirCache!;
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/$_subdir');
    if (!await d.exists()) await d.create(recursive: true);
    return _dirCache = d;
  }

  static String _clave(String url) {
    final hash = sha256.convert(utf8.encode(url)).toString().substring(0, 40);
    final esPdf = url.split('?').first.toLowerCase().endsWith('.pdf');
    return '$hash.${esPdf ? 'pdf' : 'bin'}';
  }

  static Future<File> _file(String url) async =>
      File('${(await _dir()).path}/${_clave(url)}');

  /// ¿El archivo ya está en cache local? (para el indicador "disponible offline").
  static Future<bool> estaCacheado(String url) async {
    if (kIsWeb || url.isEmpty) return false;
    try {
      return await (await _file(url)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Bytes del archivo, CACHE-FIRST: si está en cache local lo sirve (sin red);
  /// si no y hay conexión, lo baja, lo cachea y lo devuelve; si no hay ni cache
  /// ni red, lanza. En web no cachea (descarga directa).
  static Future<Uint8List> bytes(
    String url, {
    void Function(double progreso)? onProgreso,
  }) async {
    if (url.isEmpty) throw Exception('URL vacía.');
    if (!kIsWeb) {
      final f = await _file(url);
      if (await f.exists()) {
        // Tocamos el mtime para que el prune por antigüedad no borre lo que el
        // chofer usa seguido.
        try {
          await f.setLastModified(DateTime.now());
        } catch (_) {}
        return f.readAsBytes();
      }
    }
    final bytes = await _descargar(url, onProgreso: onProgreso);
    if (!kIsWeb) {
      try {
        await (await _file(url)).writeAsBytes(bytes, flush: true);
      } catch (_) {
        /* si no se puede escribir, igual devolvemos los bytes en memoria */
      }
    }
    return bytes;
  }

  static Future<Uint8List> _descargar(
    String url, {
    void Function(double progreso)? onProgreso,
  }) async {
    final resp = await Dio().get<List<int>>(
      url,
      options: Options(
        responseType: ResponseType.bytes,
        receiveTimeout: const Duration(minutes: 3),
      ),
      onReceiveProgress: (recibido, total) {
        if (total > 0) onProgreso?.call(recibido / total);
      },
    );
    final data = resp.data;
    if (data == null || data.isEmpty) throw Exception('La descarga vino vacía.');
    return Uint8List.fromList(data);
  }

  /// Pre-descarga (best-effort) los archivos que NO estén cacheados. Se llama al
  /// abrir "Mis papeles" CON conexión, para tenerlos disponibles offline en un
  /// control. No bloquea ni tira: si falla uno, sigue con el resto.
  static Future<void> precachear(Iterable<String> urls) async {
    if (kIsWeb) return;
    for (final url in urls) {
      if (url.isEmpty) continue;
      try {
        if (await estaCacheado(url)) {
          // Tocamos el mtime para que no se pode lo que sigue vigente.
          try {
            await (await _file(url)).setLastModified(DateTime.now());
          } catch (_) {}
          continue;
        }
        await bytes(url);
      } catch (_) {
        /* best-effort: sin red o archivo caído no rompe el resto */
      }
    }
    await _podarViejos();
  }

  /// Borra del cache los archivos no tocados en [_maxEdad] (URLs viejas de
  /// re-subidas que ya no se referencian). Best-effort.
  static Future<void> _podarViejos() async {
    try {
      final limite = DateTime.now().subtract(_maxEdad);
      await for (final e in (await _dir()).list()) {
        if (e is File) {
          try {
            if ((await e.stat()).modified.isBefore(limite)) await e.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
