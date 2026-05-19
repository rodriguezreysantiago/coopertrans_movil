import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/prefs_service.dart';
import '../../../shared/utils/phone_formatter.dart';

/// Cliente para la cola de WhatsApp automatizado.
///
/// Es la otra punta del bot Node.js (subcarpeta `whatsapp-bot/`). La
/// app escribe docs a `COLA_WHATSAPP` con la forma esperada y el bot
/// los procesa de forma asincrónica. Mantener este formato sincronizado
/// con `whatsapp-bot/src/firestore.js`.
///
/// Estados del workflow:
/// - `PENDIENTE`: la app acaba de encolar; el bot todavía no lo tomó.
/// - `PROCESANDO`: el bot lo levantó y está en el delay anti-bot.
/// - `ENVIADO`: el mensaje salió. `enviado_en` tiene timestamp.
/// - `ERROR`: algo falló. `error` tiene el detalle textual.
///
/// El admin puede reintentar un ERROR cambiándolo a PENDIENTE de nuevo
/// (ver pantalla "Cola de WhatsApp").
class WhatsAppColaService {
  WhatsAppColaService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Nombre de la colección. Constante porque el bot también la usa.
  static const String coleccion = 'COLA_WHATSAPP';

  /// Encola un mensaje para que el bot lo envíe.
  ///
  /// [telefono]: cualquier formato razonable AR — con o sin `+54 9`,
  /// con o sin guiones/espacios. `PhoneFormatter.paraGuardar` lo
  /// normaliza al formato canónico `549<área><nro>` que necesita el
  /// bot para WhatsApp Web. Si el dato no es un teléfono válido, el
  /// doc igual se encola con telefono vacío y el bot lo va a marcar
  /// como ERROR (defensa en profundidad — no fallamos la encolada
  /// silenciosamente para que el admin vea el problema en pantalla).
  ///
  /// [mensaje]: texto plano del mensaje. WhatsApp soporta markdown
  /// ligero (`*bold*`, `_italic_`, `~strike~`).
  ///
  /// [origen], [destinatarioColeccion], [destinatarioId], [campoBase]
  /// se persisten para auditoría. Sirven para que después el admin
  /// pueda saber "¿de qué chofer y qué papel salió este aviso?".
  ///
  /// Devuelve el `id` del doc encolado.
  Future<String> encolar({
    required String telefono,
    required String mensaje,
    String origen = 'manual',
    String? destinatarioColeccion,
    String? destinatarioId,
    String? campoBase,
  }) async {
    // Normalización defensiva: aunque casi todos los callers ya pasan
    // teléfonos guardados (que vienen de EMPLEADOS.TELEFONO normalizado),
    // si alguno llega con formato distinto se arregla acá.
    final telefonoNorm = PhoneFormatter.paraGuardar(telefono);
    final ref = await _db.collection(coleccion).add({
      'telefono': telefonoNorm.isNotEmpty ? telefonoNorm : telefono.trim(),
      'mensaje': mensaje,
      'estado': 'PENDIENTE',
      'encolado_en': FieldValue.serverTimestamp(),
      'enviado_en': null,
      'error': null,
      'intentos': 0,
      'origen': origen,
      if (destinatarioColeccion != null)
        'destinatario_coleccion': destinatarioColeccion,
      if (destinatarioId != null) 'destinatario_id': destinatarioId,
      if (campoBase != null) 'campo_base': campoBase,
      'admin_dni': PrefsService.dni,
      'admin_nombre': PrefsService.nombre,
    });
    return ref.id;
  }

  /// Reintenta un envío que terminó en ERROR. Cambia el estado a
  /// `PENDIENTE` y limpia el mensaje de error. El bot lo levantará
  /// en el próximo ciclo del listener.
  Future<void> reintentar(String docId) async {
    await _db.collection(coleccion).doc(docId).update({
      'estado': 'PENDIENTE',
      'error': null,
      // No reseteamos `intentos` para que se vea cuántas veces se
      // intentó — útil para detectar números problemáticos.
    });
  }

  /// Borra un doc de la cola. Útil para limpiar históricos antiguos
  /// o para cancelar un envío que el admin ya no quiere mandar.
  Future<void> eliminar(String docId) async {
    await _db.collection(coleccion).doc(docId).delete();
  }

  /// Stream con los últimos N docs ordenados por timestamp de
  /// encolado descendente. Útil para la pantalla "Cola de WhatsApp".
  ///
  /// Si `estado` está, agrega `where('estado', '==', estado)` server-side.
  /// Fix Santiago 2026-05-19: antes el filtro se aplicaba client-side
  /// sobre los últimos 100 docs traídos — si los 4 errores estaban en
  /// la posición 100+ por antigüedad, el listado decía "Sin mensajes
  /// con estado ERROR" mientras el header del resumen (que traía 200)
  /// sí los contaba. Inconsistencia confusa. Ahora el filtro va al
  /// query → el listado siempre encuentra todos los matches del
  /// estado pedido independientemente de la ventana cronológica.
  Stream<QuerySnapshot> streamCola({int limit = 100, String? estado}) {
    Query<Map<String, dynamic>> q =
        _db.collection(coleccion).orderBy('encolado_en', descending: true);
    if (estado != null && estado.isNotEmpty) {
      q = q.where('estado', isEqualTo: estado);
    }
    return q.limit(limit).snapshots();
  }
}
