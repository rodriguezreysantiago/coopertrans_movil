import 'dart:async';

import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/services/prefs_service.dart';

class LoginResult {
  final bool success;
  final String? message;
  final String? dni;
  final String? nombre;
  final String? rol;

  LoginResult({
    required this.success,
    this.message,
    this.dni,
    this.nombre,
    this.rol,
  });

  factory LoginResult.error(String message) {
    return LoginResult(success: false, message: message);
  }

  factory LoginResult.ok({
    required String dni,
    required String nombre,
    required String rol,
  }) {
    return LoginResult(success: true, dni: dni, nombre: nombre, rol: rol);
  }
}

/// Servicio de autenticación contra Firebase Auth.
///
/// **Cómo funciona el login**:
///
/// 1. El cliente llama a la Cloud Function `loginConDni` (callable Gen2)
///    vía **HTTPS directo** con [Dio]. NO usa el plugin
///    `cloud_functions` porque ese plugin no tiene implementación
///    nativa para Windows desktop. Llamando por HTTPS plano funciona
///    en todas las plataformas (Android, iOS, Web, Windows).
/// 2. La function valida las credenciales server-side contra la
///    colección `EMPLEADOS` (campo `CONTRASEÑA` con bcrypt o SHA-256
///    legacy) y emite un **custom token** con `uid = dni` y custom
///    claims `{rol, nombre}`.
/// 3. El cliente hace `signInWithCustomToken(token)` y queda logueado
///    en Firebase Auth (que sí tiene implementación Windows). A partir
///    de ahí `request.auth.uid` en las `firestore.rules` es el DNI.
///
/// **Protocolo callable**: el body se envuelve en `{"data": {...}}` y
/// la respuesta viene en `{"result": {...}}` (success) o
/// `{"error": {"message", "status"}}` (error). Replicamos ese contrato
/// manualmente acá.
class AuthService {
  /// URL del callable. Funciona para Gen2 vía la capa de routing
  /// legacy de Firebase. Si en el futuro cambiamos a Gen1 o cambia el
  /// pattern, solo se ajusta esta constante.
  static const String _loginEndpoint =
      'https://southamerica-east1-coopertrans-movil.cloudfunctions.net/loginConDni';

  final FirebaseAuth _auth;
  final Dio _dio;

  AuthService({
    FirebaseAuth? auth,
    Dio? dio,
  })  : _auth = auth ?? FirebaseAuth.instance,
        _dio = dio ?? Dio();

