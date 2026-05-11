import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
// `flutter/services` exporta los TextInputFormatter usados por
// `_DatoEditableTexto` (DigitOnlyFormatter hereda de ahí).
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/capabilities.dart';
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

  @override
  void initState() {
    super.initState();
    _empleadosStream = FirebaseFirestore.instance
        .collection(AppCollections.empleados)
        .orderBy('NOMBRE')
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gestión de Personal',
      actions: [
        IconButton(
          tooltip: _mostrarInactivos
              ? 'Ocultar empleados inactivos'
              : 'Mostrar empleados inactivos',
          icon: Icon(
            _mostrarInactivos
                ? Icons.visibility_off_outlined
                : Icons.archive_outlined,
            color: _mostrarInactivos
                ? AppColors.accentOrange
                : Colors.white70,
          ),
          onPressed: () =>
              setState(() => _mostrarInactivos = !_mostrarInactivos),
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
        // label "NUEVO" del FAB es ambiguo sin contexto fuera del título.
        tooltip: 'Agregar nuevo chofer',
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('NUEVO'),
      ),
      body: AppListPage(
        stream: _empleadosStream,
        searchHint: 'Buscar por nombre, tractor o enganche...',
        emptyTitle: 'Sin choferes cargados',
        emptySubtitle: 'Tocá el botón + para agregar uno',
        emptyIcon: Icons.badge_outlined,
        filter: (doc, q) {
          final data = doc.data() as Map<String, dynamic>;
          // Filtro de soft-delete: por default ocultamos inactivos.
          // El toggle del AppBar permite verlos cuando hace falta
          // gestionar reactivaciones.
          if (!_mostrarInactivos && !AppActivo.esActivo(data)) {
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
    );
  }
}

