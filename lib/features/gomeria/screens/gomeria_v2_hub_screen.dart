import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import 'gomeria_v2_stock_screen.dart';
import 'gomeria_v2_unidad_screen.dart';

/// Hub del modelo NUEVO de gomería — REFACTOR NÚCLEO (jun 2026).
///
/// La entrada es por BÚSQUEDA (no una lista larga de 127 unidades, que en
/// tablet era incómoda): el gomero busca por chofer (le trae su tractor +
/// enganche), o directo un tractor o un enganche por patente. Arriba quedan
/// los accesos a Stock y (solo admin) al catálogo.
///
/// SOLO PRESENTACIÓN: la carga de datos (`_cargar`, split tractor/enganche por
/// regex de TIPO, choferes con unidad asignada), el ordenamiento, los filtros
/// de búsqueda y la navegación (`_abrirUnidad`) quedan intactos — sólo se
/// reescribió el árbol de widgets a tokens (`context.colors`), header eyebrow +
/// hero number + `AppKpiStrip`, accesos como `AppCard`, buscador `AppInput`,
/// tabs re-skineadas y filas densas `AppCard(tier:1)`.
class GomeriaV2HubScreen extends StatefulWidget {
  const GomeriaV2HubScreen({super.key});

  @override
  State<GomeriaV2HubScreen> createState() => _GomeriaV2HubScreenState();
}

