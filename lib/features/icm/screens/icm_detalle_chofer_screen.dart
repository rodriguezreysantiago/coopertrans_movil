import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Detalle ICM individual de un chofer, con el número **oficial de Sitrack**
/// (lo que audita YPF, MÁS BAJO = MEJOR):
///   - Header: nombre + DNI + ICM del mes + severidad.
///   - Comparativa con el mes anterior (¿mejoró o empeoró?).
///   - ICM urbano vs no-urbano (dónde maneja peor).
///   - Desglose de infracciones (altas / medias / leves) + excesos de
///     velocidad + conducción agresiva.
///   - **Detalle de infracciones** (desde `chofer.infracciones`, que el
///     scraper trae con `get_infractions(scopeId)` de Sitrack): tabla
///     con las MISMAS columnas que muestra el modal de Sitrack
///     (vehículo + tipo + fecha + ubicación + vel.permitida + pico +
///     tiempo + puntaje).
///
/// Se llega desde el ranking / reporte / card de inicio con el DNI como
/// argumento de ruta.
///
/// REFACTOR NÚCLEO (jun 2026): re-estilizado SIN tocar la capa de datos.
/// El State (`_future`, `_dni`, `_cargar`, `_buscar`, `_DetalleData`), los
/// reads de `ICM_OFICIAL` + `EMPLEADOS`, `IcmOficialService` y la navegación
/// quedan intactos — sólo se reescribió el árbol de widgets al sistema bento:
/// header con hero number (ICM en `c.text`, severidad → `AppDot`/`AppBadge`),
/// secciones con `AppEyebrow` + grilla de `AppStat`, comparativa y detalle de
/// infracciones en `AppCard(tier:1)` con mono tabular, chips de filtro pill y
/// estados empty/loading/error con los widgets del sistema. La clasificación
/// de severidad NO cambia — sólo se mapea a tokens del tema.
class IcmDetalleChoferScreen extends StatefulWidget {
  const IcmDetalleChoferScreen({super.key});

  @override
  State<IcmDetalleChoferScreen> createState() =>
      _IcmDetalleChoferScreenState();
}

