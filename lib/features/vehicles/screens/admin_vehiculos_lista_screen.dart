import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../core/services/capabilities.dart';
import '../../../core/theme/app_breakpoints.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../providers/vehiculo_provider.dart';
import '../services/vehiculo_actions.dart';
import '../services/volvo_api_service.dart';

import 'admin_vehiculo_alta_screen.dart';
import 'admin_vehiculo_form_screen.dart';
import 'diagnostico_volvo_screen.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
// 13 widgets visuales (cards, sheet de detalle, telemetría, badges,
// rows) extraídos para mantener navegable el screen principal.
// Comparten privacidad y los imports via `part of`.
part 'admin_vehiculos_lista_widgets.dart';

/// Pantalla de Gestión de Flota.
///
/// Migrada al sistema de diseño unificado (AppScaffold + AppListPage +
/// AppCard + AppDetailSheet + VencimientoBadge + AppFileThumbnail).
class AdminVehiculosListaScreen extends StatefulWidget {
  const AdminVehiculosListaScreen({super.key});

  @override
  State<AdminVehiculosListaScreen> createState() =>
      _AdminVehiculosListaScreenState();
}

class _AdminVehiculosListaScreenState
    extends State<AdminVehiculosListaScreen> {
  /// Por default ocultos los tanques de combustibles líquidos y los
  /// tractores asignados a sus choferes. Toggle del AppBar (escudo) los
  /// muestra para auditoría/mantenimiento.
  bool _mostrarExcluidos = false;

  /// Set de patentes excluidas (cacheado). Null mientras carga.
  ExcluidosSet? _excluidos;

  /// Card-filtro en foco (Santiago 2026-06-10: las cards SON el filtro,
  /// reemplazaron a los chips por tipo). Default TRACTOR. Valores: 'LIBRES',
  /// los tipos (TRACTOR/BATEA/…), 'INACTIVOS'.
  String _cardSeleccionada = AppTiposVehiculo.tractor;

  /// Stream de TODA la flota. Las cards LIBRES/INACTIVOS cruzan tipos, así
  /// que filtramos client-side (como Gestión de Personal). Se crea UNA vez
  /// para no re-suscribir al cambiar de card.
  late final Stream<QuerySnapshot> _streamTodos;

  @override
  void initState() {
    super.initState();
    _streamTodos = FirebaseFirestore.instance
        .collection(AppCollections.vehiculos)
        .snapshots();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<VehiculoProvider>().init();
    });
    ExcluidosService.cargar().then((s) {
      if (mounted) setState(() => _excluidos = s);
    });
  }

  /// Tipos de unidad: tractor primero + enganches (sin ACOPLADO, que solo
  /// existe por retrocompat de docs viejos).
  static List<String> get _tipos => [
        AppTiposVehiculo.tractor,
        ...AppTiposVehiculo.enganches.where((t) => t != 'ACOPLADO'),
      ];

  /// IDs de las cards-filtro, en orden: LIBRES · tipos · INACTIVOS.
  static List<String> get _cards =>
      [_kCardLibres, ..._tipos, _kCardInactivos];

  /// ¿La unidad entra a la lista? Pasa el escudo de excluidos y coincide con
  /// la card seleccionada.
  bool _visible(Map<String, dynamic> data, String patente) {
    if (!_mostrarExcluidos &&
        ExcluidosService.esExcluido(_excluidos, patente: patente)) {
      return false;
    }
    return _coincideCard(_cardSeleccionada, data);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gestión de Flota',
      actions: [
        // Toggle "mostrar excluidos" (tanques combustibles + tractores de
        // tanqueros). Por default OFF para que la flota operativa no se
        // mezcle con las unidades que no controlamos. (El toggle de inactivos
        // se quitó: ahora vive en la card INACTIVOS — Santiago 2026-06-10.)
        if ((_excluidos?.patentes.isNotEmpty ?? false))
          IconButton(
            tooltip: _mostrarExcluidos
                ? 'Ocultar tanques de combustibles'
                : 'Mostrar tanques de combustibles',
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
      // Solo quien puede crear vehículos ve el FAB "Nuevo" (ADMIN/SUPERVISOR).
      floatingActionButton:
          Capabilities.can(PrefsService.rol, Capability.crearVehiculo)
              ? FloatingActionButton.extended(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AdminVehiculoAltaScreen(),
                    ),
                  ),
                  tooltip: 'Agregar nueva unidad',
                  icon: const Icon(Icons.add),
                  label: const Text('Nuevo'),
                )
              : null,
      body: Column(
        children: [
          // Cards-filtro (LIBRES · tipos · INACTIVOS) que SON el filtro. El
          // conteo de cada card + la lista salen del MISMO stream de toda la
          // flota (cero lecturas extra) y respetan el escudo de excluidos.
          _HeroFlota(
            stream: _streamTodos,
            cards: _cards,
            seleccionada: _cardSeleccionada,
            onCard: (id) => setState(() => _cardSeleccionada = id),
            mostrarExcluidos: _mostrarExcluidos,
            excluidos: _excluidos,
          ),
          Expanded(
            child: _ListaFlota(
              stream: _streamTodos,
              cardId: _cardSeleccionada,
              visible: _visible,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// CARDS-FILTRO DE FLOTA (LIBRES · tipos · INACTIVOS)
// =============================================================================

const String _kCardLibres = 'LIBRES';
const String _kCardInactivos = 'INACTIVOS';

/// ¿El doc coincide con la card [id]? Facetas NO exclusivas: LIBRES = activa +
/// ESTADO LIBRE (cualquier tipo); INACTIVOS = baja; un tipo = activa + ese
/// TIPO. (Un tractor libre coincide con LIBRES y con TRACTOR.)
bool _coincideCard(String id, Map<String, dynamic> data) {
  final activa = AppActivo.esActivo(data);
  if (id == _kCardInactivos) return !activa;
  if (!activa) return false; // las demás cards solo muestran activas
  if (id == _kCardLibres) {
    return (data['ESTADO'] ?? 'LIBRE').toString().toUpperCase() == 'LIBRE';
  }
  return (data['TIPO'] ?? '').toString().toUpperCase() == id;
}

/// Label de una card-filtro.
String _cardLabel(String id) {
  if (id == _kCardLibres) return 'Libres';
  if (id == _kCardInactivos) return 'Inactivos';
  return AppTiposVehiculo.pluralEtiquetas[id] ?? id;
}

/// Encabezado de Gestión de Flota: eyebrow + strip de CARDS-FILTRO (Santiago
/// 2026-06-10). Las cards (LIBRES · tipos · INACTIVOS) SON el filtro, en vez
/// del viejo KpiStrip no-interactivo + chips por tipo. El conteo de cada card
/// sale del MISMO stream de toda la flota que consume la lista, respetando el
/// escudo de excluidos.
class _HeroFlota extends StatelessWidget {
  final Stream<QuerySnapshot> stream;
  final List<String> cards;
  final String seleccionada;
  final ValueChanged<String> onCard;
  final bool mostrarExcluidos;
  final ExcluidosSet? excluidos;

  const _HeroFlota({
    required this.stream,
    required this.cards,
    required this.seleccionada,
    required this.onCard,
    required this.mostrarExcluidos,
    required this.excluidos,
  });

  @override
  Widget build(BuildContext context) {
    final esDesktop = AppBreakpoints.isDesktopOrLarger(context);
    return StreamBuilder<QuerySnapshot>(
      stream: stream,
      builder: (ctx, snap) {
        final docs = snap.data?.docs ?? const [];
        // Conteo por card sobre toda la flota (respetando el escudo). Las
        // facetas se solapan: un tractor libre cuenta en LIBRES y TRACTORES.
        final counts = <String, int>{};
        for (final d in docs) {
          if (!mostrarExcluidos &&
              ExcluidosService.esExcluido(excluidos, patente: d.id)) {
            continue;
          }
          final data = d.data() as Map<String, dynamic>;
          for (final id in cards) {
            if (_coincideCard(id, data)) {
              counts[id] = (counts[id] ?? 0) + 1;
            }
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppEyebrow('Flota'),
              const SizedBox(height: AppSpacing.md),
              _StripCardsFlota(
                esDesktop: esDesktop,
                cards: cards,
                seleccionada: seleccionada,
                counts: counts,
                onCard: onCard,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Strip de cards-filtro de Flota (estética AppKpiStrip pero tappeable).
/// Desktop: las cards reparten el ancho (Expanded); mobile: scroll horizontal
/// (7 cards no entran cómodas).
class _StripCardsFlota extends StatelessWidget {
  final bool esDesktop;
  final List<String> cards;
  final String seleccionada;
  final Map<String, int> counts;
  final ValueChanged<String> onCard;
  const _StripCardsFlota({
    required this.esDesktop,
    required this.cards,
    required this.seleccionada,
    required this.counts,
    required this.onCard,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final celdas = [
      for (final id in cards)
        _CeldaCardFlota(
          label: _cardLabel(id),
          valor: counts[id] ?? 0,
          seleccionado: seleccionada == id,
          esDesktop: esDesktop,
          onTap: () => onCard(id),
        ),
    ];
    final fila = IntrinsicHeight(
      child: Row(
        children: [
          for (var i = 0; i < celdas.length; i++) ...[
            if (esDesktop) Expanded(child: celdas[i]) else celdas[i],
            if (i < celdas.length - 1) Container(width: 1, color: c.border),
          ],
        ],
      ),
    );
    return Container(
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: esDesktop
            ? fila
            : SingleChildScrollView(
                scrollDirection: Axis.horizontal, child: fila),
      ),
    );
  }
}

/// Una celda del strip de Flota. Tappeable; resalta con tinte brand cuando es
/// la card en foco. En mobile fija un mínimo para que sea tappeable.
class _CeldaCardFlota extends StatelessWidget {
  final String label;
  final int valor;
  final bool seleccionado;
  final bool esDesktop;
  final VoidCallback onTap;
  const _CeldaCardFlota({
    required this.label,
    required this.valor,
    required this.seleccionado,
    required this.esDesktop,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final contenido = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: esDesktop ? 18 : 14,
        vertical: esDesktop ? 18 : 14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(
              color: seleccionado ? c.brand : c.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '$valor',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.h2.copyWith(
              color: c.text,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
    final celda = ConstrainedBox(
      constraints: BoxConstraints(minWidth: esDesktop ? 0 : 112),
      child: ColoredBox(
        color: seleccionado
            ? c.brand.withValues(alpha: 0.12)
            : Colors.transparent,
        child: contenido,
      ),
    );
    return InkWell(onTap: onTap, child: celda);
  }
}

