import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/responsive_grid.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../core/services/prefs_service.dart';
import '../../auth/services/auth_service.dart';
import '../../vehicles/providers/vehiculo_provider.dart';
import '../../vehicles/services/vehiculo_repository.dart';

/// Panel principal — primera pantalla después del login.
///
/// Muestra un grid 2×2 con accesos rápidos a las funciones del chofer.
/// Si el usuario es ADMIN, aparece una cuarta tarjeta para entrar al
/// panel de administración.
class MainPanel extends StatelessWidget {
  final String dni;
  final String nombre;
  final String rol;

  MainPanel({
    super.key,
    required this.dni,
    required this.nombre,
    required this.rol,
  });

  final AuthService _authService = AuthService();

  bool get _isAdmin => rol.trim().toUpperCase() == 'ADMIN';

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      // El logo a la izquierda del AppBar ya muestra "Coopertrans Móvil";
      // poner appName acá producía "Coopertrans Móvil | Coopertrans Móvil".
      title: 'Menú Principal',
      actions: [
        IconButton(
          icon: const Icon(Icons.logout_outlined),
          tooltip: 'Cerrar sesión',
          onPressed: () => _logout(context),
        ),
      ],
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 20),
                _WelcomeHeader(dni: dni, nombre: nombre),
                const SizedBox(height: 30),
                Expanded(
                  child: LayoutBuilder(
                    builder: (ctx, constraints) {
                      // Botones del menú: 3 (chofer) o 4 (admin) en grid
                      // 2x2. Calculamos el ratio según el alto disponible
                      // para que las cards llenen la pantalla SIN scroll
                      // interno. Antes era ratio 1.2 fijo → en mobile
                      // chico el GridView scrolleaba internamente y
                      // dejaba ver solo 2 botones.
                      const cols = 2;
                      const spacing = 15.0;
                      // Cant filas reales = ceil(N / cols). Con 3 botones
                      // y 2 cols, son 2 filas (la 2ª con 1 hueco). Con 4
                      // botones, idem 2 filas pero llenas. Mismo cálculo.
                      final n = _isAdmin ? 4 : 3;
                      final filas = (n / cols).ceil();
                      // Helper compartido — clamp 0.5..2.0 + fallback
                      // 1.2 (botones más anchos que altos por diseño).
                      final ratio = computeGridRatio(
                        boxWidth: constraints.maxWidth,
                        boxHeight: constraints.maxHeight,
                        cols: cols,
                        rows: filas,
                        spacing: spacing,
                        clampMin: 0.5,
                        fallback: 1.2,
                      );
                      return GridView.count(
                        crossAxisCount: cols,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        childAspectRatio: ratio,
                        physics: const NeverScrollableScrollPhysics(),
                        children: [
                          _MenuButton(
                            titulo: 'MI PERFIL',
                            icono: Icons.person_pin_outlined,
                            color: AppColors.accentBlue,
                            onTap: () => Navigator.pushNamed(
                              context,
                              AppRoutes.perfil,
                              arguments: dni,
                            ),
                          ),
                          _MenuButton(
                            titulo: 'MI UNIDAD',
                            icono: Icons.local_shipping_outlined,
                            color: AppColors.accentOrange,
                            onTap: () => Navigator.pushNamed(
                              context,
                              AppRoutes.equipo,
                              arguments: dni,
                            ),
                          ),
                          _MenuButton(
                            titulo: 'MIS VENCIMIENTOS',
                            icono: Icons.assignment_late_outlined,
                            color: AppColors.accentGreen,
                            onTap: () => Navigator.pushNamed(
                              context,
                              AppRoutes.misVencimientos,
                              arguments: dni,
                            ),
                          ),
                          if (_isAdmin)
                            _MenuButton(
                              titulo: 'ADMINISTRACIÓN',
                              icono: Icons.admin_panel_settings_sharp,
                              color: AppColors.accentRed,
                              onTap: () => Navigator.pushNamed(
                                context,
                                AppRoutes.adminPanel,
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Text(
                      'Legajo: $dni · Rol: $rol',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _logout(BuildContext context) async {
    final navigator = Navigator.of(context);

    // Limpiamos el estado en memoria ANTES de hacer logout, para que el
    // siguiente usuario que loguee no vea datos cacheados del anterior.
    // - Repositorio: cierra los listeners de Firestore (deja de gastar lecturas)
    // - Provider: limpia estados de loading/success/error y last sync
    try {
      context.read<VehiculoRepository>().clearStreamCache();
      context.read<VehiculoProvider>().clearAll();
    } catch (e) {
      // Si por algún motivo Provider no está disponible, seguimos igual
      debugPrint('Aviso: no se pudo limpiar estado al logout: $e');
    }

    await _authService.logout();
    if (!context.mounted) return;
    // El Future de pushNamedAndRemoveUntil se completa cuando la nueva
    // ruta haga pop (nunca, en este caso). Lo descartamos explícito.
    unawaited(navigator.pushNamedAndRemoveUntil('/', (route) => false));
  }
}

// =============================================================================
// HEADER DE BIENVENIDA
// =============================================================================

class _WelcomeHeader extends StatelessWidget {
  final String dni;
  final String nombre;
  const _WelcomeHeader({required this.dni, required this.nombre});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(25),
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.account_circle,
                color: AppColors.accentGreen,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'BIENVENIDO',
                style: TextStyle(
                  color: Colors.white.withAlpha(150),
                  letterSpacing: 2,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Saludo con prioridad APODO si está cargado, fallback al
          // primer nombre del NOMBRE (segundo token, formato
          // APELLIDO NOMBRE SEGUNDO_NOMBRE). Mismo patrón que el
          // _Saludo del admin_panel_screen.
          _NombreSaludo(dni: dni, nombreFull: nombre),
        ],
      ),
    );
  }
}

/// Resuelve el nombre a saludar leyendo `EMPLEADOS/{dni}.APODO` una sola
/// vez y, si no está cargado, cae al primer nombre del campo NOMBRE.
/// Renderiza solo el `Text` grande con el resultado.
class _NombreSaludo extends StatefulWidget {
  final String dni;
  final String nombreFull;

  const _NombreSaludo({required this.dni, required this.nombreFull});

  @override
  State<_NombreSaludo> createState() => _NombreSaludoState();
}

class _NombreSaludoState extends State<_NombreSaludo> {
  /// Inicializado SÍNCRONO desde `PrefsService.apodo` (cacheado al login)
  /// para evitar el flicker "Bienvenido Santiago" → "Bienvenido Santi"
  /// que pasaba cuando esto era un Future a Firestore. Si la cache está
  /// vacía (usuarios legacy logueados pre-fix 2026-05-07), el lookup
  /// async se ejecuta una vez y cachea el resultado para próximas
  /// sesiones.
  late String _apodoResuelto = PrefsService.apodo.trim();

  @override
  void initState() {
    super.initState();
    if (_apodoResuelto.isEmpty) {
      _resolverApodoLegacy();
    }
  }

  /// Solo se invoca para usuarios que iniciaron sesión antes de que
  /// PrefsService cacheara el APODO. Una vez resuelto, queda guardado
  /// y la próxima sesión arranca síncrona.
  Future<void> _resolverApodoLegacy() async {
    final dni = widget.dni.trim();
    if (dni.isEmpty) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .get();
      if (!mounted) return;
      final apodo = (snap.data()?['APODO'] ?? '').toString().trim();
      if (apodo.isEmpty) return; // sin apodo cargado, dejamos el fallback
      setState(() => _apodoResuelto = apodo);
      // Cacheamos para próximas sesiones (sin await — no bloquea UI).
      unawaited(PrefsService.setApodo(apodo));
    } catch (_) {
      // Si Firestore falla, dejamos el fallback del primer nombre.
    }
  }

  /// Para nombres "APELLIDO NOMBRE …", devuelve "Nombre" capitalizado.
  /// Si el campo NOMBRE viene con una sola palabra, devuelve esa palabra.
  String _primerNombre(String full) {
    final partes = full.trim().split(RegExp(r'\s+'));
    if (partes.isEmpty) return '';
    final n = partes.length >= 2 ? partes[1] : partes.first;
    if (n.isEmpty) return '';
    return '${n[0].toUpperCase()}${n.substring(1).toLowerCase()}';
  }

  @override
  Widget build(BuildContext context) {
    final nombre = _apodoResuelto.isNotEmpty
        ? _apodoResuelto
        : _primerNombre(widget.nombreFull);
    return Text(
      nombre,
      style: const TextStyle(
        fontSize: 32,
        fontWeight: FontWeight.bold,
        color: Colors.white,
      ),
    );
  }
}

// =============================================================================
// BOTÓN DEL MENÚ (cuadradito grande)
// =============================================================================

class _MenuButton extends StatelessWidget {
  final String titulo;
  final IconData icono;
  final Color color;
  final VoidCallback onTap;

  const _MenuButton({
    required this.titulo,
    required this.icono,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white.withAlpha(15)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(22),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withAlpha(25),
                  shape: BoxShape.circle,
                ),
                child: Icon(icono, color: color, size: 30),
              ),
              const SizedBox(height: 12),
              Text(
                titulo,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
