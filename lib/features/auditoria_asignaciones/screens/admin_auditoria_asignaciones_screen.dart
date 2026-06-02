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

/// Auditoría de asignaciones — 2 vistas en TabBar.
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
          Material(
            color: AppColors.surface1,
            child: TabBar(
              controller: _tab,
              indicatorColor: AppColors.brand,
              labelColor: AppColors.brand,
              unselectedLabelColor: Colors.white60,
              labelStyle:
                  AppType.body.copyWith(fontWeight: FontWeight.w600),
              tabs: const [
                Tab(
                  icon: Icon(Icons.local_shipping_outlined),
                  text: 'Por unidad',
                ),
                Tab(
                  icon: Icon(Icons.person_search_outlined),
                  text: 'Por chofer',
                ),
              ],
            ),
          ),
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
      padding: const EdgeInsets.all(AppSpacing.md),
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
      padding: const EdgeInsets.all(AppSpacing.md),
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

class _BannerInfo extends StatelessWidget {
  final String texto;
  const _BannerInfo({required this.texto});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.info.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.info.withValues(alpha: 0.30)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: AppColors.info, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texto,
              style: AppType.label.copyWith(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector de rango de fechas OPCIONAL. Por defecto "Todo el historial";
/// al tocar abre un date range picker. Con rango activo muestra una X para
/// limpiarlo (volver a todo).
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
    final hayRango = rango != null;
    final texto = hayRango
        ? '${_fmt(rango!.start)}  →  ${_fmt(rango!.end)}'
        : 'Todo el historial';
    return InkWell(
      onTap: onElegir,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.brand.withValues(alpha: 0.40)),
        ),
        child: Row(
          children: [
            const Icon(Icons.date_range, color: AppColors.brand, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('PERÍODO',
                      style: AppType.eyebrow.copyWith(color: AppColors.brand)),
                  const SizedBox(height: 2),
                  Text(texto,
                      style: AppType.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ],
              ),
            ),
            if (onLimpiar != null)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54, size: 18),
                tooltip: 'Ver todo el historial',
                onPressed: onLimpiar,
                visualDensity: VisualDensity.compact,
              )
            else
              const Icon(Icons.edit, color: Colors.white54, size: 16),
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
    final tiene = (textoSel ?? '').isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          prefixIcon: Icon(icon, color: Colors.white54),
          suffixIcon: const Icon(Icons.search, color: Colors.white54),
        ),
        child: Text(
          tiene ? textoSel! : hint,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: tiene ? Colors.white : Colors.white54,
            fontSize: 14,
            fontWeight: tiene ? FontWeight.w600 : FontWeight.normal,
            letterSpacing: tiene ? 0.5 : 0,
          ),
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
                color: AppColors.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.xs),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(titulo,
                    style: AppType.eyebrow.copyWith(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        letterSpacing: 1.4)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.sm),
              child: TextField(
                controller: ctrl,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: hintBuscar,
                  border: const OutlineInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md, vertical: AppSpacing.md),
                  suffixIcon: filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close, size: 18),
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
            Expanded(child: lista),
          ],
        ),
      ),
    );
  }
}