class _IcmDetalleChoferScreenState extends State<IcmDetalleChoferScreen> {
  Future<_DetalleData>? _future;
  String _dni = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null) return; // cargar 1 sola vez
    final args = ModalRoute.of(context)?.settings.arguments;
    _dni = args is String ? args : '';
    if (_dni.isEmpty) return;
    _future = _cargar(_dni);
  }

  Future<_DetalleData> _cargar(String dni) async {
    final db = FirebaseFirestore.instance;
    final idActual = IcmOficialService.periodoId();
    final idAnterior = IcmOficialService.periodoId(offsetMeses: -1);
    final periodos = await Future.wait([
      IcmOficialService.cargarPeriodo(db, idActual),
      IcmOficialService.cargarPeriodo(db, idAnterior),
    ]);
    // Nombre desde EMPLEADOS (por si el doc oficial trae el nombre Sitrack
    // distinto / vacío).
    final empSnap = await db.collection('EMPLEADOS').doc(dni).get();
    final nombreEmp = (empSnap.data()?['NOMBRE'] ?? '').toString().trim();
    return _DetalleData(
      actual: _buscar(periodos[0], dni),
      anterior: _buscar(periodos[1], dni),
      idActual: idActual,
      idAnterior: idAnterior,
      nombreEmpleado: nombreEmp,
    );
  }

  IcmOficialChofer? _buscar(IcmOficialPeriodo? p, String dni) {
    if (p == null || dni.isEmpty) return null;
    for (final c in p.choferes) {
      if (c.dni == dni) return c;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_dni.isEmpty) {
      return const AppScaffold(
        title: 'Detalle ICM',
        body: AppEmptyState(
          icon: Icons.badge_outlined,
          title: 'Sin chofer seleccionado',
          subtitle: 'Vení desde el ranking — el detalle requiere un chofer '
              'seleccionado.',
        ),
      );
    }
    return AppScaffold(
      title: 'Detalle ICM',
      body: FutureBuilder<_DetalleData>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const AppSkeletonList(count: 5);
          }
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudo cargar el detalle',
              subtitle: '${snap.error}',
            );
          }
          final data = snap.data!;
          final c = data.actual ?? data.anterior;
          if (c == null) {
            return AppEmptyState(
              icon: Icons.person_off_outlined,
              title: 'Sin datos del ICM oficial para este chofer',
              subtitle: 'DNI ${AppFormatters.formatearDNI(_dni)}. Puede que no '
                  'haya tenido actividad registrada o que el mes recién '
                  'arranque. Se sincroniza una vez al día desde Sitrack.',
            );
          }
          final nombre = data.nombreEmpleado.isNotEmpty
              ? data.nombreEmpleado
              : (c.nombre.isNotEmpty ? c.nombre : 'DNI $_dni');
          final esActual = data.actual != null;
          return SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  nombre: nombre,
                  dni: _dni,
                  chofer: c,
                  periodoLabel: IcmOficialService.labelPeriodo(
                      esActual ? data.idActual : data.idAnterior),
                  esMesActual: esActual,
                ),
                const SizedBox(height: AppSpacing.md),
                _ComparativaMeses(
                  actual: data.actual,
                  anterior: data.anterior,
                  labelActual:
                      IcmOficialService.labelPeriodo(data.idActual),
                  labelAnterior:
                      IcmOficialService.labelPeriodo(data.idAnterior),
                ),
                const SizedBox(height: AppSpacing.xl),
                const AppEyebrow('ICM por tipo de vía'),
                const SizedBox(height: AppSpacing.sm),
                _StatGrid(
                  cells: [
                    _StatCell(
                      label: 'Urbano',
                      value: c.sinActividad
                          ? '—'
                          : c.icmUrbano.toStringAsFixed(1),
                    ),
                    _StatCell(
                      label: 'No urbano (ruta)',
                      value: c.sinActividad
                          ? '—'
                          : c.icmNoUrbano.toStringAsFixed(1),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                const AppEyebrow('Recorrido del período'),
                const SizedBox(height: AppSpacing.sm),
                _StatGrid(
                  cells: [
                    _StatCell(
                      label: 'Distancia',
                      value: AppFormatters.formatearMiles(c.distanciaKm),
                      unit: 'km',
                    ),
                    _StatCell(
                      label: 'Tiempo de manejo',
                      value: c.tiempoH.toStringAsFixed(0),
                      unit: 'h',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                const AppEyebrow('Infracciones'),
                const SizedBox(height: AppSpacing.sm),
                _Infracciones(chofer: c),
                const SizedBox(height: AppSpacing.xl),
                const AppEyebrow('Otros indicadores'),
                const SizedBox(height: AppSpacing.sm),
                _StatGrid(
                  cells: [
                    _StatCell(
                      label: 'Excesos de velocidad',
                      value: '${c.excesosVelocidad}',
                    ),
                    _StatCell(
                      label: 'Conducción agresiva',
                      value: '${c.conduccionAgresiva}',
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xl),
                const AppEyebrow('Detalle de infracciones'),
                const SizedBox(height: AppSpacing.sm),
                _ListaInfracciones(infracciones: c.infracciones),
                const SizedBox(height: AppSpacing.lg),
                const _NotaFuente(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DetalleData {
  final IcmOficialChofer? actual;
  final IcmOficialChofer? anterior;
  final String idActual;
  final String idAnterior;
  final String nombreEmpleado;

  const _DetalleData({
    required this.actual,
    required this.anterior,
    required this.idActual,
    required this.idAnterior,
    required this.nombreEmpleado,
  });
}

/// Color semántico de la severidad oficial Sitrack mapeado a tokens del tema
/// (success/warning/error/textMuted). Reemplaza al `colorSeveridadIcm` de hex
/// Material para respetar la paleta Núcleo. La clasificación NO cambia: usamos
/// el enum de severidad ya calculado por Sitrack, sin inventar umbrales.
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

/// Header del detalle: hero number del ICM (en `c.text`, nunca semántico) +
/// nombre + DNI + badge de severidad. El acento de color vive en el `AppDot`
/// del badge, no en el número.
class _Header extends StatelessWidget {
  final String nombre;
  final String dni;
  final IcmOficialChofer chofer;
  final String periodoLabel;
  final bool esMesActual;

  const _Header({
    required this.nombre,
    required this.dni,
    required this.chofer,
    required this.periodoLabel,
    required this.esMesActual,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _colorSeveridad(context, chofer.severidad);
    final icmStr =
        chofer.sinActividad ? '—' : chofer.icm.toStringAsFixed(1);
    return AppCard(
      tier: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(child: AppEyebrow('ICM oficial · Sitrack')),
              Flexible(
                child: Text(
                  '$periodoLabel${esMesActual ? '' : ' · último con datos'}',
                  textAlign: TextAlign.end,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Hero number + nombre/DNI a la derecha.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                icmStr,
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        nombre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.h5.copyWith(color: c.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'DNI ${AppFormatters.formatearDNI(dni)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.monoSm.copyWith(color: c.textMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AppBadge(
                text: chofer.severidadLabel,
                color: color,
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

/// Comparativa del ICM del chofer entre el mes actual y el anterior.
/// MÁS BAJO = MEJOR → si bajó, mejoró (verde).
class _ComparativaMeses extends StatelessWidget {
  final IcmOficialChofer? actual;
  final IcmOficialChofer? anterior;
  final String labelActual;
  final String labelAnterior;

  const _ComparativaMeses({
    required this.actual,
    required this.anterior,
    required this.labelActual,
    required this.labelAnterior,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (actual == null || anterior == null) {
      return const SizedBox.shrink();
    }
    // ⚠ En el ICM oficial, 0 = "sin infracciones" y 0 = "sin actividad" son
    // indistinguibles numéricamente pero opuestos. Si en alguno de los dos
    // meses no hubo actividad, NO se puede calcular un delta (sino un chofer
    // que no manejó figuraría como "mejoró a 0" — plata mal asignada).
    if (actual!.sinActividad || anterior!.sinActividad) {
      return AppCard(
        tier: 1,
        child: Row(
          children: [
            Icon(Icons.info_outline, color: c.textMuted, size: 18),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                actual!.sinActividad
                    ? 'Sin actividad este mes — no comparable con $labelAnterior.'
                    : 'Sin actividad en $labelAnterior — no hay base de comparación.',
                style: AppType.body.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      );
    }
    final a = actual!.icm;
    final b = anterior!.icm;
    final delta = a - b; // negativo = mejoró
    final mejoro = delta < 0;
    final igual = delta.abs() < 0.05;
    final color = igual ? c.textMuted : (mejoro ? c.success : c.error);
    final icono = igual
        ? Icons.remove
        : (mejoro ? Icons.arrow_downward : Icons.arrow_upward);
    final txt = igual
        ? 'Sin cambios vs $labelAnterior'
        : '${mejoro ? 'Mejoró' : 'Empeoró'} '
            '${delta.abs().toStringAsFixed(1)} pts vs $labelAnterior '
            '(${b.toStringAsFixed(1)})';
    return AppCard(
      tier: 1,
      child: Row(
        children: [
          Icon(icono, color: color, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              txt,
              style: AppType.body.copyWith(
                  color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// Desglose de infracciones por gravedad — grilla de 3 celdas con número en
/// color semántico (rojo/ámbar/verde). Clasificación sin cambios.
class _Infracciones extends StatelessWidget {
  final IcmOficialChofer chofer;
  const _Infracciones({required this.chofer});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _StatGrid(
      cells: [
        _StatCell(
          label: 'Altas',
          value: '${chofer.infAltas}',
          valueColor: c.error,
        ),
        _StatCell(
          label: 'Medias',
          value: '${chofer.infMedias}',
          valueColor: c.warning,
        ),
        _StatCell(
          label: 'Leves',
          value: '${chofer.infLeves}',
          valueColor: c.success,
        ),
      ],
    );
  }
}

/// Grilla de N celdas de stat en bento (cada una `Expanded` → ancho acotado).
///
/// `crossAxisAlignment: stretch` requiere altura finita en el padre. Dentro del
/// SingleChildScrollView del detalle de chofer eso explota porque el SCSV pasa
/// constraints verticales infinitas → "BoxConstraints forces an infinite height"
/// (Sentry FLUTTER-2J, jun 2026). `IntrinsicHeight` le da a la Row el alto del
/// hijo más alto antes de que el stretch lo distribuya — mismo visual, sin assert.
class _StatGrid extends StatelessWidget {
  final List<_StatCell> cells;
  const _StatGrid({required this.cells});

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < cells.length; i++) ...[
            if (i > 0) const SizedBox(width: AppSpacing.sm),
            Expanded(child: cells[i]),
          ],
        ],
      ),
    );
  }
}

/// Celda de stat bento: eyebrow + número héroe (sans, tabular) con unidad mono.
/// El número va en `FittedBox(scaleDown)` para que valores largos (km con
/// miles) no desborden en pantallas chicas (regla anti-overflow Núcleo).
class _StatCell extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;

  /// Color del número. `null` → `c.text` (hero number neutro). Semántico sólo
  /// en stats que lo justifican (conteo de infracciones por gravedad).
  final Color? valueColor;

  const _StatCell({
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.eyebrow.copyWith(color: c.textMuted),
          ),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  value,
                  style: AppType.h4.copyWith(
                    color: valueColor ?? c.text,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 4),
                  Text(unit!,
                      style: AppType.monoSm.copyWith(color: c.textMuted)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lista de infracciones individuales del chofer en el período (de
/// `chofer.infracciones`, embebido en el doc del período por el scraper
/// Python que llama get_infractions(scopeId) de Sitrack). Muestra las
/// MISMAS columnas que el modal de Sitrack — el operador ve lo mismo
/// en la app que en el portal.
///
/// Stateful porque mantiene chips de filtro por tipo de infracción
/// (top 6 más frecuentes) y paginación local (de a 30 con "Mostrar más").
class _ListaInfracciones extends StatefulWidget {
  final List<InfraccionIndividual> infracciones;
  const _ListaInfracciones({required this.infracciones});

  @override
  State<_ListaInfracciones> createState() => _ListaInfraccionesState();
}

class _ListaInfraccionesState extends State<_ListaInfracciones> {
  String? _filtroTipo;
  int _maxVisibles = 30;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lista = widget.infracciones;
    if (lista.isEmpty) {
      return AppCard(
        tier: 1,
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, size: 18, color: c.textMuted),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                'Sin infracciones individuales para este período. El detalle '
                'se sincroniza desde Sitrack una vez al día.',
                style: AppType.body.copyWith(color: c.textSecondary),
              ),
            ),
          ],
        ),
      );
    }

    // Top tipos por cantidad
    final conteoPorTipo = <String, int>{};
    for (final i in lista) {
      conteoPorTipo[i.infraccion] = (conteoPorTipo[i.infraccion] ?? 0) + 1;
    }
    final tiposFrecuentes = conteoPorTipo.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final filtrados = _filtroTipo == null
        ? lista
        : lista.where((i) => i.infraccion == _filtroTipo).toList();
    final visibles = filtrados.take(_maxVisibles).toList();
    final hayMas = filtrados.length > visibles.length;
    final sumaPuntaje = lista.fold<double>(0, (a, b) => a + b.puntaje);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${lista.length} infracción${lista.length == 1 ? "" : "es"} · '
          'suma de puntaje ${sumaPuntaje.toStringAsFixed(2)}',
          style: AppType.monoSm.copyWith(color: c.textSecondary),
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              _ChipFiltro(
                label: 'Todas (${lista.length})',
                selected: _filtroTipo == null,
                onTap: () => setState(() {
                  _filtroTipo = null;
                  _maxVisibles = 30;
                }),
              ),
              for (final t in tiposFrecuentes.take(6))
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _ChipFiltro(
                    label: '${t.key} (${t.value})',
                    selected: _filtroTipo == t.key,
                    onTap: () => setState(() {
                      _filtroTipo = t.key;
                      _maxVisibles = 30;
                    }),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ...visibles.map((i) => _InfraccionCard(infraccion: i)),
        if (hayMas) ...[
          const SizedBox(height: AppSpacing.sm),
          Center(
            child: TextButton.icon(
              onPressed: () => setState(() => _maxVisibles += 50),
              icon: const Icon(Icons.expand_more, size: 18),
              label: Text('Mostrar más '
                  '(${filtrados.length - visibles.length} restantes)'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Pill de filtro por tipo de infracción (mismo look que el chip de período
/// del ranking: activo = relleno `text` sobre `bg`; inactivo = borde hairline).
class _ChipFiltro extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _ChipFiltro({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.text : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: selected ? null : Border.all(color: c.borderStrong),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.label.copyWith(
            color: selected ? c.bg : c.textSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Card de una infracción individual. Mismas columnas que la tabla del
/// modal de Sitrack: tipo + fecha + ubicación + vel.permitida + pico de
/// velocidad + tiempo (si aplica) + puntaje. El puntaje se clasifica con los
/// MISMOS umbrales (>=10 grave, >=5 media, resto leve) → dot/badge semántico.
class _InfraccionCard extends StatelessWidget {
  final InfraccionIndividual infraccion;
  const _InfraccionCard({required this.infraccion});

  /// Color del puntaje (umbrales sin cambios) mapeado a tokens del tema.
  Color _colorPuntaje(BuildContext context) {
    final c = context.colors;
    if (infraccion.puntaje >= 10) return c.error;
    if (infraccion.puntaje >= 5) return c.warning;
    return c.success;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final i = infraccion;
    final color = _colorPuntaje(context);
    return AppCard(
      tier: 1,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Fila 1: tipo + puntaje
          Row(
            children: [
              AppDot(color, size: 7),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  i.infraccion,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.body.copyWith(
                      color: c.text, fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              AppBadge(
                text: i.puntaje.toStringAsFixed(2),
                color: color,
                size: AppBadgeSize.sm,
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          // Fila 2: fecha + patente + tiempo (mono).
          Wrap(
            spacing: AppSpacing.md,
            runSpacing: 4,
            children: [
              _MetaItem(icon: Icons.access_time, texto: i.fecha),
              if (i.patente.isNotEmpty)
                _MetaItem(icon: Icons.local_shipping, texto: i.patente),
              if (i.tiempo != null)
                _MetaItem(icon: Icons.timer, texto: i.tiempo!),
            ],
          ),
          // Fila 3: ubicación
          if (i.ubicacion.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.place, size: 12, color: c.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    i.ubicacion,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ],
          // Fila 4: velocidades (sólo si están). Rojo si es exceso real.
          if (i.velMaxima != null || i.velLimite != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.speed,
                    size: 12,
                    color: i.esExcesoVelocidad ? c.error : c.textMuted),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    i.velLimite != null && i.velMaxima != null
                        ? 'Pico ${i.velMaxima!.toStringAsFixed(0)} km/h '
                            '· límite ${i.velLimite!.toStringAsFixed(0)} km/h'
                        : i.velMaxima != null
                            ? 'Pico ${i.velMaxima!.toStringAsFixed(0)} km/h'
                            : 'Límite ${i.velLimite!.toStringAsFixed(0)} km/h',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(
                      color: i.esExcesoVelocidad ? c.error : c.textSecondary,
                      fontWeight:
                          i.esExcesoVelocidad ? FontWeight.w600 : null,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Ítem de metadato (icono + texto mono) de una infracción. Mismo lenguaje en
/// fecha / patente / tiempo.
class _MetaItem extends StatelessWidget {
  final IconData icon;
  final String texto;
  const _MetaItem({required this.icon, required this.texto});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: c.textMuted),
        const SizedBox(width: AppSpacing.xs),
        Text(
          texto,
          style: AppType.monoSm.copyWith(color: c.textSecondary),
        ),
      ],
    );
  }
}

class _NotaFuente extends StatelessWidget {
  const _NotaFuente();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      'Fuente: tablero ICM oficial de Sitrack (lo que audita YPF). '
      'Escala más baja = mejor. Se actualiza una vez al día. '
      'El detalle de eventos viene del stream /files/reports de Sitrack '
      '(actualizado cada 5 min).',
      style: AppType.monoSm.copyWith(
        color: c.textMuted,
        fontStyle: FontStyle.italic,
        height: 1.5,
      ),
    );
  }
}