class _GomeriaV2HubScreenState extends State<GomeriaV2HubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _qChofer = TextEditingController();
  final _qTractor = TextEditingController();
  final _qEnganche = TextEditingController();

  bool _cargando = true;
  String? _error;
  final List<_Unidad> _tractores = [];
  final List<_Unidad> _enganches = [];
  final List<_Chofer> _choferes = [];

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    for (final c in [_qChofer, _qTractor, _qEnganche]) {
      c.addListener(() => setState(() {}));
    }
    _cargar();
  }

  @override
  void dispose() {
    _tab.dispose();
    _qChofer.dispose();
    _qTractor.dispose();
    _qEnganche.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final fs = FirebaseFirestore.instance;
      final vSnap = await fs.collection(AppCollections.vehiculos).get();
      for (final d in vSnap.docs) {
        final data = d.data();
        final u = _Unidad(
          patente: d.id,
          marca: (data['MARCA'] ?? '').toString(),
        );
        // Clasificación canónica por AppTiposVehiculo.enganches (incluye
        // BIVUELCO/ACOPLADO). Antes un regex que NO capturaba BIVUELCO lo
        // metía en _tractores y le ofrecía posiciones de tractor.
        (AppTiposVehiculo.enganches
                    .contains((data['TIPO'] ?? '').toString().toUpperCase().trim())
                ? _enganches
                : _tractores)
            .add(u);
      }
      _tractores.sort((a, b) => a.patente.compareTo(b.patente));
      _enganches.sort((a, b) => a.patente.compareTo(b.patente));

      final eSnap = await fs.collection(AppCollections.empleados).get();
      for (final d in eSnap.docs) {
        final data = d.data();
        if (data['ACTIVO'] == false) continue;
        final tractor = (data['VEHICULO'] ?? '').toString().trim();
        final enganche = (data['ENGANCHE'] ?? '').toString().trim();
        final tieneT = tractor.isNotEmpty && tractor != '-';
        final tieneE = enganche.isNotEmpty && enganche != '-';
        if (!tieneT && !tieneE) continue; // solo los que tienen unidad
        _choferes.add(_Chofer(
          nombre: (data['NOMBRE'] ?? d.id).toString(),
          tractor: tieneT ? tractor : null,
          enganche: tieneE ? enganche : null,
        ));
      }
      _choferes.sort((a, b) => a.nombre.compareTo(b.nombre));
      if (mounted) setState(() => _cargando = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _cargando = false;
        });
      }
    }
  }

  void _abrirUnidad(String patente, TipoUnidadCubierta tipo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GomeriaV2UnidadScreen(unidadId: patente, unidadTipo: tipo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppScaffold(
      title: 'Gomería (nueva)',
      body: _cargando
          ? const AppSkeletonList(count: 6)
          : _error != null
              ? AppErrorState(
                  title: 'No se pudieron cargar las unidades',
                  subtitle: _error!,
                  onRetry: () {
                    setState(() {
                      _cargando = true;
                      _error = null;
                      _tractores.clear();
                      _enganches.clear();
                      _choferes.clear();
                    });
                    _cargar();
                  },
                )
              : Column(
                  children: [
                    _encabezado(),
                    _Tabs(controller: _tab),
                    Expanded(
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          _tabChofer(),
                          _tabUnidades(_tractores, _qTractor,
                              TipoUnidadCubierta.tractor, 'tractor'),
                          _tabUnidades(_enganches, _qEnganche,
                              TipoUnidadCubierta.enganche, 'enganche'),
                        ],
                      ),
                    ),
                  ],
                ),
      floatingActionButton: _cargando || _error != null
          ? null
          : FloatingActionButton.extended(
              backgroundColor: c.brand,
              foregroundColor: c.brandFg,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GomeriaV2StockScreen()),
              ),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Stock'),
            ),
    );
  }

  // ───────────────────────── encabezado: eyebrow + hero + KPIs + accesos ──
  Widget _encabezado() {
    final esAdmin = PrefsService.rol == AppRoles.admin;
    final total = _tractores.length + _enganches.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Gomería'),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$total',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('unidades', style: AppType.monoSm),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppKpiStrip(
            stats: [
              AppStat(label: 'Tractores', value: '${_tractores.length}'),
              AppStat(label: 'Enganches', value: '${_enganches.length}'),
              AppStat(label: 'Choferes', value: '${_choferes.length}'),
            ],
          ),
          if (esAdmin) ...[
            const SizedBox(height: AppSpacing.md),
            _AccesoCatalogo(
              onTap: () => Navigator.pushNamed(
                  context, AppRoutes.adminGomeriaMarcasModelos),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buscador(TextEditingController ctrl, String hint) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: AppInput(
        controller: ctrl,
        hint: hint,
        icon: Icons.search,
        mono: true,
        trailingAction: ctrl.text.isEmpty ? null : 'Limpiar',
        onTrailingTap: ctrl.clear,
      ),
    );
  }

  // ───────────────────────── tab: por chofer ─────────────────────────────
  Widget _tabChofer() {
    final q = _qChofer.text.trim().toUpperCase();
    final lista = q.isEmpty
        ? _choferes
        : _choferes
            .where((c) => c.nombre.toUpperCase().contains(q))
            .toList();
    return Column(
      children: [
        _buscador(_qChofer, 'Buscar chofer por nombre'),
        Expanded(
          child: lista.isEmpty
              ? const AppEmptyState(
                  icon: Icons.person_search_outlined,
                  title: 'Sin resultados',
                  subtitle: 'Probá con otro nombre.',
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, 0, AppSpacing.lg, 96),
                  itemCount: lista.length,
                  itemBuilder: (_, i) => _CardChofer(
                    chofer: lista[i],
                    onAbrir: _abrirUnidad,
                  ),
                ),
        ),
      ],
    );
  }

  // ───────────────────────── tabs: tractores / enganches ─────────────────
  Widget _tabUnidades(List<_Unidad> todas, TextEditingController ctrl,
      TipoUnidadCubierta tipo, String nombreTipo) {
    final q = ctrl.text.trim().toUpperCase();
    final lista = q.isEmpty
        ? todas
        : todas
            .where((u) =>
                u.patente.toUpperCase().contains(q) ||
                u.marca.toUpperCase().contains(q))
            .toList();
    return Column(
      children: [
        _buscador(ctrl, 'Buscar $nombreTipo por patente'),
        Expanded(
          child: lista.isEmpty
              ? const AppEmptyState(
                  icon: Icons.search_off_outlined,
                  title: 'Sin resultados',
                  subtitle: 'Probá con otra patente o marca.',
                )
              : LayoutBuilder(
                  builder: (_, cns) {
                    final cols = cns.maxWidth >= 1200
                        ? 4
                        : cns.maxWidth >= 900
                            ? 3
                            : cns.maxWidth >= 600
                                ? 2
                                : 1;
                    if (cols == 1) {
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(
                            AppSpacing.lg, 0, AppSpacing.lg, 96),
                        itemCount: lista.length,
                        itemBuilder: (_, i) =>
                            _TileUnidad(unidad: lista[i], tipo: tipo, onAbrir: _abrirUnidad),
                      );
                    }
                    const sp = AppSpacing.md;
                    final w = (cns.maxWidth - AppSpacing.lg * 2 - sp * (cols - 1)) /
                        cols;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, 0, AppSpacing.lg, 96),
                      child: Wrap(
                        spacing: sp,
                        runSpacing: sp,
                        children: [
                          for (final u in lista)
                            SizedBox(
                              width: w,
                              child: _TileUnidad(
                                  unidad: u, tipo: tipo, onAbrir: _abrirUnidad),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

// =============================================================================
// TABS Núcleo — fila de pills bajo el header (en lugar del Material TabBar
// con indicador inferior). El TabController sigue manejando el estado.
// =============================================================================

class _Tabs extends StatelessWidget {
  final TabController controller;
  const _Tabs({required this.controller});

  static const _labels = ['Por chofer', 'Tractores', 'Enganches'];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xs),
          child: Row(
            children: [
              for (var i = 0; i < _labels.length; i++) ...[
                if (i > 0) const SizedBox(width: 6),
                AppFilterChip(
                  label: _labels[i],
                  count: 0,
                  activo: controller.index == i,
                  onTap: () => controller.animateTo(i),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

// =============================================================================
// ACCESO al catálogo (solo admin) — AppCard tappeable estilo bento.
// =============================================================================

class _AccesoCatalogo extends StatelessWidget {
  final VoidCallback onTap;
  const _AccesoCatalogo({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.category_outlined, size: 18, color: c.brand),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Marcas y modelos',
                  style: AppType.body.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Catálogo de cubiertas',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

// =============================================================================
// FILA chofer — AppCard(tier:1) con su tractor + enganche tappeables.
// =============================================================================

class _CardChofer extends StatelessWidget {
  final _Chofer chofer;
  final void Function(String, TipoUnidadCubierta) onAbrir;
  const _CardChofer({required this.chofer, required this.onAbrir});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 1,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            chofer.nombre,
            style: AppType.body.copyWith(fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: AppSpacing.sm),
          _FilaUnidadChofer(
            etiqueta: 'Tractor',
            icono: Icons.local_shipping_outlined,
            patente: chofer.tractor,
            onTap: chofer.tractor == null
                ? null
                : () => onAbrir(chofer.tractor!, TipoUnidadCubierta.tractor),
          ),
          const SizedBox(height: 6),
          _FilaUnidadChofer(
            etiqueta: 'Enganche',
            icono: Icons.rv_hookup_outlined,
            patente: chofer.enganche,
            onTap: chofer.enganche == null
                ? null
                : () => onAbrir(chofer.enganche!, TipoUnidadCubierta.enganche),
          ),
        ],
      ),
    );
  }
}

/// Una fila tractor/enganche dentro de la card de un chofer. Con patente es
/// tappeable; sin asignar, muestra "—".
class _FilaUnidadChofer extends StatelessWidget {
  final String etiqueta;
  final IconData icono;
  final String? patente;
  final VoidCallback? onTap;
  const _FilaUnidadChofer({
    required this.etiqueta,
    required this.icono,
    required this.patente,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final asignado = patente != null;
    final fila = Row(
      children: [
        Icon(icono, size: 16, color: asignado ? c.textSecondary : c.textMuted),
        const SizedBox(width: AppSpacing.sm),
        Text(
          etiqueta,
          style: AppType.bodySm.copyWith(color: c.textSecondary),
        ),
        const Spacer(),
        Text(
          asignado ? patente! : '—',
          style: AppType.mono.copyWith(
            color: asignado ? c.text : c.textMuted,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (asignado) ...[
          const SizedBox(width: AppSpacing.xs),
          Icon(Icons.chevron_right, size: 16, color: c.textMuted),
        ],
      ],
    );
    if (!asignado) return fila;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: fila,
      ),
    );
  }
}

// =============================================================================
// TILE de unidad (tractor / enganche) — AppCard(tier:1) tappeable.
// =============================================================================

class _TileUnidad extends StatelessWidget {
  final _Unidad unidad;
  final TipoUnidadCubierta tipo;
  final void Function(String, TipoUnidadCubierta) onAbrir;
  const _TileUnidad(
      {required this.unidad, required this.tipo, required this.onAbrir});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => onAbrir(unidad.patente, tipo),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(
            tipo == TipoUnidadCubierta.tractor
                ? Icons.local_shipping_outlined
                : Icons.rv_hookup_outlined,
            size: 18,
            color: c.textSecondary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  unidad.patente,
                  style: AppType.mono.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  unidad.marca.isEmpty ? '—' : unidad.marca,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: c.textMuted),
        ],
      ),
    );
  }
}

class _Unidad {
  final String patente;
  final String marca;
  _Unidad({required this.patente, required this.marca});
}

class _Chofer {
  final String nombre;
  final String? tractor;
  final String? enganche;
  _Chofer({required this.nombre, this.tractor, this.enganche});
}
