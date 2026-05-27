import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../asignaciones/models/asignacion_vehiculo.dart';
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
  late DateTime _fecha;
  String _patente = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _fecha = DateTime.now();
  }

  Future<void> _elegirFecha() async {
    final ahora = DateTime.now();
    final f = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(2024, 1, 1),
      lastDate: ahora,
      locale: const Locale('es', 'AR'),
      helpText: 'Fecha a consultar',
      confirmText: 'Aplicar',
      cancelText: 'Cancelar',
    );
    if (f == null) return;
    setState(() => _fecha = DateTime(f.year, f.month, f.day, 23, 59, 59));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        const _BannerInfo(
          texto: 'Mostramos qué chofer tenía asignada la unidad elegida en '
              'la fecha que selecciones, según el historial de asignaciones '
              'del sistema. Sirve para multas tardías y reconciliación.',
        ),
        const SizedBox(height: AppSpacing.md),
        _SelectorFecha(fecha: _fecha, onTap: _elegirFecha),
        const SizedBox(height: AppSpacing.sm),
        _DropdownPatente(
          value: _patente,
          onChanged: (v) => setState(() => _patente = v),
        ),
        const SizedBox(height: AppSpacing.lg),
        if (_patente.isEmpty)
          const _Placeholder(
            icono: Icons.local_shipping_outlined,
            titulo: 'Elegí una unidad',
            subtitulo:
                'Seleccioná un tractor y la fecha para ver quién lo manejaba.',
          )
        else
          _ResultadoAsignacion(patente: _patente, fecha: _fecha),
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
        if (_choferDni.isEmpty)
          const _Placeholder(
            icono: Icons.person_search_outlined,
            titulo: 'Elegí un chofer',
            subtitulo:
                'Seleccioná un chofer para ver todas las unidades que '
                'condujo y los rangos de fechas.',
          )
        else
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

class _SelectorFecha extends StatelessWidget {
  final DateTime fecha;
  final VoidCallback onTap;
  const _SelectorFecha({required this.fecha, required this.onTap});

  String _fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-${d.year}';

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.brand.withValues(alpha: 0.40)),
        ),
        child: Row(
          children: [
            const Icon(Icons.calendar_today, color: AppColors.brand, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FECHA',
                      style: AppType.eyebrow.copyWith(color: AppColors.brand)),
                  const SizedBox(height: 2),
                  Text(_fmt(fecha),
                      style: AppType.body.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                ],
              ),
            ),
            const Icon(Icons.edit, color: Colors.white54, size: 16),
          ],
        ),
      ),
    );
  }
}

/// Dropdown de patentes (solo TIPO=TRACTOR). Sin filtro de ESTADO porque
/// la auditoría puede interesarse en unidades dadas de baja.
class _DropdownPatente extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _DropdownPatente({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .where('TIPO', isEqualTo: 'TRACTOR')
          .snapshots(),
      builder: (ctx, snap) {
        final patentes = (snap.data?.docs ??
                <QueryDocumentSnapshot<Map<String, dynamic>>>[])
            .map((d) => d.id)
            .toList()
          ..sort();
        return DropdownButtonFormField<String>(
          isDense: true,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Unidad (tractor)',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon:
                Icon(Icons.local_shipping_outlined, color: Colors.white54),
          ),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          dropdownColor: AppColors.surface2,
          initialValue: value.isEmpty ? null : value,
          hint: const Text('Elegí una unidad…',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
          items: patentes
              .map((p) => DropdownMenuItem<String>(
                    value: p,
                    child: Text(p,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            letterSpacing: 0.5,
                            fontWeight: FontWeight.w600)),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v ?? ''),
        );
      },
    );
  }
}

/// Dropdown de choferes (rol CHOFER o legacy USUARIO, ACTIVO=true).
/// Sin filtrar por ACTIVO=false porque la auditoría puede interesar
/// choferes que se fueron — su historial sigue siendo válido.
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
        // Lista (dni, nombre) ordenada por nombre ASC para el dropdown.
        // No filtramos por ACTIVO: choferes inactivos tienen historial
        // y la auditoría puede necesitarlo.
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

        return DropdownButtonFormField<String>(
          isDense: true,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Chofer',
            border: OutlineInputBorder(),
            isDense: true,
            prefixIcon: Icon(Icons.person_outline, color: Colors.white54),
          ),
          style: const TextStyle(color: Colors.white, fontSize: 14),
          dropdownColor: AppColors.surface2,
          initialValue: value.isEmpty ? null : value,
          hint: const Text('Elegí un chofer…',
              style: TextStyle(color: Colors.white54, fontSize: 14)),
          // menuMaxHeight para que en mobile con muchos choferes el menú
          // no ocupe toda la pantalla — queda scrolleable.
          menuMaxHeight: 400,
          items: choferes
              .map((c) => DropdownMenuItem<String>(
                    value: c.dni,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.nombre,
                            style: TextStyle(
                              color: c.activo
                                  ? Colors.white
                                  : Colors.white54,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (!c.activo) ...[
                          const SizedBox(width: 6),
                          Text(
                            '(inactivo)',
                            style: AppType.label.copyWith(
                              color: AppColors.warning,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ))
              .toList(),
          onChanged: (v) => onChanged(v ?? ''),
        );
      },
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
// RESULTADO TAB 1: chofer asignado a la patente en la fecha
// ============================================================================

class _ResultadoAsignacion extends StatelessWidget {
  final String patente;
  final DateTime fecha;
  const _ResultadoAsignacion({required this.patente, required this.fecha});

  @override
  Widget build(BuildContext context) {
    // Traemos TODAS las asignaciones de la patente (suelen ser pocas
    // por unidad). Filtrar `desde <= fecha && hasta >= fecha` en
    // Firestore requeriría index compuesto y dos rangos (no se puede
    // en una sola query). Lo hacemos en memoria — la cardinalidad
    // por patente es chica.
    final stream = FirebaseFirestore.instance
        .collection(AppCollections.asignacionesVehiculo)
        .where('vehiculo_id', isEqualTo: patente)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const AppSkeletonList(count: 1, conAvatar: true);
        }
        if (snap.hasError) {
          return AppErrorState(
              title: 'Error', subtitle: snap.error.toString());
        }
        final asignaciones = (snap.data?.docs ?? [])
            .map(AsignacionVehiculo.fromDoc)
            .where((a) => _activaEn(a, fecha))
            .toList();

        if (asignaciones.isEmpty) {
          return const _Placeholder(
            icono: Icons.person_off_outlined,
            titulo: 'Sin chofer asignado',
            subtitulo:
                'No hay registros de asignación a esta unidad para la fecha '
                'seleccionada. Puede que la unidad estuviera libre o '
                'que falte cargar el alta.',
          );
        }

        // Caso normal: 1 asignación matching. Caso raro (overlap): mostramos
        // todas para que el admin las vea.
        return Column(
          children: asignaciones
              .map((a) => _AsignacionCardPorUnidad(asignacion: a))
              .toList(),
        );
      },
    );
  }

  bool _activaEn(AsignacionVehiculo a, DateTime fecha) {
    if (a.desde.isAfter(fecha)) return false;
    if (a.hasta == null) return true;
    return !a.hasta!.isBefore(fecha);
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
          ],
        );
      },
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
