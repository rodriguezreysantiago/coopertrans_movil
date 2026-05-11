import 'package:flutter/material.dart';

/// Avatar circular para fotos de perfil de empleados. Versión robusta
/// de `CircleAvatar(backgroundImage: NetworkImage(...))` que NO se
/// queda gris si la URL falla.
///
/// Diseño:
///   - Si [url] es null / vacía / "-" → muestra el ícono [icono].
///   - Si la URL carga OK → muestra la imagen recortada en círculo.
///   - Si la URL falla (404, timeout, host inválido) → muestra el
///     ícono [icono] vía `errorBuilder` en lugar de quedar gris.
///   - Mientras carga → muestra un spinner discreto.
///
/// **Caso operativo que motivó esto** (Santiago 2026-05-12): después
/// de la migración del proyecto Firebase de `logisticaapp-e539a` a
/// `coopertrans-movil`, 48 de 61 empleados quedaron con URL de
/// foto apuntando al bucket viejo que devuelve 404. El
/// `NetworkImage` original en `backgroundImage` falla silencioso y
/// el operador veía avatares vacíos.
class FotoPerfilAvatar extends StatelessWidget {
  /// URL de la foto. `null`, vacía o `"-"` se tratan igual: sin foto.
  final String? url;
  final double radius;
  final IconData icono;
  final Color iconColor;
  final Color fondo;

  const FotoPerfilAvatar({
    super.key,
    required this.url,
    this.radius = 24,
    this.icono = Icons.person,
    this.iconColor = Colors.white54,
    this.fondo = Colors.white12,
  });

  bool get _tieneUrl =>
      url != null && url!.isNotEmpty && url != '-';

  @override
  Widget build(BuildContext context) {
    if (!_tieneUrl) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: fondo,
        child: Icon(icono, color: iconColor, size: radius * 0.9),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: fondo,
      child: ClipOval(
        child: Image.network(
          url!,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          // Si falla (404, host muerto, token expirado, etc.) caemos al
          // ícono en lugar de dejar el círculo vacío.
          errorBuilder: (ctx, error, stack) {
            return Icon(icono, color: iconColor, size: radius * 0.9);
          },
          // Durante la carga, spinner mínimo. Importante para celus
          // lentos — si no, el operador no ve nada hasta que llegue.
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            return Center(
              child: SizedBox(
                width: radius * 0.6,
                height: radius * 0.6,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: iconColor,
                  value: progress.expectedTotalBytes == null
                      ? null
                      : progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
