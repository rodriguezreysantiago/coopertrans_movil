// lib/features/auditoria_asignaciones/screens/admin_auditoria_asignaciones_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — auditoría de asignaciones en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los streams/reads (`ASIGNACIONES_VEHICULO` / `ASIGNACIONES_ENGANCHE` vía
//     `AsignacionVehiculoService` / `AsignacionEngancheService`; VEHICULOS /
//     EMPLEADOS para los selectores con buscador),
//   - los modelos `AsignacionVehiculo` / `AsignacionEnganche` /
//     `EngancheLlevado`,
//   - la lógica `_enRango`, `_duracion`, `diasDuracion`,
//     `enganchesLlevadosPorChofer`,
//   - el State (`_tab` ahora ES el TabController; `_patente`/`_esEnganche`/
//     `_rango`/`_choferDni`) + keep-alive de cada vista,
//   - la navegación (read-only) y los pickers con buscador.
//
// Layout Núcleo:
//   - Las 2 vistas (Por unidad / Por chofer) viven en pills `AppFilterChip`
//     en lugar del TabBar Material, pero se mantiene el `TabController` y el
//     keep-alive de cada subvista (los chips solo cambian `_tab.index`).
//   - Banners → caja surface con eyebrow + texto.
//   - Selector de rango → pill Núcleo (cristal + dot brand).
//   - Campos selector + sheets de picker → reskin a tokens + buscador estilo
//     Núcleo (TextField sobre surface2). Empty del picker = AppEmptyState.
//   - Resúmenes → AppKpiStrip / AppStat (hero numbers en c.text, NUNCA color
//     semántico en el número).
//   - Cards de período → AppCard(tier 1/2) con patente/fechas en mono, badge
//     "Actual" = AppBadge, filas label/valor = `_Linea` (value mono cuando es
//     fecha/dato técnico), Divider → AppHairline.
//   - Placeholders → AppEmptyState; loading → AppSkeletonList; error →
//     AppErrorState.
//
// Reglas duras: tokens (context.colors), números/fechas técnicas en mono,
// embedded (sin fondo full-screen propio), faltante → "—", sin overflow.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../asignaciones/models/asignacion_enganche.dart';
import '../../asignaciones/models/asignacion_vehiculo.dart';
import '../../asignaciones/services/asignacion_enganche_service.dart';
import '../../asignaciones/services/asignacion_vehiculo_service.dart';

/// Auditoría de asignaciones — 2 vistas en pills Núcleo.
///
/// 1. **Por unidad + fecha** (original 2026-05-27): "¿quién manejaba esta
///    unidad este día?". Para multas tardías / reconciliación puntual.
///
/// 2. **Por chofer** (agregado 2026-05-27 PM): "¿qué unidades manejó este
///    chofer desde que hay registro?". Para entender la rotación, ver
///    cuántas unidades pasó un chofer, base para liquidación / actividad.
///
/// Ambas leen de `ASIGNACIONES_VEHICULO` (la colección iButton de Sitrack
/// quedó muerta tras el refactor de la mañana — no aporta valor operativo).
///
/// REFACTOR PREVIO 2026-05-27 AM (decisión Santiago): la pantalla previa
/// cruzaba `SITRACK_IBUTTONS_HISTORICO` vs `ASIGNACIONES_VEHICULO` para
/// detectar discrepancias. Esa info no se usaba.
class AdminAuditoriaAsignacionesScreen extends StatefulWidget {
  const AdminAuditoriaAsignacionesScreen({super.key});

  @override
  State<AdminAuditoriaAsignacionesScreen> createState() =>
      _AdminAuditoriaAsignacionesScreenState();
}

