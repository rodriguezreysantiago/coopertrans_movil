import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Avatar circular para fotos de perfil de empleados — REFACTOR 2026-05-27.
///
/// **Cambios vs. la versión previa:**
/// - Si no hay URL de foto, en lugar de un icono gris sobre fondo gris,
///   muestra **las iniciales del nombre sobre un círculo cobalto**.
///   Free identity: cada chofer empieza a "tener cara" aunque no haya
///   subido su foto todavía.
/// - El icono original sigue disponible como fallback si tampoco hay
///   nombre (caso: avatar de un usuario sin legajo cargado).
/// - Si la URL falla, primero intenta iniciales; si tampoco hay nombre,
///   cae al icono.
///
/// **Compat.** API retrocompatible — `nombre` es opcional. Los call-sites
/// existentes que solo pasan `url` siguen funcionando, solo que cuando
/// no haya URL van a ver el ícono gris hasta que se le agregue `nombre`.
///
/// **Caso operativo que motivó esto** (Santiago 2026-05-12): después
/// de la migración del proyecto Firebase de `logisticaapp-e539a` a
/// `coopertrans-movil`, 48 de 61 empleados quedaron con URL de foto
/// apuntando al bucket viejo que devuelve 404. El `NetworkImage`
/// original en `backgroundImage` falla silencioso y el operador veía
/// avatares vacíos. La review de diseño agregó: "y si encima fallan,
/// que al menos se vean las iniciales".
class FotoPerfilAvatar extends StatelessWidget {
  /// URL de la foto. `null`, vacía o `"-"` se tratan igual: sin foto.
  final String? url;

  /// Nombre completo del empleado — usado para calcular iniciales si
  /// no hay foto. Opcional para no romper call-sites; si no se pasa,
  /// el fallback es el [icono].
  final String? nombre;

  final double radius;
  final IconData icono;

  /// Color del fondo cuando se muestran iniciales. Default = brand.
  final Color initialsBackground;

  /// Color del fondo cuando se muestra el ícono fallback (sin nombre).
  final Color iconBackground;

  /// Color del ícono fallback.
  final Color iconColor;

  const FotoPerfilAvatar({
    super.key,
    required this.url,
    this.nombre,
    this.radius = 24,
    this.icono = Icons.person,
    this.initialsBackground = AppColors.brand,
    this.iconBackground = AppColors.surface3,
    this.iconColor = AppColors.textTertiary,
  });

  bool get _tieneUrl => url != null && url!.isNotEmpty && url != '-';

  /// Calcula iniciales del [nombre] — máximo 2 letras.
  /// "Santiago González" → "SG"
  /// "MARÍA" → "M"
  /// "Juan Carlos Pérez Lopez" → "JP" (primer + último)
  /// null / vacío → null (no hay iniciales, usar icono).
  String? get _iniciales {
    final n = nombre?.trim() ?? '';
    if (n.isEmpty) return null;
    final partes = n.split(RegExp(r'\s+'));
    if (partes.isEmpty) return null;
    if (partes.length == 1) {
      final letra = partes.first;
      return letra.isEmpty ? null : letra[0].toUpperCase();
    }
    final primera = partes.first;
    final ultima = partes.last;
    final a = primera.isEmpty ? '' : primera[0];
    final b = ultima.isEmpty ? '' : ultima[0];
    final s = (a + b).toUpperCase();
    return s.isEmpty ? null : s;
  }

  Widget _placeholderSinFoto() {
    final ini = _iniciales;
    if (ini == null) {
      return CircleAvatar(
        radius: radius,
        backgroundColor: iconBackground,
        child: Icon(icono, color: iconColor, size: radius * 0.9),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: initialsBackground,
      child: Text(
        ini,
        style: TextStyle(
          color: Colors.white,
          fontSize: radius * 0.75,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
          height: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_tieneUrl) return _placeholderSinFoto();

    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.surface3,
      child: ClipOval(
        child: Image.network(
          url!,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          // Si falla (404, host muerto, token expirado, etc.) caemos al
          // placeholder de iniciales (o ícono si no hay nombre) en lugar
          // de dejar el círculo vacío.
          errorBuilder: (ctx, error, stack) => _placeholderSinFoto(),
          loadingBuilder: (ctx, child, progress) {
            if (progress == null) return child;
            // Durante la carga: si tenemos iniciales, las mostramos como
            // skeleton (mejor que un spinner vacío). Si no, spinner.
            final ini = _iniciales;
            if (ini != null) {
              return CircleAvatar(
                radius: radius,
                backgroundColor: initialsBackground.withAlpha(120),
                child: Text(
                  ini,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: radius * 0.75,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    height: 1,
                  ),
                ),
              );
            }
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
