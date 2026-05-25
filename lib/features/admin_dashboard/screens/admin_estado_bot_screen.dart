import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../whatsapp_bot/screens/admin_whatsapp_cola_screen.dart';
import '../../whatsapp_bot/screens/admin_whatsapp_historico_screen.dart';
import '../../whatsapp_bot/services/whatsapp_historico_service.dart';

// 14 widgets visuales (banner, cards de cola/mensajes/cron/config/info,
// errores recientes, bloque datos, filas, kill-switch) extraidos para
// mantener navegable este screen. Comparten privacidad via `part of`.
part 'admin_estado_bot_widgets.dart';

/// Pantalla "Estado del Bot" — muestra en tiempo real el estado del bot
/// Node.js que envía mensajes de WhatsApp.
///
/// Lee del doc `BOT_HEALTH/main` que el bot escribe cada
/// `HEARTBEAT_INTERVAL_SECONDS` segundos (default 60s, ver
/// `whatsapp-bot/src/health.js`).
///
/// Indicadores visuales:
/// - **Verde**: bot vivo y cliente WA listo. Heartbeat reciente.
/// - **Amarillo**: cliente WA en transición (iniciando, auth_pendiente,
///   autenticado-pero-no-listo) o heartbeat con > 90s de antigüedad.
/// - **Rojo**: cliente WA desconectado / auth_fallo, o heartbeat con
///   > 2 min de antigüedad (consideramos al bot caído).
///
/// La detección de "bot caído" la hacemos del lado cliente comparando
/// el `ultimoHeartbeat` con la hora actual del dispositivo. No
/// dependemos de un campo "vivo: true/false" porque si el bot crashea,
/// nadie podría ponerlo en false.
class AdminEstadoBotScreen extends StatefulWidget {
  const AdminEstadoBotScreen({super.key});

  @override
  State<AdminEstadoBotScreen> createState() => _AdminEstadoBotScreenState();
}

class _AdminEstadoBotScreenState extends State<AdminEstadoBotScreen> {
  /// Refresca cada 5s la diferencia "hace X segundos" sin tocar
  /// Firestore. El doc se actualiza solo (heartbeat del bot), pero el
  /// _texto_ "hace 12s" tiene que rerenderearse aunque no haya nuevo
  /// snapshot.
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Estado del Bot',
      actions: [
        // M8+M10 — acceso al histórico de mensajes (30 días). El
        // dashboard muestra "Cola en vivo" (TTL horas); el histórico
        // resuelve "¿se mandó tal mensaje el lunes?".
        IconButton(
          icon: const Icon(Icons.history, color: Colors.white),
          tooltip: 'Historial de mensajes (30 días)',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdminWhatsappHistoricoScreen(),
              ),
            );
          },
        ),
      ],
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('BOT_HEALTH')
            .doc('main')
            .snapshots(),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return _Mensaje(
              icono: Icons.error_outline,
              color: AppColors.error,
              texto: 'Error leyendo BOT_HEALTH: ${snap.error}',
            );
          }
          if (!snap.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: AppColors.accentGreen),
            );
          }
          if (!snap.data!.exists) {
            return const _Mensaje(
              icono: Icons.help_outline,
              color: AppColors.warning,
              texto:
                  'El bot nunca reportó estado.\n\n'
                  'Verificá en la PC del bot que esté corriendo:\n'
                  'cd whatsapp-bot && npm start',
            );
          }
          final data = snap.data!.data() as Map<String, dynamic>;
          return _DashboardBot(data: data);
        },
      ),
    );
  }
}