class _AdminAuditoriaAsignacionesScreenState
    extends State<AdminAuditoriaAsignacionesScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    // Los pills setean `_tab.index` directamente; escuchamos para reflejar
    // el chip activo cuando cambia (incluido swipe del TabBarView).
    _tab.addListener(() {
      if (!_tab.indexIsChanging) setState(() {});
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Auditoría de asignaciones',
      body: Column(
        children: [
          // Pills Núcleo en lugar del TabBar Material — mismo TabController.
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
            child: Row(
              children: [
                _VistaPill(
                  label: 'Por unidad',
                  icon: Icons.local_shipping_outlined,
                  activo: _tab.index == 0,
                  onTap: () => _tab.animateTo(0),
                ),
                const SizedBox(width: AppSpacing.sm),
                _VistaPill(
                  label: 'Por chofer',
                  icon: Icons.person_search_outlined,
                  activo: _tab.index == 1,
                  onTap: () => _tab.animateTo(1),
                ),
              ],
            ),
          ),
          const AppHairline(),
          Expanded(
            child: TabBarView(
              controller: _tab,
              children: const [
                _TabPorUnidad(),
                _TabPorChofer(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pill de selección de vista (estilo Núcleo: activo = relleno `text` sobre
/// `bg`; inactivo = borde hairline). Replica el lenguaje del `_ChipEstado`
/// del mapa de flota, con ícono.
class _VistaPill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool activo;
  final VoidCallback onTap;
  const _VistaPill({
    required this.label,
    required this.icon,
    required this.activo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: activo ? c.text : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: activo ? null : Border.all(color: c.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon,
                  size: 16, color: activo ? c.bg : c.textSecondary),
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(
                    color: activo ? c.bg : c.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// TAB 1 — POR UNIDAD + FECHA
// ============================================================================

class _TabPorUnidad extends StatefulWidget {
  const _TabPorUnidad();

  @override
  State<_TabPorUnidad> createState() => _TabPorUnidadState();
}

class _TabPorUnidadState extends State<_TabPorUnidad>
    with AutomaticKeepAliveClientMixin {
  String _patente = '';
  bool _esEnganche = false;

  /// Rango de fechas para acotar el historial. `null` = todo el historial
  /// (desde el inicio), que es el default — el pedido principal del operador.
  DateTimeRange? _rango;

  @override
  bool get wantKeepAlive => true;

  Future<void> _elegirRango() async {
    final ahora = DateTime.now();
    final r = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024, 1, 1),
      lastDate: ahora,
      initialDateRange: _rango,
      locale: const Locale('es', 'AR'),
      helpText: 'Elegí el rango de fechas',
      saveText: 'Aplicar',
    );
    if (r == null) return;
    // Normalizamos: desde 00:00 del primer día hasta 23:59:59 del último,
    // para que el rango incluya completos ambos extremos.
    setState(() => _rango = DateTimeRange(
          start: DateTime(r.start.year, r.start.month, r.start.day),
          end: DateTime(r.end.year, r.end.month, r.end.day, 23, 59, 59),
        ));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        const _BannerInfo(
          texto: 'Elegí una unidad y te mostramos TODOS los choferes que la '
              'manejaron desde que hay registro (si es enganche, los tractores '
              'que lo llevaron). Filtrá por rango de fechas para acotar.',
        ),
        const SizedBox(height: AppSpacing.md),
        _DropdownPatente(
          value: _patente,
          onChanged: (v, esEng) => setState(() {
            _patente = v;
            _esEnganche = esEng;
          }),
        ),
        if (_patente.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          _SelectorRango(
            rango: _rango,
            onElegir: _elegirRango,
            onLimpiar:
                _rango == null ? null : () => setState(() => _rango = null),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        // Sin unidad elegida no mostramos un recuadro grande: el cartel de
        // ayuda + el campo ya dicen qué hacer (evita la triple repetición de
        // "elegí una unidad" — decisión Santiago 2026-06-02).
        if (_patente.isNotEmpty)
          _HistorialPorUnidad(
            patente: _patente,
            esEnganche: _esEnganche,
            rango: _rango,
          ),
      ],
    );
  }
}

// ============================================================================
// TAB 2 — POR CHOFER (historial completo de unidades)
// ============================================================================

class _TabPorChofer extends StatefulWidget {
  const _TabPorChofer();

  @override
  State<_TabPorChofer> createState() => _TabPorChoferState();
}

class _TabPorChoferState extends State<_TabPorChofer>
    with AutomaticKeepAliveClientMixin {
  String _choferDni = '';

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
      children: [
        const _BannerInfo(
          texto: 'Historial completo de unidades manejadas por el chofer '
              'elegido, desde que hay registro en el sistema. La asignación '
              'actual (la que sigue usando hoy) aparece arriba.',
        ),
        const SizedBox(height: AppSpacing.md),
        _DropdownChofer(
          value: _choferDni,
          onChanged: (v) => setState(() => _choferDni = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        // Sin chofer elegido, igual que en "Por unidad": cartel + campo
        // alcanzan, sin recuadro grande redundante.
        if (_choferDni.isNotEmpty)
          _HistorialPorChofer(choferDni: _choferDni),
      ],
    );
  }
}

// ============================================================================
// SELECTORES
// ============================================================================

/// Caja informativa Núcleo (surface2 + border + eyebrow + texto). Reemplaza
/// al banner azul Material que precedía cada vista.
class _BannerInfo extends StatelessWidget {
  final String texto;
  const _BannerInfo({required this.texto});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border(
          top: BorderSide(color: c.border),
          right: BorderSide(color: c.border),
          bottom: BorderSide(color: c.border),
          left: BorderSide(color: c.info, width: 3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: c.info, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              texto,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector de rango de fechas OPCIONAL. Por defecto "Todo el historial";
/// al tocar abre un date range picker. Con rango activo muestra una X para
/// limpiarlo (volver a todo). Pill Núcleo: cristal surface2 + dot brand +
/// fechas mono.
class _SelectorRango extends StatelessWidget {
  final DateTimeRange? rango;
  final VoidCallback onElegir;
  final VoidCallback? onLimpiar; // null = no hay rango que limpiar
  const _SelectorRango(
      {required this.rango, required this.onElegir, this.onLimpiar});

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hayRango = rango != null;
    final texto = hayRango
        ? '${_fmt(rango!.start)}  →  ${_fmt(rango!.end)}'
        : 'Todo el historial';
    return InkWell(
      onTap: onElegir,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            AppDot(c.brand, size: 7),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppEyebrow('Período'),
                  const SizedBox(height: 2),
                  Text(
                    texto,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono.copyWith(
                        color: hayRango ? c.text : c.textSecondary,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (onLimpiar != null)
              IconButton(
                icon: Icon(Icons.close, color: c.textMuted, size: 18),
                tooltip: 'Ver todo el historial',
                onPressed: onLimpiar,
                visualDensity: VisualDensity.compact,
              )
            else
              Icon(Icons.edit_outlined, color: c.textMuted, size: 16),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// SELECTORES CON BUSCADOR (patente / chofer)
// ============================================================================
// Reemplazaron a los DropdownButtonFormField planos el 2026-06-01: con ~50
// unidades y ~48 choferes el dropdown nativo era un scroll largo sin filtro.
// Ahora cada uno abre un modal sheet con buscador (mismo patrón que el
// selector de tarifas de Logística). El campo visible imita un dropdown.

/// Campo tappable que imita un dropdown pero abre un selector con buscador.
/// Reskin Núcleo: surface2 + border + label eyebrow + ícono search a la
/// derecha; el valor seleccionado va en mono (es un dato técnico: patente /
/// nombre).
class _CampoSelector extends StatelessWidget {
  final String label;
  final IconData icon;
  final String? textoSel; // null/vacío → muestra el hint
  final String hint;
  final VoidCallback onTap;
  const _CampoSelector({
    required this.label,
    required this.icon,
    required this.textoSel,
    required this.hint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tiene = (textoSel ?? '').isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: c.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppEyebrow(label),
                  const SizedBox(height: 2),
                  Text(
                    tiene ? textoSel! : hint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: (tiene ? AppType.mono : AppType.body).copyWith(
                      color: tiene ? c.text : c.textPlaceholder,
                      fontWeight: tiene ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(Icons.search, color: c.textMuted, size: 18),
          ],
        ),
      ),
    );
  }
}

/// Estructura común de los sheets de selección (handle + título + buscador
/// autofocus + lista). El filtrado lo hace cada sheet sobre su lista.
class _PickerSheetScaffold extends StatelessWidget {
  final String titulo;
  final String hintBuscar;
  final TextEditingController ctrl;
  final String filtro;
  final ValueChanged<String> onFiltro;
  final Widget lista;
  const _PickerSheetScaffold({
    required this.titulo,
    required this.hintBuscar,
    required this.ctrl,
    required this.filtro,
    required this.onFiltro,
    required this.lista,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.85),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(
                  top: AppSpacing.sm, bottom: AppSpacing.xs),
              decoration: BoxDecoration(
                color: c.borderStrong,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AppEyebrow(titulo),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
              child: SizedBox(
                height: 44,
                child: TextField(
                  controller: ctrl,
                  autofocus: true,
                  style: AppType.body.copyWith(color: c.text),
                  decoration: InputDecoration(
                    prefixIcon: Icon(Icons.search, size: 18, color: c.textMuted),
                    hintText: hintBuscar,
                    hintStyle: AppType.body.copyWith(color: c.textMuted),
                    filled: true,
                    fillColor: c.surface2,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md, vertical: AppSpacing.md),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      borderSide: BorderSide(color: c.border),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      borderSide: BorderSide(color: c.borderFocus),
                    ),
                    suffixIcon: filtro.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.close, size: 18, color: c.textMuted),
                            tooltip: 'Limpiar búsqueda',
                            onPressed: () {
                              ctrl.clear();
                              onFiltro('');
                            },
                          ),
                  ),
                  onChanged: onFiltro,
                ),
              ),
            ),
            Flexible(child: lista),
          ],
        ),
      ),
    );
  }
}

class _PatenteOpcion {
  final String patente;
  final String tipo;
  final bool esEnganche;
  const _PatenteOpcion(
      {required this.patente, required this.tipo, required this.esEnganche});
}

/// Selector de patente con BUSCADOR — tractores Y enganches (las multas
/// aplican a ambos). Sin filtro de ESTADO porque la auditoría puede
/// interesarse en unidades dadas de baja. Devuelve `(patente, esEnganche)`
/// para que el resultado sepa si hacer la cascada enganche→tractor→chofer.
class _DropdownPatente extends StatelessWidget {
  final String value;
  final void Function(String patente, bool esEnganche) onChanged;
  const _DropdownPatente({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .snapshots(),
      builder: (ctx, snap) {
        // Tractores primero, después enganches; cada grupo alfabético.
        final items = (snap.data?.docs ??
                <QueryDocumentSnapshot<Map<String, dynamic>>>[])
            .map((d) {
          final tipo = (d.data()['TIPO'] ?? '').toString().toUpperCase();
          return _PatenteOpcion(
            patente: d.id,
            tipo: tipo,
            esEnganche: tipo.isNotEmpty && tipo != 'TRACTOR',
          );
        }).toList()
          ..sort((a, b) {
            if (a.esEnganche != b.esEnganche) return a.esEnganche ? 1 : -1;
            return a.patente.compareTo(b.patente);
          });

        return _CampoSelector(
          label: 'Unidad (tractor o enganche)',
          icon: Icons.directions_car_outlined,
          textoSel: value.isEmpty ? null : value,
          hint: 'Elegí una unidad…',
          onTap: () async {
            final elegida = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              backgroundColor: c.surface1,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
              ),
              builder: (_) =>
                  _PatentePickerSheet(items: items, seleccionada: value),
            );
            if (elegida == null) return; // cerró sin elegir
            final it = items.firstWhere((e) => e.patente == elegida,
                orElse: () => _PatenteOpcion(
                    patente: elegida, tipo: '', esEnganche: false));
            onChanged(elegida, it.esEnganche);
          },
        );
      },
    );
  }
}

/// Sheet con buscador para elegir una unidad (tractor o enganche).
class _PatentePickerSheet extends StatefulWidget {
  final List<_PatenteOpcion> items;
  final String seleccionada;
  const _PatentePickerSheet(
      {required this.items, required this.seleccionada});

  @override
  State<_PatentePickerSheet> createState() => _PatentePickerSheetState();
}

class _PatentePickerSheetState extends State<_PatentePickerSheet> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = _filtro.trim().toUpperCase();
    final filtrados = f.isEmpty
        ? widget.items
        : widget.items
            .where((it) =>
                it.patente.toUpperCase().contains(f) ||
                it.tipo.toUpperCase().contains(f))
            .toList();
    return _PickerSheetScaffold(
      titulo: 'Elegir unidad',
      hintBuscar: 'Buscar por patente o tipo…',
      ctrl: _ctrl,
      filtro: _filtro,
      onFiltro: (v) => setState(() => _filtro = v),
      lista: filtrados.isEmpty
          ? _SinCoincidencias(filtro: _filtro)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              itemCount: filtrados.length,
              separatorBuilder: (_, __) => AppHairline(color: c.border),
              itemBuilder: (_, i) {
                final it = filtrados[i];
                final esActual = it.patente == widget.seleccionada;
                return InkWell(
                  onTap: () => Navigator.of(context).pop(it.patente),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(
                          it.esEnganche
                              ? Icons.rv_hookup
                              : Icons.local_shipping_outlined,
                          size: 18,
                          color: c.textMuted,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Text(it.patente,
                            style: AppType.mono.copyWith(
                                color: c.text,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            it.esEnganche ? it.tipo.toLowerCase() : 'tractor',
                            style: AppType.bodySm.copyWith(color: c.textMuted),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (esActual)
                          Icon(Icons.check_circle, color: c.success, size: 18),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Selector de choferes con BUSCADOR (rol CHOFER o legacy USUARIO). Sin
/// filtrar por ACTIVO=false porque la auditoría puede interesar choferes
/// que se fueron — su historial sigue siendo válido.
class _DropdownChofer extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _DropdownChofer({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .where('ROL', whereIn: [
            AppRoles.chofer,
            AppRoles.usuarioLegacy,
          ])
          .snapshots(),
      builder: (ctx, snap) {
        final docs = snap.data?.docs ??
            <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        // Lista (dni, nombre) ordenada por nombre ASC. No filtramos por
        // ACTIVO: choferes inactivos tienen historial y la auditoría puede
        // necesitarlo.
        final choferes = docs.map((d) {
          final data = d.data();
          final nombre = (data['NOMBRE'] ?? '').toString().trim();
          final activo = data['ACTIVO'] != false;
          return _ChoferOpcion(
            dni: d.id,
            nombre: nombre.isEmpty ? 'DNI ${d.id}' : nombre,
            activo: activo,
          );
        }).toList()
          ..sort((a, b) => a.nombre.compareTo(b.nombre));

        final sel = value.isEmpty
            ? null
            : choferes.firstWhere((c) => c.dni == value,
                orElse: () =>
                    _ChoferOpcion(dni: value, nombre: 'DNI $value', activo: true));

        return _CampoSelector(
          label: 'Chofer',
          icon: Icons.person_outline,
          textoSel: sel?.nombre,
          hint: 'Elegí un chofer…',
          onTap: () async {
            final elegido = await showModalBottomSheet<String>(
              context: context,
              isScrollControlled: true,
              backgroundColor: c.surface1,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
              ),
              builder: (_) =>
                  _ChoferPickerSheet(choferes: choferes, seleccionado: value),
            );
            if (elegido == null) return; // cerró sin elegir
            onChanged(elegido);
          },
        );
      },
    );
  }
}

/// Sheet con buscador para elegir un chofer (filtra por nombre o DNI).
class _ChoferPickerSheet extends StatefulWidget {
  final List<_ChoferOpcion> choferes;
  final String seleccionado;
  const _ChoferPickerSheet(
      {required this.choferes, required this.seleccionado});

  @override
  State<_ChoferPickerSheet> createState() => _ChoferPickerSheetState();
}

class _ChoferPickerSheetState extends State<_ChoferPickerSheet> {
  final _ctrl = TextEditingController();
  String _filtro = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = _filtro.trim().toUpperCase();
    final filtrados = f.isEmpty
        ? widget.choferes
        : widget.choferes
            .where((ch) =>
                ch.nombre.toUpperCase().contains(f) || ch.dni.contains(f))
            .toList();
    return _PickerSheetScaffold(
      titulo: 'Elegir chofer',
      hintBuscar: 'Buscar por nombre o DNI…',
      ctrl: _ctrl,
      filtro: _filtro,
      onFiltro: (v) => setState(() => _filtro = v),
      lista: filtrados.isEmpty
          ? _SinCoincidencias(filtro: _filtro)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
              itemCount: filtrados.length,
              separatorBuilder: (_, __) => AppHairline(color: c.border),
              itemBuilder: (_, i) {
                final ch = filtrados[i];
                final esActual = ch.dni == widget.seleccionado;
                return InkWell(
                  onTap: () => Navigator.of(context).pop(ch.dni),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        vertical: AppSpacing.md),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                ch.nombre,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: AppType.body.copyWith(
                                  color: ch.activo ? c.text : c.textMuted,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text('DNI ${ch.dni}',
                                  style: AppType.monoSm
                                      .copyWith(color: c.textMuted)),
                            ],
                          ),
                        ),
                        if (!ch.activo)
                          Padding(
                            padding:
                                const EdgeInsets.only(left: AppSpacing.sm),
                            child: AppBadge(
                              text: 'INACTIVO',
                              color: c.warning,
                              size: AppBadgeSize.sm,
                            ),
                          ),
                        if (esActual)
                          Padding(
                            padding: const EdgeInsets.only(left: AppSpacing.sm),
                            child: Icon(Icons.check_circle,
                                color: c.success, size: 18),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class _ChoferOpcion {
  final String dni;
  final String nombre;
  final bool activo;
  const _ChoferOpcion({
    required this.dni,
    required this.nombre,
    required this.activo,
  });
}

/// Estado vacío del picker (lista sin coincidencias con el filtro).
class _SinCoincidencias extends StatelessWidget {
  final String filtro;
  const _SinCoincidencias({required this.filtro});

  @override
  Widget build(BuildContext context) {
    return AppEmptyState(
      icon: Icons.search_off_outlined,
      title: filtro.trim().isEmpty
          ? 'Sin opciones cargadas'
          : 'Sin coincidencias',
      subtitle: filtro.trim().isEmpty
          ? null
          : 'No hay resultados para "$filtro".',
    );
  }
}

// ============================================================================
// RESULTADO TAB 1: historial completo de la unidad (choferes / tractores)
// ============================================================================

/// Historial completo de una unidad. Para un TRACTOR: todos los choferes que
/// la manejaron (de ASIGNACIONES_VEHICULO). Para un ENGANCHE: todos los
/// tractores que lo llevaron (de ASIGNACIONES_ENGANCHE). Filtrable por
/// [rango] (null = todo el historial). Reemplazó al modo "fecha puntual" el
/// 2026-06-01: el operador necesitaba ver todo de una y acotar por rango, no
/// ir fecha por fecha.
class _HistorialPorUnidad extends StatelessWidget {
  final String patente;
  final bool esEnganche;
  final DateTimeRange? rango;
  const _HistorialPorUnidad({
    required this.patente,
    required this.esEnganche,
    required this.rango,
  });

  /// Una asignación entra si su período [desde, hasta] se solapa con el
  /// rango (hasta==null = activa, sin fin).
  bool _enRango(DateTime desde, DateTime? hasta) {
    final r = rango;
    if (r == null) return true;
    if (desde.isAfter(r.end)) return false;
    if (hasta != null && hasta.isBefore(r.start)) return false;
    return true;
  }

  Widget _vacio() {
    final conFiltro = rango != null;
    return AppEmptyState(
      icon: Icons.history_toggle_off_outlined,
      title: conFiltro ? 'Sin registros en ese rango' : 'Sin historial',
      subtitle: conFiltro
          ? 'No hay asignaciones de esta unidad en el rango elegido. Probá '
              'ampliar las fechas o tocá la X para ver todo el historial.'
          : 'Esta unidad no tiene asignaciones registradas en el sistema. Si '
              'nunca se le asignó nadie oficialmente, no aparece nada acá.',
    );
  }

  @override
  Widget build(BuildContext context) {
    return esEnganche ? _buildEnganche() : _buildTractor();
  }

  Widget _buildTractor() {
    return StreamBuilder<List<AsignacionVehiculo>>(
      stream: AsignacionVehiculoService().streamHistorialPorVehiculo(patente),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSkeletonList(count: 4, conAvatar: true);
        }
        if (snap.hasError) {
          return AppErrorState(
              title: 'Error', subtitle: snap.error.toString());
        }
        final filtradas = (snap.data ?? const <AsignacionVehiculo>[])
            .where((a) => _enRango(a.desde, a.hasta))
            .toList();
        if (filtradas.isEmpty) return _vacio();
        final choferesUnicos =
            filtradas.map((a) => a.choferDni).toSet().length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppKpiStrip(
              stats: [
                AppStat(
                    label: 'Asignaciones', value: '${filtradas.length}'),
                AppStat(label: 'Choferes', value: '$choferesUnicos'),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...filtradas.map((a) => _AsignacionCardPorUnidad(asignacion: a)),
          ],
        );
      },
    );
  }

  Widget _buildEnganche() {
    return StreamBuilder<List<AsignacionEnganche>>(
      stream: AsignacionEngancheService().streamHistorialPorEnganche(patente),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSkeletonList(count: 4, conAvatar: true);
        }
        if (snap.hasError) {
          return AppErrorState(
              title: 'Error', subtitle: snap.error.toString());
        }
        final filtradas = (snap.data ?? const <AsignacionEnganche>[])
            .where((a) => _enRango(a.desde, a.hasta))
            .toList();
        if (filtradas.isEmpty) return _vacio();
        final tractoresUnicos =
            filtradas.map((a) => a.tractorId).toSet().length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppKpiStrip(
              stats: [
                AppStat(
                    label: 'Asignaciones', value: '${filtradas.length}'),
                AppStat(label: 'Tractores', value: '$tractoresUnicos'),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const _BannerInfo(
              texto: 'Es un enganche: mostramos los tractores que lo llevaron. '
                  'Para ver el chofer de cada período, elegí ese tractor en '
                  'esta misma vista.',
            ),
            const SizedBox(height: AppSpacing.md),
            ...filtradas.map((a) => _EngancheHistorialCard(asignacion: a)),
          ],
        );
      },
    );
  }
}

/// Card del tab "Por unidad": el destaque es el chofer (lo que el operador
/// busca: a quién le pongo la multa).
class _AsignacionCardPorUnidad extends StatelessWidget {
  final AsignacionVehiculo asignacion;
  const _AsignacionCardPorUnidad({required this.asignacion});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final nombre = (asignacion.choferNombre ?? '').trim().isNotEmpty
        ? asignacion.choferNombre!.trim()
        : 'DNI ${asignacion.choferDni}';
    final esActual = asignacion.hasta == null;
    final color = esActual ? c.success : c.textMuted;
    return AppCard(
      tier: 1,
      accent: esActual ? c.success : null,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AppDot(color, size: 7, glow: esActual),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(nombre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.h5),
                    const SizedBox(height: 2),
                    Text('DNI ${asignacion.choferDni}',
                        style: AppType.monoSm.copyWith(color: c.textMuted)),
                  ],
                ),
              ),
              if (esActual) ...[
                const SizedBox(width: AppSpacing.sm),
                const _BadgeActual(),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          _Linea(
            label: 'Asignado desde',
            valor: AppFormatters.formatearFecha(asignacion.desde),
            mono: true,
          ),
          _Linea(
            label: esActual ? 'Hasta' : 'Asignado hasta',
            valor: esActual
                ? 'En uso (sin fecha de fin)'
                : AppFormatters.formatearFecha(asignacion.hasta!),
            mono: !esActual,
            colorValor: esActual ? c.success : null,
          ),
          _Linea(label: 'Duración', valor: _duracion(asignacion)),
          if ((asignacion.motivo ?? '').trim().isNotEmpty)
            _Linea(label: 'Motivo', valor: asignacion.motivo!.trim()),
          if ((asignacion.asignadoPorNombre ?? '').trim().isNotEmpty ||
              asignacion.asignadoPorDni.isNotEmpty)
            _Linea(
              label: 'Asignado por',
              valor: (asignacion.asignadoPorNombre ?? '').isNotEmpty
                  ? asignacion.asignadoPorNombre!
                  : 'DNI ${asignacion.asignadoPorDni}',
            ),
        ],
      ),
    );
  }
}

// ============================================================================
// CARD DE UN PERÍODO DE ENGANCHE (qué tractor lo llevó)
// ============================================================================

/// Card de un período del historial de un enganche: qué tractor lo llevó y
/// desde/hasta cuándo. El destaque es el tractor — de ahí se deriva el chofer
/// (eligiendo ese tractor en la misma vista).
class _EngancheHistorialCard extends StatelessWidget {
  final AsignacionEnganche asignacion;
  const _EngancheHistorialCard({required this.asignacion});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esActual = asignacion.hasta == null;
    final color = esActual ? c.success : c.textMuted;
    final tractor = asignacion.tractorId;
    final modelo = (asignacion.tractorModelo ?? '').trim();
    return AppCard(
      tier: 1,
      accent: esActual ? c.success : null,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AppDot(color, size: 7, glow: esActual),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tractor,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.mono.copyWith(
                            color: c.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700)),
                    if (modelo.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(modelo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppType.bodySm.copyWith(color: c.textMuted)),
                    ],
                  ],
                ),
              ),
              if (esActual) ...[
                const SizedBox(width: AppSpacing.sm),
                const _BadgeActual(),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          _Linea(
            label: 'Enganchado desde',
            valor: AppFormatters.formatearFecha(asignacion.desde),
            mono: true,
          ),
          _Linea(
            label: 'Hasta',
            valor: esActual
                ? 'Sigue enganchado'
                : AppFormatters.formatearFecha(asignacion.hasta!),
            mono: !esActual,
            colorValor: esActual ? c.success : null,
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// RESULTADO TAB 2: historial de unidades de un chofer
// ============================================================================

class _HistorialPorChofer extends StatelessWidget {
  final String choferDni;
  const _HistorialPorChofer({required this.choferDni});

  @override
  Widget build(BuildContext context) {
    // Stream del service: orderBy desde DESC + limit 50.
    // La cardinalidad por chofer es chica (Vecchi: ~10-20 cambios por
    // chofer en historia, incluso para los más rotativos). 50 cubre con
    // margen los próximos años.
    final stream =
        AsignacionVehiculoService().streamHistorialPorChofer(choferDni);

    return StreamBuilder<List<AsignacionVehiculo>>(
      stream: stream,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSkeletonList(count: 5, conAvatar: false);
        }
        if (snap.hasError) {
          return AppErrorState(
              title: 'Error', subtitle: snap.error.toString());
        }
        final asignaciones = snap.data ?? const <AsignacionVehiculo>[];
        if (asignaciones.isEmpty) {
          return const AppEmptyState(
            icon: Icons.history_toggle_off_outlined,
            title: 'Sin historial',
            subtitle:
                'Este chofer no tiene asignaciones registradas en el sistema. '
                'Si nunca se le asignó una unidad oficialmente, no va a aparecer '
                'nada acá aunque maneje en la realidad.',
          );
        }

        // Resumen arriba: cuántas unidades distintas + total días asignado.
        final unidadesUnicas =
            asignaciones.map((a) => a.vehiculoId).toSet().length;
        final totalDias = asignaciones.fold<int>(
          0,
          (acc, a) => acc + a.diasDuracion(),
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppKpiStrip(
              stats: [
                AppStat(
                    label: 'Asignaciones',
                    value: asignaciones.length.toString()),
                AppStat(
                    label: 'Unidades', value: unidadesUnicas.toString()),
                AppStat(
                    label: 'Tiempo total', value: _formatDias(totalDias)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            ...asignaciones
                .map((a) => _AsignacionCardPorChofer(asignacion: a)),
            _EnganchesDelChofer(asignacionesTractor: asignaciones),
          ],
        );
      },
    );
  }
}

/// Sección "Enganches que llevó" del historial por chofer (cruce
/// chofer→tractor→enganche). Si el chofer nunca llevó enganches, no muestra
/// nada para no ensuciar la vista.
class _EnganchesDelChofer extends StatelessWidget {
  final List<AsignacionVehiculo> asignacionesTractor;
  const _EnganchesDelChofer({required this.asignacionesTractor});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return FutureBuilder<List<EngancheLlevado>>(
      future: AsignacionEngancheService()
          .enganchesLlevadosPorChofer(asignacionesTractor),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.only(top: AppSpacing.md),
            child: AppSkeletonList(count: 2, conAvatar: false),
          );
        }
        final enganches = snap.data ?? const <EngancheLlevado>[];
        if (enganches.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppSpacing.lg),
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: 4),
              child: Row(
                children: [
                  AppDot(c.brand, size: 6),
                  const SizedBox(width: AppSpacing.sm),
                  const AppEyebrow('Enganches que llevó'),
                ],
              ),
            ),
            ...enganches.map((e) => _EngancheLlevadoCard(item: e)),
          ],
        );
      },
    );
  }
}

