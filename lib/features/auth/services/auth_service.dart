import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../../../core/constants/app_constants.dart';
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

      // 2) Limpiamos cualquier sesión previa de Firebase Auth ANTES de
      //    intercambiar el custom token. Sin esto, si quedó un user
      //    pegado de un intento previo (ej. el reloj del device estaba
      //    desfasado y el token vencía instantáneo), el SDK puede
      //    quedar en un estado raro y `signInWithCustomToken` se cuelga
      //    para siempre sin tirar excepción. Esto pasa puntualmente en
      //    Android cuando los Google Play Services están desactualizados
      //    o el clock skew es >5min.
      try {
        if (_auth.currentUser != null) {
          await _auth.signOut().timeout(const Duration(seconds: 5));
        }
      } catch (e) {
        debugPrint('⚠️ signOut previo falló (lo ignoramos): $e');
      }

      // 3) Iniciamos sesión en Firebase Auth con el custom token.
      //
      // Lleva timeout explícito de 15s — el SDK NO lo trae por default
      // y, ante problemas de red / Play Services / reloj desfasado,
      // queda colgado indefinido. Mejor fallar rápido y mostrar un
      // error accionable que dejar al user mirando un spinner eterno.
      debugPrint('🔐 signInWithCustomToken iniciando…');
      await _auth.signInWithCustomToken(token).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException(
          'Firebase Auth no respondió. Revisá fecha/hora del celular '
          '(debe estar en automático) y que Google Play Services esté '
          'actualizado.',
        ),
      );
      debugPrint('🔐 signInWithCustomToken OK uid=${_auth.currentUser?.uid}');

      // 4) Persistimos los datos en SharedPreferences para que la app
      //    los muestre rápido sin tocar Firestore en cada pantalla.
      // Apodo cacheado para que el saludo del dashboard sea síncrono
      // (sin flicker "Bienvenido Santiago" → "Bienvenido Santi").
      await PrefsService.guardarUsuario(
        dni: cleanDni,
        nombre: nombre,
        apodo: apodo,
        rol: rol,
      );

      // 5) Pre-warm del cache de Firestore: leemos el legajo del chofer
      //    una vez después del login para que el cache offline quede
      //    poblado. Las pantallas "Mi Perfil" / "Mi Unidad" usan
      //    `snapshots()` — con el cache caliente, esos streams emiten
      //    el primer snapshot al instante (cached) en lugar de esperar
      //    el round-trip al server. Crítico en celus con red lenta
      //    (caso reportado por chofer 16969961 en Android lento donde
      //    todo demora 3-4 min).
      //
      //    Timeout corto (5s) — si la red está MUY lenta, no bloqueamos
      //    el login completo por esto. El cliente igual entra; la
      //    siguiente pantalla hará get on-demand cuando pueda.
      _prewarmCacheLegajo(cleanDni);

      return LoginResult.ok(dni: cleanDni, nombre: nombre, rol: rol);
    } on FirebaseAuthException catch (e) {
      debugPrint('🚨 signInWithCustomToken → ${e.code}: ${e.message}');
      return LoginResult.error(
          'No se pudo iniciar sesión (${e.code}). Reintentá en un momento.');
    } on TimeoutException catch (e) {
      // El TimeoutException puede venir del HTTP a la function (sin
      // conexión / function fría / red lenta) o del signInWithCustomToken
      // (Play Services / clock skew). Si trae mensaje específico lo
      // mostramos tal cual; si no, fallback al genérico de red.
      final msg = e.message?.trim();
      return LoginResult.error(
        (msg != null && msg.isNotEmpty)
            ? msg
            : 'Tiempo de espera agotado. Verifique su señal de internet.',
      );
    } on DioException catch (e) {
      // Logs defensivos: NO incluir el body de la respuesta (puede traer
      // tokens si el callable tuvo éxito parcial), NO incluir el path
      // completo de la URL (preservar host pero recortar query/segments
      // que podrían contener identificadores). Solo lo necesario para
      // diagnosticar errores de red sin filtrar secretos.
      final host = e.requestOptions.uri.host;
      final errorBody = e.response?.data;
      // Si el body es un Map con campo "error.message", logueamos solo
      // ese campo (es el mensaje de error preparado server-side, no
      // contiene tokens). Si es otra forma, mostramos el tipo nada más.
      String resumenBody = '<sin body>';
      if (errorBody is Map) {
        final err = errorBody['error'];
        if (err is Map && err['message'] != null) {
          resumenBody = err['message'].toString();
        } else {
          resumenBody = '<map sin error.message>';
        }
      } else if (errorBody != null) {
        resumenBody = '<${errorBody.runtimeType}>';
      }
      debugPrint('🚨 loginConDni Dio → type=${e.type} host=$host '
          'status=${e.response?.statusCode} body=$resumenBody');
      if (e.error != null) {
        debugPrint('   underlying error: ${e.error.runtimeType}');
      }
      return LoginResult.error(
          'No se pudo conectar al servidor. Verifique su conexión.');
    } catch (e, stack) {
      debugPrint('🚨 AuthService.login error: $e');
      debugPrint(stack.toString());
      return LoginResult.error('Error interno al iniciar sesión.');
    }
  }

  /// Hace una lectura fire-and-forget del legajo del chofer en
  /// Firestore para precargar el cache offline. Si falla o tarda, lo
  /// ignoramos — el login ya terminó OK y las pantallas que necesitan
  /// el legajo lo van a leer por su cuenta (con el cache de Firestore
  /// trabajando a favor cuando llegue la respuesta).
  ///
  /// No await: devolvemos al toque para no bloquear el login del user.
  void _prewarmCacheLegajo(String dni) {
    FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .doc(dni)
        .get()
        .timeout(const Duration(seconds: 5))
        .then((_) {
      debugPrint('✅ pre-warm cache legajo OK ($dni)');
    }).catchError((e) {
      debugPrint('⚠️ pre-warm cache legajo falló (no crítico): $e');
    });
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
