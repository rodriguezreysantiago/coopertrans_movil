import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../constants/app_colors.dart';

/// Banner "Conexión lenta" — REFACTOR 2026-05-27.
///
/// Generalización del patrón `_conexionLenta` que existía solo en
/// [UserMiPerfilScreen]. Se activa automáticamente si pasan más de
/// [deadline] sin que el [stream] emita un primer evento.
///
/// **Uso:**
///
/// ```dart
/// final stream = FirebaseFirestore.instance.collection('X').doc(id).snapshots();
///
/// AppOfflineBanner(
///   stream: stream,
///   child: StreamBuilder(...),
/// )
/// ```
///
/// El banner aparece arriba del [child] cuando hace lag. Cuando llega
/// el primer dato, se va.
///
/// **Layout.** Slim — 28px de alto, no roba demasiado del viewport.
/// **Color.** Warning (naranja), no error rojo — la conexión lenta no
/// es un error, es una degradación.
class AppOfflineBanner<T> extends StatefulWidget {
  final Stream<T> stream;
  final Widget child;
  final Duration deadline;
  final String mensaje;

  const AppOfflineBanner({
    super.key,
    required this.stream,
    required this.child,
    this.deadline = const Duration(seconds: 10),
    this.mensaje = 'Conexión lenta — mostrando datos guardados',
  });

  @override
  State<AppOfflineBanner<T>> createState() => _AppOfflineBannerState<T>();
}

class _AppOfflineBannerState<T> extends State<AppOfflineBanner<T>> {
  bool _lenta = false;
  bool _llegoAlgo = false;
  Timer? _timer;
  StreamSubscription<T>? _sub;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.deadline, () {
      if (mounted && !_llegoAlgo) setState(() => _lenta = true);
    });
    _sub = widget.stream.listen((_) {
      if (mounted) {
        setState(() {
          _llegoAlgo = true;
          _lenta = false;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 240),
          transitionBuilder: (c, anim) => SizeTransition(
            sizeFactor: anim,
            // axisAlignment:-1 (deprecado tras 3.41) -> se despliega desde arriba.
            alignment: Alignment.topLeft,
            child: c,
          ),
          child: _lenta
              ? _BannerInterno(
                  key: const ValueKey('lenta'),
                  mensaje: widget.mensaje,
                )
              : const SizedBox.shrink(key: ValueKey('ok')),
        ),
        Expanded(child: widget.child),
      ],
    );
  }
}

class _BannerInterno extends StatelessWidget {
  final String mensaje;
  const _BannerInterno({super.key, required this.mensaje});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.warning.withAlpha(40),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            color: AppColors.warning,
            size: 16,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              mensaje,
              style: AppType.label.copyWith(color: AppColors.warning),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