class _EngancheLlevadoCard extends StatelessWidget {
  final EngancheLlevado item;
  const _EngancheLlevadoCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activo = item.hasta == null;
    final color = activo ? c.success : c.textMuted;
    return AppCard(
      tier: 1,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          AppDot(color, size: 7, glow: activo),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.enganche,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.mono.copyWith(
                        color: c.text, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text('vía tractor ${item.tractor}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.bodySm.copyWith(color: c.textMuted)),
                const SizedBox(height: 2),
                Text(
                  activo
                      ? 'Desde ${AppFormatters.formatearFecha(item.desde)} · sigue'
                      : '${AppFormatters.formatearFecha(item.desde)} → '
                          '${AppFormatters.formatearFecha(item.hasta!)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(
                      color: activo ? c.success : c.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Card del tab "Por chofer": el destaque es la patente (lo que el
/// operador busca: qué unidad manejaba en cada momento).
class _AsignacionCardPorChofer extends StatelessWidget {
  final AsignacionVehiculo asignacion;
  const _AsignacionCardPorChofer({required this.asignacion});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esActual = asignacion.hasta == null;
    final color = esActual ? c.success : c.textMuted;
    return AppCard(
      tier: 1,
      accent: esActual ? c.success : null,
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: AppDot(color, size: 7, glow: esActual),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  asignacion.vehiculoId,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.mono.copyWith(
                    color: c.text,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (esActual) ...[
                const SizedBox(width: AppSpacing.sm),
                const _BadgeActual(),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          const AppHairline(),
          const SizedBox(height: AppSpacing.md),
          _Linea(
            label: 'Desde',
            valor: AppFormatters.formatearFecha(asignacion.desde),
            mono: true,
          ),
          _Linea(
            label: 'Hasta',
            valor: esActual
                ? 'Sigue manejándola'
                : AppFormatters.formatearFecha(asignacion.hasta!),
            mono: !esActual,
            colorValor: esActual ? c.success : null,
          ),
          _Linea(label: 'Duración', valor: _duracion(asignacion)),
          if ((asignacion.motivo ?? '').trim().isNotEmpty)
            _Linea(label: 'Motivo', valor: asignacion.motivo!.trim()),
        ],
      ),
    );
  }
}

// ============================================================================
// HELPERS COMPARTIDOS
// ============================================================================

class _BadgeActual extends StatelessWidget {
  const _BadgeActual();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppBadge(
      text: 'ACTUAL',
      color: c.success,
      dot: true,
      size: AppBadgeSize.sm,
    );
  }
}

/// Primitiva de fila label (izq) / valor (der) — Núcleo. `mono` para los
/// valores técnicos (fechas/patentes); `colorValor` para resaltar el estado
/// "en uso" en verde.
class _Linea extends StatelessWidget {
  final String label;
  final String valor;
  final bool mono;
  final Color? colorValor;
  const _Linea({
    required this.label,
    required this.valor,
    this.mono = false,
    this.colorValor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final valBase = mono ? AppType.mono : AppType.body;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 4,
            child: Text(
              label,
              style: AppType.bodySm.copyWith(color: c.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            flex: 6,
            child: Text(
              valor,
              textAlign: TextAlign.right,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: valBase.copyWith(color: colorValor ?? c.text),
            ),
          ),
        ],
      ),
    );
  }
}

String _duracion(AsignacionVehiculo a) {
  final fin = a.hasta ?? DateTime.now();
  final dias = fin.difference(a.desde).inDays;
  if (dias == 0) return 'Menos de un día';
  if (dias == 1) return '1 día';
  if (dias < 30) return '$dias días';
  final meses = (dias / 30).floor();
  if (meses == 1) return '~1 mes ($dias días)';
  if (meses < 12) return '~$meses meses ($dias días)';
  final anios = (dias / 365).floor();
  return anios == 1
      ? '~1 año ($dias días)'
      : '~$anios años ($dias días)';
}

/// Formato humano de una cantidad de días para el KPI "Tiempo total".
String _formatDias(int totalDias) {
  if (totalDias == 0) return '< 1 día';
  if (totalDias == 1) return '1 día';
  if (totalDias < 30) return '$totalDias días';
  final meses = (totalDias / 30).floor();
  if (meses < 12) return '~$meses meses';
  final anios = (totalDias / 365).floor();
  return anios == 1 ? '~1 año' : '~$anios años';
}
