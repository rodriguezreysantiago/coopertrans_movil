import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
// `flutter/services` exporta los TextInputFormatter usados por
// `_DatoEditableTexto` (DigitOnlyFormatter hereda de ahí).
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/foto_perfil_avatar.dart';

import '../services/empleado_actions.dart';
import 'admin_personal_form_screen.dart';
import 'chofer_actividad_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
// 10 widgets visuales (card, detalle, header, datos editables, filas
// de vencimiento, asignacion de unidad) extraidos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
part 'admin_personal_lista_widgets.dart';

/// Pantalla de Gestión de Personal.
///
/// Migrada al sistema de diseño unificado:
/// AppScaffold + AppListPage + AppCard + AppDetailSheet +
/// VencimientoBadge + AppFileThumbnail.
class AdminPersonalListaScreen extends StatefulWidget {
  const AdminPersonalListaScreen({super.key});

  @override
  State<AdminPersonalListaScreen> createState() =>
      _AdminPersonalListaScreenState();
}

class _AdminPersonalListaScreenState
    extends State<AdminPersonalListaScreen> {
  // Stream cacheado para evitar lecturas duplicadas al buscar/refrescar.
  late final Stream<QuerySnapshot> _empleadosStream;

  /// Por default solo activos. Toggle del AppBar lo invierte.
  bool _mostrarInactivos = false;

  /// Por default los 3 tanqueros + 2 testers están ocultos. Toggle del
  /// AppBar permite verlos para auditoría/mantenimiento de esos perfiles.
  bool _mostrarExcluidos = false;

  /// Set de DNIs excluidos (cacheado por `ExcluidosService`). Null hasta
  /// que termine la carga inicial — si quedó null cuando el filter corre,
  /// `esExcluido` devuelve `false` (fail-safe).
  ExcluidosSet? _excluidos;

  @override
  void initState() {
    super.initState();
    _empleadosStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .orderBy('NOMBRE')
        .snapshots();
    // Cargar set de excluidos en background. Al terminar, setState para
    // que el StreamBuilder re-renderice aplicando el filtro.
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gestión de Personal',
      actions: [
        // Toggle de "mostrar excluidos" (tanqueros + testers). Útil
        // cuando el admin necesita editar perfiles de testers (Apple
        // Reviewer, Android) o de los choferes de combustibles
        // líquidos. Por default OFF para que los empleados reales no
        // se mezclen visualmente con esas cuentas operativas.
        if ((_excluidos?.dnis.isNotEmpty ?? false))
          IconButton(
            tooltip: _mostrarExcluidos
                ? 'Ocultar tanqueros y testers'
                : 'Mostrar tanqueros y testers',
            icon: Icon(
              _mostrarExcluidos
                  ? Icons.shield_moon_outlined
                  : Icons.shield_outlined,
              color: _mostrarExcluidos
                  ? AppColors.warning
                  : AppColors.textSecondary,
            ),
            onPressed: () =>
                setState(() => _mostrarExcluidos = !_mostrarExcluidos),
          ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => const AdminPersonalFormScreen(),
          ),
        ),
        // El tooltip ayuda en desktop (hover) y a screen readers — el
        // label "Nuevo" del FAB es ambiguo sin contexto fuera del título.
        tooltip: 'Agregar nuevo chofer',
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Nuevo'),
      ),
      body: Column(
        children: [
          // Chip "Mostrar inactivos" arriba del listado, más visible
          // que el IconButton del AppBar anterior (Santiago 2026-05-19:
          // "no tengo forma de ver los que fueron dados de baja").
          // Antes vivía como icono pequeño en el AppBar, ahora es un
          // FilterChip explícito con etiqueta y color.
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Mostrar inactivos'),
                  selected: _mostrarInactivos,
                  onSelected: (v) =>
                      setState(() => _mostrarInactivos = v),
                  selectedColor:
                      AppColors.warning.withValues(alpha: 0.6),
                  avatar: Icon(
                    _mostrarInactivos
                        ? Icons.visibility
                        : Icons.visibility_off,
                    size: 16,
                    color: _mostrarInactivos
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: AppListPage(
              stream: _empleadosStream,
              searchHint: 'Buscar por nombre, tractor o enganche...',
              emptyTitle: 'Sin choferes cargados',
              emptySubtitle: 'Tocá el botón + para agregar uno',
              emptyIcon: Icons.badge_outlined,
              filter: (doc, q) {
                final data = doc.data() as Map<String, dynamic>;
                // Filtro de soft-delete: por default ocultamos
                // inactivos. El chip "Mostrar inactivos" permite verlos
                // cuando hace falta gestionar reactivaciones.
                if (!_mostrarInactivos && !AppActivo.esActivo(data)) {
                  return false;
                }
                // Filtro de excluidos (tanqueros + testers). Por
                // default ocultamos para que los empleados reales no
                // se mezclen.
                if (!_mostrarExcluidos &&
                    ExcluidosService.esExcluido(_excluidos, dni: doc.id)) {
                  return false;
                }
                final hay = '${data['NOMBRE'] ?? ''} '
                        '${data['VEHICULO'] ?? ''} ${data['ENGANCHE'] ?? ''} '
                        '${doc.id}'
                    .toUpperCase();
                return hay.contains(q);
              },
              itemBuilder: (ctx, doc) => _EmpleadoCard(doc: doc),
            ),
          ),
        ],
      ),
    );
  }
}