/// Estado vacío del picker (lista sin coincidencias con el filtro).
Widget _sinCoincidencias(String filtro) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Text(
        filtro.trim().isEmpty
            ? 'No hay opciones cargadas.'
            : 'Sin coincidencias con "$filtro".',
        textAlign: TextAlign.center,
        style:
            AppType.body.copyWith(color: AppColors.textSecondary, fontSize: 13),
      ),
    ),
  );
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
              backgroundColor: AppColors.background,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
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
    final f = _filtro.trim().toUpperCase();
    final filtrados = f.isEmpty
        ? widget.items
        : widget.items
            .where((it) =>
                it.patente.toUpperCase().contains(f) ||
                it.tipo.toUpperCase().contains(f))
            .toList();
    return _PickerSheetScaffold(
      titulo: 'ELEGIR UNIDAD',
      hintBuscar: 'Buscar por patente o tipo…',
      ctrl: _ctrl,
      filtro: _filtro,
      onFiltro: (v) => setState(() => _filtro = v),
      lista: filtrados.isEmpty
          ? _sinCoincidencias(_filtro)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.lg),
              itemCount: filtrados.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.borderSubtle),
              itemBuilder: (_, i) {
                final it = filtrados[i];
                final esActual = it.patente == widget.seleccionada;
                return InkWell(
                  onTap: () => Navigator.of(context).pop(it.patente),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(
                          it.esEnganche
                              ? Icons.rv_hookup
                              : Icons.local_shipping_outlined,
                          size: 18,
                          color: Colors.white38,
                        ),
                        const SizedBox(width: AppSpacing.md),
                        Text(it.patente,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5)),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            it.esEnganche ? it.tipo.toLowerCase() : 'tractor',
                            style: AppType.label
                                .copyWith(color: Colors.white38, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (esActual)
                          const Icon(Icons.check_circle,
                              color: AppColors.success, size: 20),
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
              backgroundColor: AppColors.background,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
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
    final f = _filtro.trim().toUpperCase();
    final filtrados = f.isEmpty
        ? widget.choferes
        : widget.choferes
            .where((c) =>
                c.nombre.toUpperCase().contains(f) || c.dni.contains(f))
            .toList();
    return _PickerSheetScaffold(
      titulo: 'ELEGIR CHOFER',
      hintBuscar: 'Buscar por nombre o DNI…',
      ctrl: _ctrl,
      filtro: _filtro,
      onFiltro: (v) => setState(() => _filtro = v),
      lista: filtrados.isEmpty
          ? _sinCoincidencias(_filtro)
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm, 0, AppSpacing.sm, AppSpacing.lg),
              itemCount: filtrados.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, color: AppColors.borderSubtle),
              itemBuilder: (_, i) {
                final c = filtrados[i];
                final esActual = c.dni == widget.seleccionado;
                return InkWell(
                  onTap: () => Navigator.of(context).pop(c.dni),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm, vertical: AppSpacing.md),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                c.nombre,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color:
                                      c.activo ? Colors.white : Colors.white54,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Text('DNI ${c.dni}',
                                  style: AppType.label.copyWith(
                                      color: Colors.white38, fontSize: 11)),
                            ],
                          ),
                        ),
                        if (!c.activo)
                          Padding(
                            padding:
                                const EdgeInsets.only(left: AppSpacing.sm),
                            child: Text('(inactivo)',
                                style: AppType.label.copyWith(
                                    color: AppColors.warning, fontSize: 11)),
                          ),
                        if (esActual)
                          const Padding(
                            padding: EdgeInsets.only(left: AppSpacing.sm),
                            child: Icon(Icons.check_circle,
                                color: AppColors.success, size: 20),
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

class _Placeholder extends StatelessWidget {
  final IconData icono;
  final String titulo;
  final String subtitulo;
  const _Placeholder({
    required this.icono,
    required this.titulo,
    required this.subtitulo,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          Icon(icono, color: Colors.white24, size: 64),
          const SizedBox(height: AppSpacing.md),
          Text(titulo, style: AppType.heading.copyWith(color: Colors.white70)),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(subtitulo,
                textAlign: TextAlign.center,
                style: AppType.label.copyWith(color: Colors.white38)),
          ),
        ],
      ),
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
    return _Placeholder(
      icono: Icons.history_toggle_off_outlined,
      titulo: conFiltro ? 'Sin registros en ese rango' : 'Sin historial',
      subtitulo: conFiltro
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
            _ResumenUnidad(
              asignaciones: filtradas.length,
              etiquetaSecundaria: 'Choferes distintos',
              valorSecundario: '$choferesUnicos',
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
            _ResumenUnidad(
              asignaciones: filtradas.length,
              etiquetaSecundaria: 'Tractores distintos',
              valorSecundario: '$tractoresUnicos',
            ),
            const SizedBox(height: AppSpacing.sm),
            const _BannerInfo(
              texto: 'Es un enganche: mostramos los tractores que lo llevaron. '
                  'Para ver el chofer de cada período, elegí ese tractor en '
                  'esta misma pestaña.',
            ),
            const SizedBox(height: AppSpacing.md),
            ...filtradas.map((a) => _EngancheHistorialCard(asignacion: a)),
          ],
        );
      },
    );
  }
}

