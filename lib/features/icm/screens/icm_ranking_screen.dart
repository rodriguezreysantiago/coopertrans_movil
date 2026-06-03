import 'package:coopertrans_movil/shared/constants/app_colors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/choferes_service.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Ranking de choferes según el ICM **oficial de Sitrack** (lo que audita
/// YPF). Escala MÁS BAJO = MEJOR. Se ordena MEJOR arriba (#1 = mejor
/// chofer del período, gamification estilo podio). Los "sin actividad"
/// quedan grises al final. Búsqueda client-side por nombre o DNI.
///
/// Reemplaza el ranking CESVI estimado (que daba números optimistas que no
/// coincidían con el tablero de YPF). Período mensual: mes actual / anterior.
///
/// REFACTOR NÚCLEO (jun 2026): re-estilizado SIN tocar la capa de datos.
/// El estado (`_Periodo`, `_normalizar`, `_ref`, `_cargar`), el FutureBuilder,
/// el orden/posiciones y la navegación al detalle quedan intactos — sólo se
/// reescribió el árbol de widgets al sistema bento: header con hero number
/// (ICM flota en `c.text`, nunca semántico), `AppFilterChip` para el período,
/// `AppInput` para el buscador, filas `AppCard(tier:1)` con `AppDot` semántico
/// + rank/score en `AppType.mono` tabular, y estados empty/loading/error con
/// los widgets del sistema.
class IcmRankingScreen extends StatefulWidget {
  const IcmRankingScreen({super.key});

  @override
  State<IcmRankingScreen> createState() => _IcmRankingScreenState();
}

enum _Periodo { semanaActual, mesActual, mesAnterior }

class _IcmRankingScreenState extends State<IcmRankingScreen> {
  _Periodo _periodo = _Periodo.mesActual;
  Future<IcmOficialPeriodo?>? _future;
  final TextEditingController _busqueda = TextEditingController();
  // El filtro normalizado se cachea para no recomputar lower+trim por cada
  // chofer en cada keystroke.
  String _filtroNorm = '';

  @override
  void initState() {
    super.initState();
    _recargar();
    _busqueda.addListener(() {
      setState(() => _filtroNorm = _normalizar(_busqueda.text));
    });
  }

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  void _recargar() {
    _future = _cargar(_periodo);
  }

  /// Normaliza un string para búsqueda case-insensitive y tolerante a
  /// acentos: "Pérez" → "perez". Sin paquete extra (App. no usa unorm).
  static String _normalizar(String s) {
    const con = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
    const sin = 'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC';
    var out = s.toLowerCase().trim();
    for (var i = 0; i < con.length; i++) {
      out = out.replaceAll(con[i], sin[i]);
    }
    return out;
  }

  /// (id del doc, colección Firestore, label legible) según el período.
  ({String id, String coleccion, String label}) _ref(_Periodo p) {
    switch (p) {
      case _Periodo.semanaActual:
        final id = IcmOficialService.semanaId();
        return (
          id: id,
          coleccion: IcmOficialService.coleccionSemanal,
          label: IcmOficialService.labelSemana(id),
        );
      case _Periodo.mesActual:
        final id = IcmOficialService.periodoId();
        return (
          id: id,
          coleccion: IcmOficialService.coleccion,
          label: IcmOficialService.labelPeriodo(id),
        );
      case _Periodo.mesAnterior:
        final id = IcmOficialService.periodoId(offsetMeses: -1);
        return (
          id: id,
          coleccion: IcmOficialService.coleccion,
          label: IcmOficialService.labelPeriodo(id),
        );
    }
  }