  /// Login con DNI + contraseña.
  ///
  /// Devuelve [LoginResult.ok] con los datos básicos del chofer si las
  /// credenciales son válidas, o [LoginResult.error] con un mensaje
  /// listo para mostrar en UI si algo falló.
  Future<LoginResult> login({
    required String dni,
    required String password,
  }) async {
    final cleanDni = dni.replaceAll(RegExp(r'[^0-9]'), '');
    final cleanPass = password.trim();

    // Pre-validación rápida — no quemamos invocaciones de la function
    // ni latencia de red si el form vino vacío.
    if (cleanDni.isEmpty || cleanPass.isEmpty) {
      return LoginResult.error('Complete todos los campos requeridos.');
    }

    try {
      // 1) Pedimos el custom token a la function por HTTPS.
      final response = await _dio.post<Map<String, dynamic>>(
        _loginEndpoint,
        data: {
          // Protocolo callable: payload va envuelto en `data`.
          'data': {
            'dni': cleanDni,
            'password': cleanPass,
          },
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          // No tiramos exception por status code — manejamos el error
          // body abajo (la function devuelve 4xx con body estructurado).
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      ).timeout(
        const Duration(seconds: 12),
        onTimeout: () => throw TimeoutException('Sin conexión.'),
      );

      // Errores HTTP de la function: el body trae `{"error": {...}}`.
      if (response.statusCode == null || response.statusCode! >= 400) {
        final err = response.data?['error'] as Map<String, dynamic>?;
        final code = (err?['status'] ?? 'unknown').toString();
        final message = (err?['message'] ?? '').toString();
        debugPrint('🚨 loginConDni HTTP ${response.statusCode} → $code: $message');
        return LoginResult.error(
          message.isNotEmpty ? message : _mensajeFallback(code),
        );
      }

      // Respuesta OK del callable: body es `{"result": {...}}`.
      final result = response.data?['result'] as Map<String, dynamic>?;
      if (result == null) {
        return LoginResult.error(
            'No se pudo iniciar sesión (respuesta inválida).');
      }
      final token = (result['token'] ?? '').toString();
      if (token.isEmpty) {
        return LoginResult.error(
            'No se pudo iniciar sesión (respuesta sin token).');
      }
      final nombre = (result['nombre'] ?? 'Usuario').toString();
      final apodo = (result['apodo'] ?? '').toString().trim();
      final rol = (result['rol'] ?? 'USUARIO').toString();

      // 2) Iniciamos sesión en Firebase Auth con el custom token.
      await _auth.signInWithCustomToken(token);

      // 3) Persistimos los datos en SharedPreferences para que la app
      //    los muestre rápido sin tocar Firestore en cada pantalla.
      // Apodo cacheado para que el saludo del dashboard sea síncrono
      // (sin flicker "Bienvenido Santiago" → "Bienvenido Santi").
      await PrefsService.guardarUsuario(
        dni: cleanDni,
        nombre: nombre,
        apodo: apodo,
        rol: rol,
      );

      return LoginResult.ok(dni: cleanDni, nombre: nombre, rol: rol);
    } on FirebaseAuthException catch (e) {
      debugPrint('🚨 signInWithCustomToken → ${e.code}: ${e.message}');
      return LoginResult.error(
          'No se pudo iniciar sesión (${e.code}). Reintentá en un momento.');
    } on TimeoutException catch (_) {
      return LoginResult.error(
          'Tiempo de espera agotado. Verifique su señal de internet.');
    } on DioException catch (e) {
      debugPrint('🚨 loginConDni Dio → type=${e.type} msg=${e.message}');
      debugPrint('   request URL: ${e.requestOptions.uri}');
      debugPrint('   request method: ${e.requestOptions.method}');
      debugPrint('   response status: ${e.response?.statusCode}');
      debugPrint('   response data: ${e.response?.data}');
      if (e.error != null) {
        debugPrint('   underlying error: ${e.error.runtimeType}: ${e.error}');
      }
      return LoginResult.error(
          'No se pudo conectar al servidor. Verifique su conexión.');
    } catch (e, stack) {
      debugPrint('🚨 AuthService.login error: $e');
      debugPrint(stack.toString());
      return LoginResult.error('Error interno al iniciar sesión.');
    }
  }

  /// Cierra la sesión: Firebase Auth + SharedPreferences locales.
  Future<void> logout() async {
    try {
      await _auth.signOut();
    } catch (e) {
      debugPrint('⚠️ Error al cerrar sesión Firebase: $e');
      // No bloqueamos el logout si Firebase falla — limpiamos prefs igual.
    }
    await PrefsService.clear();
  }

  /// Mensaje legible cuando la function devuelve un código pero sin
  /// `message` poblado (no debería pasar en nuestro código pero
  /// defendemos la UI igual).
  String _mensajeFallback(String code) {
    switch (code) {
      case 'INVALID_ARGUMENT':
      case 'invalid-argument':
        return 'Datos incompletos o inválidos.';
      case 'NOT_FOUND':
      case 'not-found':
        return 'El usuario no existe o el DNI es incorrecto.';
      case 'PERMISSION_DENIED':
      case 'permission-denied':
        return 'Credenciales incorrectas.';
      case 'FAILED_PRECONDITION':
      case 'failed-precondition':
        return 'El usuario no tiene contraseña configurada.';
      case 'RESOURCE_EXHAUSTED':
      case 'resource-exhausted':
        // Rate limit del login (5 intentos fallidos → 5 min de bloqueo).
        // El mensaje específico ("reintentá en X minutos") viene del
        // server, esto es solo fallback genérico.
        return 'Demasiados intentos fallidos. Esperá unos minutos antes de reintentar.';
      case 'UNAVAILABLE':
      case 'unavailable':
        return 'Servicio no disponible. Intentá de nuevo en un rato.';
      default:
        return 'Error al iniciar sesión.';
    }
  }
}