/// Resumen de 2 KPIs arriba del historial de una unidad.
class _ResumenUnidad extends StatelessWidget {
  final int asignaciones;
  final String etiquetaSecundaria;
  final String valorSecundario;
  const _ResumenUnidad({
    required this.asignaciones,
    required this.etiquetaSecundaria,
    required this.valorSecundario,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
                child:
                    _Kpi(label: 'Asignaciones', valor: '$asignaciones')),
            Container(width: 1, height: 36, color: Colors.white12),
            Expanded(
                child: _Kpi(
                    label: etiquetaSecundaria, valor: valorSecundario)),
          ],
        ),
      ),
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
    final nombre = (asignacion.choferNombre ?? '').trim().isNotEmpty
        ? asignacion.choferNombre!.trim()
        : 'DNI ${asignacion.choferDni}';
    final esActual = asignacion.hasta == null;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: const BoxDecoration(
                    color: AppColors.brand,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.person,
                      color: Colors.white, size: 24),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nombre,
                          style: AppType.heading
                              .copyWith(color: Colors.white, fontSize: 17)),
                      Text('DNI ${asignacion.choferDni}',
                          style: AppType.label
                              .copyWith(color: Colors.white54)),
                    ],
                  ),
                ),
                if (esActual) const _BadgeActual(),
              ],
            ),
            const Divider(color: Colors.white12, height: 24),
            _Fila(
              label: 'Asignado desde',
              valor: AppFormatters.formatearFecha(asignacion.desde),
            ),
            const SizedBox(height: AppSpacing.xs),
            _Fila(
              label: esActual ? 'Hasta' : 'Asignado hasta',
              valor: esActual
                  ? 'En uso (sin fecha de fin)'
                  : AppFormatters.formatearFecha(asignacion.hasta!),
              colorValor: esActual ? AppColors.success : Colors.white,
            ),
            const SizedBox(height: AppSpacing.xs),
            _Fila(
              label: 'Duración',
              valor: _duracion(asignacion),
              colorValor: Colors.white70,
            ),
            if ((asignacion.motivo ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              _Fila(label: 'Motivo', valor: asignacion.motivo!.trim()),
            ],
            if ((asignacion.asignadoPorNombre ?? '').trim().isNotEmpty ||
                asignacion.asignadoPorDni.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.xs),
              _Fila(
                label: 'Asignado por',
                valor: (asignacion.asignadoPorNombre ?? '').isNotEmpty
                    ? asignacion.asignadoPorNombre!
                    : 'DNI ${asignacion.asignadoPorDni}',
                colorValor: Colors.white54,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// CARD DE UN PERÍODO DE ENGANCHE (qué tractor lo llevó)
// ============================================================================

/// Card de un período del historial de un enganche: qué tractor lo llevó y
/// desde/hasta cuándo. El destaque es el tractor — de ahí se deriva el chofer
/// (eligiendo ese tractor en la misma pestaña).
class _EngancheHistorialCard extends StatelessWidget {
  final AsignacionEnganche asignacion;
  const _EngancheHistorialCard({required this.asignacion});

  @override
  Widget build(BuildContext context) {
    final esActual = asignacion.hasta == null;
    final tractor = asignacion.tractorId;
    final modelo = (asignacion.tractorModelo ?? '').trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: esActual
                          ? AppColors.success
                          : AppColors.brand.withValues(alpha: 0.60),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.local_shipping,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tractor,
                            style: AppType.heading.copyWith(
                                color: Colors.white,
                                fontSize: 18,
                                letterSpacing: 1,
                                fontWeight: FontWeight.w700)),
                        if (modelo.isNotEmpty)
                          Text(modelo,
                              style: AppType.label
                                  .copyWith(color: Colors.white54)),
                      ],
                    ),
                  ),
                  if (esActual) const _BadgeActual(),
                ],
              ),
              const Divider(color: Colors.white12, height: 24),
              _Fila(
                label: 'Enganchado desde',
                valor: AppFormatters.formatearFecha(asignacion.desde),
              ),
              const SizedBox(height: AppSpacing.xs),
              _Fila(
                label: 'Hasta',
                valor: esActual
                    ? 'Sigue enganchado'
                    : AppFormatters.formatearFecha(asignacion.hasta!),
                colorValor: esActual ? AppColors.success : Colors.white,
              ),
            ],
          ),
        ),
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
          return const _Placeholder(
            icono: Icons.history_toggle_off_outlined,
            titulo: 'Sin historial',
            subtitulo:
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
            _ResumenChofer(
              asignaciones: asignaciones.length,
              unidades: unidadesUnicas,
              totalDias: totalDias,
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
              child: Text('ENGANCHES QUE LLEVÓ',
                  style: AppType.eyebrow.copyWith(color: Colors.white54)),
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
    final activo = item.hasta == null;
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            const Icon(Icons.rv_hookup, color: Colors.white54, size: 22),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.enganche,
                      style: AppType.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5)),
                  Text('vía tractor ${item.tractor}',
                      style: AppType.label.copyWith(color: Colors.white54)),
                  const SizedBox(height: 2),
                  Text(
                    activo
                        ? 'Desde ${AppFormatters.formatearFecha(item.desde)} · sigue'
                        : '${AppFormatters.formatearFecha(item.desde)} → '
                            '${AppFormatters.formatearFecha(item.hasta!)}',
                    style: AppType.label.copyWith(
                        color: activo ? AppColors.success : Colors.white70),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card chiquita arriba del historial: 3 KPIs.
class _ResumenChofer extends StatelessWidget {
  final int asignaciones;
  final int unidades;
  final int totalDias;
  const _ResumenChofer({
    required this.asignaciones,
    required this.unidades,
    required this.totalDias,
  });

  String _formatDias() {
    if (totalDias == 0) return '< 1 día';
    if (totalDias == 1) return '1 día';
    if (totalDias < 30) return '$totalDias días';
    final meses = (totalDias / 30).floor();
    if (meses < 12) return '~$meses meses';
    final anios = (totalDias / 365).floor();
    return anios == 1 ? '~1 año' : '~$anios años';
  }

  @override
  Widget build(BuildContext context) {
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
                child: _Kpi(
                    label: 'Asignaciones',
                    valor: asignaciones.toString())),
            Container(width: 1, height: 36, color: Colors.white12),
            Expanded(
                child: _Kpi(
                    label: 'Unidades distintas',
                    valor: unidades.toString())),
            Container(width: 1, height: 36, color: Colors.white12),
            Expanded(
                child: _Kpi(label: 'Tiempo total', valor: _formatDias())),
          ],
        ),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  final String label;
  final String valor;
  const _Kpi({required this.label, required this.valor});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(valor,
            style: AppType.heading
                .copyWith(color: AppColors.brand, fontSize: 20)),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center,
            style: AppType.eyebrow.copyWith(color: Colors.white54)),
      ],
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
    final esActual = asignacion.hasta == null;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: esActual
                          ? AppColors.success
                          : AppColors.brand.withValues(alpha: 0.60),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.local_shipping,
                        color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Text(
                      asignacion.vehiculoId,
                      style: AppType.heading.copyWith(
                        color: Colors.white,
                        fontSize: 22,
                        letterSpacing: 1,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (esActual) const _BadgeActual(),
                ],
              ),
              const Divider(color: Colors.white12, height: 24),
              _Fila(
                label: 'Desde',
                valor: AppFormatters.formatearFecha(asignacion.desde),
              ),
              const SizedBox(height: AppSpacing.xs),
              _Fila(
                label: 'Hasta',
                valor: esActual
                    ? 'Sigue manejándola'
                    : AppFormatters.formatearFecha(asignacion.hasta!),
                colorValor: esActual ? AppColors.success : Colors.white,
              ),
              const SizedBox(height: AppSpacing.xs),
              _Fila(
                label: 'Duración',
                valor: _duracion(asignacion),
                colorValor: Colors.white70,
              ),
              if ((asignacion.motivo ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                _Fila(label: 'Motivo', valor: asignacion.motivo!.trim()),
              ],
            ],
          ),
        ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.success.withValues(alpha: 0.20),
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: AppColors.success.withValues(alpha: 0.50)),
      ),
      child: Text('ACTUAL',
          style: AppType.eyebrow.copyWith(color: AppColors.success)),
    );
  }
}

class _Fila extends StatelessWidget {
  final String label;
  final String valor;
  final Color? colorValor;
  const _Fila({required this.label, required this.valor, this.colorValor});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(label,
              style: AppType.label.copyWith(color: Colors.white54)),
        ),
        Expanded(
          child: Text(valor,
              style: AppType.body.copyWith(
                  color: colorValor ?? Colors.white,
                  fontWeight: FontWeight.w500)),
        ),
      ],
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