  Future<IcmOficialPeriodo?> _cargar(_Periodo p) async {
    final db = FirebaseFirestore.instance;
    final excluidos = await ExcluidosService.cargar(db: db);
    final dnisChofer = await ChoferesService.cargarDnisChofer(db: db);
    final r = _ref(p);
    return IcmOficialService.cargarPeriodo(
      db,
      r.id,
      coleccionFirestore: r.coleccion,
      // Excluye: (a) tanqueros + testers (ExcluidosService) y (b) DNIs con
      // ROL distinto de CHOFER en EMPLEADOS (Santiago 2026-05-23: PLANTA /
      // ADMIN / etc. no deben aparecer en el ranking ICM). Los totales de
      // cabecera quedan tal cual los reporta Sitrack porque ESE es el
      // número auditado por YPF.
      // Si dnisChofer es null (query falló), NO filtramos por rol —
      // fail-safe: mejor mostrar uno indebido 100ms que vaciar el ranking.
      excluirDni: (dni) =>
          ExcluidosService.esExcluido(excluidos, dni: dni) ||
          (dnisChofer != null && !dnisChofer.contains(dni)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Ranking ICM',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BarraFiltros(
            periodoActual: _periodo,
            onChanged: (p) => setState(() {
              _periodo = p;
              _recargar();
            }),
          ),
          _Buscador(controller: _busqueda),
          Expanded(
            child: FutureBuilder<IcmOficialPeriodo?>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const AppSkeletonList(count: 8);
                }
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudo cargar el ranking',
                    subtitle: '${snap.error}',
                    onRetry: () => setState(_recargar),
                  );
                }
                final periodo = snap.data;
                if (periodo == null || periodo.vacio) {
                  return AppEmptyState(
                    icon: Icons.leaderboard_outlined,
                    title: 'Aún no hay datos del ICM oficial de '
                        '${_ref(_periodo).label}',
                    subtitle:
                        'Se sincroniza una vez al día desde el portal de '
                        'Sitrack. Si recién arranca el período, esperá a la '
                        'próxima madrugada.',
                  );
                }
                // ORDEN: mejor arriba (#1 = mejor chofer del período).
                // Los sin actividad/DNI quedan al final (no compiten).
                final orden = periodo.choferesParaRanking;
                // Posición numerada: solo cuenta a los rankeables (con
                // actividad y DNI). Los grises de abajo van sin posición
                // para no confundir "está en el puesto N" con "no compite".
                final rankeables = periodo.choferesConActividad.length;
                // Filtro por nombre o DNI (normalizado: case-insensitive +
                // sin acentos). Aplicado después del orden para no romper
                // la posición numerada.
                final filas = _filtroNorm.isEmpty
                    ? orden
                    : orden
                        .where((c) =>
                            _normalizar(c.nombre).contains(_filtroNorm) ||
                            c.dni.contains(_filtroNorm))
                        .toList();
                final label = _ref(_periodo).label;
                if (filas.isEmpty) {
                  return ListView(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.lg),
                    children: [
                      _HeaderFlota(periodo: periodo, label: label),
                      const SizedBox(height: AppSpacing.xl),
                      _SinResultados(consulta: _busqueda.text),
                    ],
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.xxl),
                  itemCount: filas.length + 1,
                  itemBuilder: (ctx, i) {
                    if (i == 0) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: AppSpacing.md),
                        child: _HeaderFlota(periodo: periodo, label: label),
                      );
                    }
                    final c = filas[i - 1];
                    // Posición = índice en el orden ORIGINAL (no en el
                    // filtrado), para que filtrar no cambie el #N de un
                    // chofer. Los sin actividad/DNI van sin posición.
                    final esRankeable =
                        !c.sinActividad && c.tieneDni;
                    final posicion = esRankeable ? orden.indexOf(c) + 1 : null;
                    return _FilaChofer(
                      posicion: posicion,
                      totalRankeables: rankeables,
                      chofer: c,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Buscador estilo Núcleo (AppInput con lupa + limpiar).
class _Buscador extends StatelessWidget {
  final TextEditingController controller;
  const _Buscador({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.sm),
      child: AppInput(
        controller: controller,
        hint: 'Buscar por nombre o DNI',
        icon: Icons.search,
        trailingAction: controller.text.isEmpty ? null : 'Limpiar',
        onTrailingTap: controller.clear,
      ),
    );
  }
}

