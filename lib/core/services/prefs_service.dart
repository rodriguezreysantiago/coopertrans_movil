import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio de preferencias del usuario logueado.
///
/// **Backend**: a partir de 2026-04-29 los datos viven en
/// [FlutterSecureStorage] (almacén seguro nativo de cada plataforma —
/// DPAPI en Windows, Keychain en iOS/macOS, KeyStore +
/// EncryptedSharedPreferences en Android). Antes vivían en
/// [SharedPreferences] (texto plano). El cambio defiende en profundidad
/// contra acceso físico al disco; el JWT de Firebase Auth ya estaba en
/// almacén seguro por el SDK, así que el riesgo previo era el de los
/// metadatos identificatorios (DNI, nombre, rol).
///
/// **API pública**: se mantiene SÍNCRONA para no requerir cambios en
/// los ~13 call sites repartidos por la app. Internamente, [init]
/// carga todos los valores a un cache en memoria al arranque; los
/// getters leen del cache, los setters escriben en cache y secure
/// storage.
///
/// **Migración**: el primer arranque después del upgrade copia los
/// valores que estaban en SharedPreferences hacia secure storage y
/// limpia los originales. Idempotente.
class PrefsService {
  // ─── Claves centralizadas ─────────────────────────────────────────
  static const String _keyDni = 'dni';
  static const String _keyNombre = 'nombre';
  static const String _keyRol = 'rol';
  static const String _keyIsLoggedIn = 'isLoggedIn';

  /// APODO del empleado, cacheado para que el saludo "Buen día, Santi"
  /// se renderice SÍNCRONO (sin esperar a Firestore al armar el dashboard).
  /// Sumado 2026-05-07 para sacar el flicker "Bienvenido Santiago" →
  /// "Bienvenido Santi" que pasaba al loguear.
  static const String _keyApodo = 'apodo';

  /// DNI del último usuario que logueó OK. Se mantiene **incluso después
  /// de logout** para auto-completar el campo en la pantalla de login.
  /// La contraseña NO se guarda nunca (eso sería un riesgo de seguridad).
  static const String _keyLastDni = 'lastDni';

  /// ID de instalación: identificador aleatorio ESTABLE por instalación de
  /// la app (no es el DNI ni el token FCM). Se usa como doc id en
  /// EMPLEADOS/{dni}/dispositivos/{installId} para que un refresh del token
  /// FCM actualice el MISMO doc (sin acumular tokens muertos). Persistente
  /// en secure storage; se genera una vez.
  static const String _keyInstallId = 'install_id';

  /// Flag de migración: si está, ya copiamos los valores viejos.
  /// Persistimos en secure storage para que sea idempotente entre
  /// reinstalaciones (si el secure storage se borra, la migración
  /// vuelve a correr — eso no rompe nada, solo lee SharedPreferences
  /// vacío y no copia nada).
  static const String _keyMigrationDone = '__migrated_from_shared_prefs_v1';

  // ─── Backend storage ──────────────────────────────────────────────
  // En flutter_secure_storage 10+, `encryptedSharedPreferences: true` se
  // deprecó (Jetpack Security está en sunset por Google) y la migración
  // al cifrado nuevo es automática en el primer acceso. Por eso el
  // constructor queda sin parámetros — el plugin elige el backend
  // adecuado por plataforma.
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  // ─── Cache en memoria (devuelto por los getters sync) ─────────────
  static String _dni = '';
  static String _nombre = '';
  static String _apodo = '';
  static String _rol = '';
  static bool _isLoggedIn = false;
  static String _lastDni = '';
  static String _installId = '';

  /// Inicializar antes del runApp. Lee todos los valores a memoria.
  /// Si es la primera ejecución después del upgrade, migra los datos
  /// que estaban en SharedPreferences al storage seguro.
  static Future<void> init() async {
    await _migrarDesdeSharedPrefsSiHaceFalta();

    _dni = await _secure.read(key: _keyDni) ?? '';
    _nombre = await _secure.read(key: _keyNombre) ?? '';
    _apodo = await _secure.read(key: _keyApodo) ?? '';
    _rol = await _secure.read(key: _keyRol) ?? '';
    _lastDni = await _secure.read(key: _keyLastDni) ?? '';
    final loggedRaw = await _secure.read(key: _keyIsLoggedIn);
    _isLoggedIn = loggedRaw == 'true';

    // Install id: generar una vez y persistir.
    _installId = await _secure.read(key: _keyInstallId) ?? '';
    if (_installId.isEmpty) {
      final r = Random.secure();
      _installId = List.generate(
        16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      await _secure.write(key: _keyInstallId, value: _installId);
    }
  }

  /// ID estable de esta instalación (ver [_keyInstallId]).
  static String get installId => _installId;

  /// Migración one-shot: si todavía no marcamos como migrado y existe
  /// SharedPreferences viejo con datos, los copia a secure storage y
  /// limpia el SharedPreferences. Si secure storage ya tiene la marca
  /// o las prefs viejas están vacías, no hace nada.
  static Future<void> _migrarDesdeSharedPrefsSiHaceFalta() async {
    try {
      final yaMigrado = await _secure.read(key: _keyMigrationDone);
      if (yaMigrado == 'true') return;

      final prefs = await SharedPreferences.getInstance();
      final viejoDni = prefs.getString(_keyDni);
      final viejoNombre = prefs.getString(_keyNombre);
      final viejoRol = prefs.getString(_keyRol);
      final viejoIsLogged = prefs.getBool(_keyIsLoggedIn);
      final viejoLastDni = prefs.getString(_keyLastDni);

      // Solo copiamos lo que efectivamente tenía valor — evitamos
      // sobreescribir secure storage con strings vacíos si las prefs
      // viejas estaban limpias.
      if (viejoDni != null && viejoDni.isNotEmpty) {
        await _secure.write(key: _keyDni, value: viejoDni);
      }
      if (viejoNombre != null && viejoNombre.isNotEmpty) {
        await _secure.write(key: _keyNombre, value: viejoNombre);
      }
      if (viejoRol != null && viejoRol.isNotEmpty) {
        await _secure.write(key: _keyRol, value: viejoRol);
      }
      // Bug A1 del code review: si viejoIsLogged era null, antes hacíamos
      // .toString() que daba "null" como string, lo cual nunca matchea
      // con `loggedRaw == 'true'` en init(). El check `!= null` ya
      // estaba pero es redundante con el de la guard del bloque, lo
      // mantengo explícito por claridad.
      if (viejoIsLogged != null) {
        // viejoIsLogged es bool aquí, NO null. .toString() da 'true'/'false'.
        await _secure.write(
            key: _keyIsLoggedIn, value: viejoIsLogged ? 'true' : 'false');
      }
      if (viejoLastDni != null && viejoLastDni.isNotEmpty) {
        await _secure.write(key: _keyLastDni, value: viejoLastDni);
      }

      // Limpiar las claves viejas — los datos ya están en secure storage.
      // No hacemos prefs.clear() porque puede haber otras prefs no
      // relacionadas (de plugins) que conviven en el mismo archivo.
      await prefs.remove(_keyDni);
      await prefs.remove(_keyNombre);
      await prefs.remove(_keyRol);
      await prefs.remove(_keyIsLoggedIn);
      await prefs.remove(_keyLastDni);

      await _secure.write(key: _keyMigrationDone, value: 'true');
      debugPrint('PrefsService: migración SharedPreferences → SecureStorage OK');
    } catch (e) {
      // Si la migración falla por algún motivo (storage corrupto, etc),
      // logueamos pero no bloqueamos el arranque — el usuario puede
      // re-loguear y se regenera todo.
      debugPrint('PrefsService: migración falló (no bloqueante): $e');
    }
  }

  // ─── Getters sync (leen del cache) ────────────────────────────────
  static String get dni => _dni;
  static String get nombre => _nombre;
  static String get apodo => _apodo;
  static String get rol => _rol;
  static bool get isLoggedIn => _isLoggedIn;
  static String get lastDni => _lastDni;

  // ─── Setters ──────────────────────────────────────────────────────

  /// Guardar datos del login. Actualiza cache + secure storage.
  /// `apodo` es opcional — string vacío significa "sin apodo cargado",
  /// el saludo cae al primer nombre del NOMBRE.
  static Future<void> guardarUsuario({
    required String dni,
    required String nombre,
    required String rol,
    String apodo = '',
  }) async {
    _dni = dni;
    _nombre = nombre;
    _apodo = apodo;
    _rol = rol;
    _isLoggedIn = true;
    _lastDni = dni;

    await _secure.write(key: _keyDni, value: dni);
    await _secure.write(key: _keyNombre, value: nombre);
    await _secure.write(key: _keyApodo, value: apodo);
    await _secure.write(key: _keyRol, value: rol);
    await _secure.write(key: _keyIsLoggedIn, value: 'true');
    // Recordatorio del último DNI para auto-completar próximos logins.
    await _secure.write(key: _keyLastDni, value: dni);
  }

  /// Actualiza solo el apodo cacheado. Usado por el dashboard cuando
  /// detecta (vía Firestore) un apodo distinto al guardado — para que
  /// la próxima sesión arranque con el valor correcto sin flicker.
  static Future<void> setApodo(String apodo) async {
    _apodo = apodo;
    await _secure.write(key: _keyApodo, value: apodo);
  }

  /// Cierra sesión: limpia cache y storage de identidad. NO borra
  /// `lastDni` para que la pantalla de login venga precargada.
  static Future<void> limpiarSesion() async {
    _dni = '';
    _nombre = '';
    _apodo = '';
    _rol = '';
    _isLoggedIn = false;

    await _secure.delete(key: _keyDni);
    await _secure.delete(key: _keyNombre);
    await _secure.delete(key: _keyApodo);
    await _secure.delete(key: _keyRol);
    // Aseguramos que el flag de logueo pase explícitamente a false
    // (no lo borramos para que getters lean 'false' explícito).
    await _secure.write(key: _keyIsLoggedIn, value: 'false');
    // OJO: lastDni NO se borra a propósito — queremos recordarlo para
    // que el próximo login venga con el campo precargado.
  }

  /// Compatibilidad con código anterior (algunos call sites usan `clear`).
  static Future<void> clear() async {
    await limpiarSesion();
  }
}