/// Mensaje "sin coincidencias" en estilo bento (no centrado a pantalla
/// completa porque va debajo del header de flota).
class _SinResultados extends StatelessWidget {
  final String consulta;
  const _SinResultados({required this.consulta});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      child: Row(
        children: [
          Icon(Icons.search_off_outlined, size: 20, color: c.textMuted),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Sin coincidencias para "$consulta".',
              style: AppType.body.copyWith(color: c.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// Selector de período — pills Núcleo (AppFilterChip sin contador visible).
class _BarraFiltros extends StatelessWidget {
  final _Periodo periodoActual;
  final ValueChanged<_Periodo> onChanged;

  const _BarraFiltros({required this.periodoActual, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xs),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          _ChipPeriodo(
            label: 'Semana actual',
            activo: periodoActual == _Periodo.semanaActual,
            onTap: () => onChanged(_Periodo.semanaActual),
          ),
          _ChipPeriodo(
            label: 'Mes actual',
            activo: periodoActual == _Periodo.mesActual,
            onTap: () => onChanged(_Periodo.mesActual),
          ),
          _ChipPeriodo(
            label: 'Mes anterior',
            activo: periodoActual == _Periodo.mesAnterior,
            onTap: () => onChanged(_Periodo.mesAnterior),
          ),
        ],
      ),
    );
  }
}

/// Pill de período (mismo look que AppFilterChip pero sin contador, ya que el
/// período no tiene un "n" asociado — es una elección, no un filtro contable).
class _ChipPeriodo extends StatelessWidget {
  final String label;
  final bool activo;
  final VoidCallback onTap;
  const _ChipPeriodo(
      {required this.label, required this.activo, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: activo ? c.text : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: activo ? null : Border.all(color: c.borderStrong),
        ),
        child: Text(
          label,
          style: AppType.label.copyWith(
            color: activo ? c.bg : c.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Cabecera con el ICM de la flota (oficial) + cómo leerlo + distribución.
/// Hero number en `c.text` (nunca semántico en el número) — la lectura
/// semántica vive en los badges de distribución.
class _HeaderFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  final String label;
  const _HeaderFlota({required this.periodo, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final conteo = periodo.conteoPorSeveridad;
    final altos = conteo[SeveridadIcm.alto] ?? 0;
    final medios = conteo[SeveridadIcm.medio] ?? 0;
    final bajos = (conteo[SeveridadIcm.bajo] ?? 0) +
        (conteo[SeveridadIcm.sinInfracciones] ?? 0);
    return AppCard(
      tier: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Eyebrow + label del período (a la derecha).
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: AppEyebrow('ICM flota · oficial Sitrack')),
              Flexible(
                child: Text(
                  label,
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Hero number + sub-línea de contexto (choferes rankeables · km).
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                periodo.icmGeneral.toStringAsFixed(1),
                style: AppType.h1.copyWith(
                  color: c.text,
                  fontSize: 56,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${periodo.choferesConActividad.length} rankeables · '
                    '${AppFormatters.formatearMiles(periodo.distanciaTotalKm)} km',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          // Distribución por severidad (badges semánticos) + "más bajo = mejor".
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppBadge(
                text: 'Alto $altos',
                color: c.error,
                dot: true,
                size: AppBadgeSize.sm,
              ),
              AppBadge(
                text: 'Medio $medios',
                color: c.warning,
                dot: true,
                size: AppBadgeSize.sm,
              ),
              AppBadge(
                text: 'Bajo/Sin $bajos',
                color: c.success,
                dot: true,
                size: AppBadgeSize.sm,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  'más bajo = mejor',
                  style: AppType.monoSm.copyWith(
                    color: c.textMuted,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Fila de un chofer en el ranking — `AppCard(tier:1)` con `AppDot` semántico
/// (verde/ámbar/rojo según severidad Sitrack), rank y score en `AppType.mono`
/// tabular. El borde de cada card hace de hairline entre filas.
class _FilaChofer extends StatelessWidget {
  /// Posición en el ranking (`null` = sin actividad/DNI, no compite).
  final int? posicion;

  /// Cantidad total de choferes rankeables del período (para mostrar
  /// "#3 / 28" — da contexto del podio).
  final int totalRankeables;

  final IcmOficialChofer chofer;

  const _FilaChofer({
    required this.posicion,
    required this.totalRankeables,
    required this.chofer,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Color semántico de la severidad → al dot/score, NUNCA al nombre.
    final color = _colorSeveridad(context, chofer.severidad);
    final icmStr =
        chofer.sinActividad ? '—' : chofer.icm.toStringAsFixed(1);
    final dniStr = chofer.tieneDni
        ? 'DNI ${AppFormatters.formatearDNI(chofer.dni)}'
        : 'Sin chofer identificado';
    final posStr = posicion == null
        ? '—'
        : '#$posicion${totalRankeables > 0 ? ' / $totalRankeables' : ''}';
    // Drill-down disponible solo si hay DNI real (Sitrack a veces tiene
    // unidades sin chofer asignado, esos no entran al detalle).
    final esNavegable = chofer.tieneDni && !chofer.sinActividad;

    return AppCard(
      tier: 1,
      onTap: esNavegable
          ? () => Navigator.pushNamed(
                context,
                AppRoutes.adminIcmDetalleChofer,
                arguments: chofer.dni,
              )
          : null,
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          // Rank + score: bloque mono tabular a la izquierda.
          SizedBox(
            width: 58,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  posStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    AppDot(color, size: 6),
                    const SizedBox(width: 5),
                    Text(
                      icmStr,
                      style: AppType.mono.copyWith(
                        color: c.text,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // Nombre + sub-líneas (DNI · km, severidad/infracciones).
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chofer.nombre.isEmpty ? '(sin nombre)' : chofer.nombre,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                      color: c.text, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 3),
                Text(
                  '$dniStr · ${AppFormatters.formatearMiles(chofer.distanciaKm)} km',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  chofer.sinActividad
                      ? 'Sin actividad en el período'
                      : '${chofer.severidadLabel} · ${chofer.totalInfracciones} '
                          'infracciones (${chofer.infAltas}A · '
                          '${chofer.infMedias}M · ${chofer.infLeves}L)',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: color),
                ),
              ],
            ),
          ),
          if (esNavegable) ...[
            const SizedBox(width: AppSpacing.sm),
            Icon(Icons.chevron_right, size: 18, color: c.textMuted),
          ],
        ],
      ),
    );
  }

  /// Color semántico de la severidad oficial Sitrack mapeado a tokens del
  /// tema (success/warning/error/textMuted). Reemplaza al `colorSeveridadIcm`
  /// de hex Material (`Colors.green.shade600`, etc.) para respetar la paleta
  /// Núcleo. La clasificación NO cambia: usamos el enum de severidad ya
  /// calculado por Sitrack, sin inventar umbrales.
  Color _colorSeveridad(BuildContext context, String severidadRaw) {
    final c = context.colors;
    switch (severidadIcmDesde(severidadRaw)) {
      case SeveridadIcm.sinInfracciones:
      case SeveridadIcm.bajo:
        return c.success;
      case SeveridadIcm.medio:
        return c.warning;
      case SeveridadIcm.alto:
        return c.error;
      case SeveridadIcm.sinActividad:
      case SeveridadIcm.desconocida:
        return c.textMuted;
    }
  }
}
