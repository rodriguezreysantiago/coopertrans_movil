import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/constants/vencimientos_config.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../widgets/vencimiento_editor_sheet.dart';
import '../widgets/vencimiento_item.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Vista calendario de TODOS los vencimientos (personal + flota), en el
/// sistema de diseño Núcleo.
///
/// Diferencia con las pantallas de auditoría existentes:
/// - Las auditorías muestran lista plana ordenada por urgencia (≤60 días).
/// - Acá vemos un calendario mensual con dots por día (color = urgencia del
///   item más próximo a vencer) + una franja de KPIs arriba. El admin agarra
///   el ritmo del mes a primera vista y puede planear sin scrollear listas.
///
/// Tap en un día abre la lista de ese día (panel lateral en pantalla ancha,
/// abajo del calendario en angosta); tap en un item abre el
/// [VencimientoEditorSheet] como en las otras auditorías.
class AdminVencimientosCalendarioScreen extends StatefulWidget {
  const AdminVencimientosCalendarioScreen({super.key});

  @override
  State<AdminVencimientosCalendarioScreen> createState() =>
      _AdminVencimientosCalendarioScreenState();
}

class _AdminVencimientosCalendarioScreenState
    extends State<AdminVencimientosCalendarioScreen> {
  /// Documentos auditados en EMPLEADOS — replica del listado en
  /// `admin_vencimientos_choferes_screen.dart`. Si en el futuro se
  /// centraliza, conviene mover esto a `vencimientos_config.dart`.

  late final Stream<QuerySnapshot> _empleadosStream;
  late final Stream<QuerySnapshot> _vehiculosStream;

  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  CalendarFormat _format = CalendarFormat.month;

  @override
  void initState() {
    super.initState();
    final db = FirebaseFirestore.instance;
    _empleadosStream = db.collection(AppCollections.empleados).snapshots();
    _vehiculosStream = db.collection(AppCollections.vehiculos).snapshots();
    // Inicializamos con el día de hoy seleccionado: el admin ve los
    // vencimientos de hoy de entrada.
    _selectedDay = DateTime(_focusedDay.year, _focusedDay.month, _focusedDay.day);
  }

  /// Construye el mapa `fecha → lista de items`. Se calcula a partir
  /// de los dos snapshots (empleados + vehículos) y se memoiza por
  /// frame — `table_calendar` llama a `eventLoader` muchísimas veces
  /// renderizando el mes, no queremos recalcular cada vez.
  Map<DateTime, List<VencimientoItem>> _construirMapa(
    QuerySnapshot empleados,
    QuerySnapshot vehiculos,
  ) {
    final map = <DateTime, List<VencimientoItem>>{};

    void agregar(DateTime fecha, VencimientoItem item) {
      final clave = DateTime(fecha.year, fecha.month, fecha.day);
      map.putIfAbsent(clave, () => []).add(item);
    }

    // EMPLEADOS — papeles del chofer (licencia, ART, psicofísico).
    // Solo aplican a CHOFER: admins/supervisores/planta no manejan ni
    // tienen estos vencimientos profesionales — los excluimos para no
    // ensuciar el calendario.
    for (final doc in empleados.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Soft-delete: empleados dados de baja no aparecen en calendario.
      if (!AppActivo.esActivo(data)) continue;
      final rol = AppRoles.normalizar(data['ROL']?.toString());
      if (!AppRoles.tieneVehiculo(rol)) continue;
      final nombre = (data['NOMBRE'] ?? 'Sin nombre').toString();
      final dni = doc.id.trim();

      AppDocsEmpleado.etiquetas.forEach((etiqueta, campoBase) {
        final fechaStr = data['VENCIMIENTO_$campoBase']?.toString();
        if (fechaStr == null || fechaStr.isEmpty) return;
        final fecha = AppFormatters.tryParseFecha(fechaStr);
        if (fecha == null) return;
        final dias = AppFormatters.calcularDiasRestantes(fechaStr);
        agregar(
          fecha,
          VencimientoItem(
            docId: dni,
            coleccion: 'EMPLEADOS',
            titulo: nombre,
            tipoDoc: etiqueta,
            campoBase: campoBase,
            fecha: fechaStr,
            dias: dias,
            urlArchivo: data['ARCHIVO_$campoBase']?.toString(),
            storagePath: 'EMPLEADOS_DOCS',
          ),
        );
      });
    }

    // VEHICULOS — RTO, seguros, extintores, etc. según specs
    for (final doc in vehiculos.docs) {
      final data = doc.data() as Map<String, dynamic>;
      // Soft-delete: vehiculos dados de baja no aparecen en calendario.
      if (!AppActivo.esActivo(data)) continue;
      final tipo = (data['TIPO'] ?? '').toString();
      final patente = doc.id.toUpperCase();
      final specs = AppVencimientos.forTipo(tipo);
      for (final spec in specs) {
        final fechaStr = data[spec.campoFecha]?.toString();
        if (fechaStr == null || fechaStr.isEmpty) continue;
        final fecha = AppFormatters.tryParseFecha(fechaStr);
        if (fecha == null) continue;
        final campoBase = spec.campoFecha.replaceFirst('VENCIMIENTO_', '');
        final dias = AppFormatters.calcularDiasRestantes(fechaStr);
        agregar(
          fecha,
          VencimientoItem(
            docId: patente,
            coleccion: 'VEHICULOS',
            titulo: '${tipo.toUpperCase()} - $patente',
            tipoDoc: spec.etiqueta,
            campoBase: campoBase,
            fecha: fechaStr,
            dias: dias,
            urlArchivo: data[spec.campoArchivo]?.toString(),
            storagePath: 'VEHICULOS_DOCS',
          ),
        );
      }
    }

    return map;
  }

  /// Color del dot según urgencia del item más próximo a vencer en el
  /// día. Si todos están bien (>30 días), verde. Si alguno está
  /// próximo (≤7 días) o vencido, rojo. Si hay alguno entre 8-30,
  /// ámbar.
  Color _colorPorUrgencia(List<VencimientoItem> items) {
    int minDias = 999;
    for (final it in items) {
      final d = it.dias;
      // En el calendario los items con fecha inválida no llegan acá
      // (tryParseFecha los descarta arriba), pero el tipo es int? así
      // que filtramos defensivamente.
      if (d != null && d < minDias) minDias = d;
    }
    if (minDias <= 7) return AppColors.error;
    if (minDias <= 30) return AppColors.warning;
    return AppColors.success;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Calendario de vencimientos',
      body: AppOfflineBanner<QuerySnapshot>(
        stream: _empleadosStream,
        child: StreamBuilder<QuerySnapshot>(
          stream: _empleadosStream,
          builder: (ctx, snapEmp) {
            if (snapEmp.hasError) {
              return AppErrorState(subtitle: snapEmp.error.toString());
            }
            if (!snapEmp.hasData) return const _CalendarioSkeleton();
            return StreamBuilder<QuerySnapshot>(
              stream: _vehiculosStream,
              builder: (ctx2, snapVeh) {
                if (snapVeh.hasError) {
                  return AppErrorState(subtitle: snapVeh.error.toString());
                }
                if (!snapVeh.hasData) return const _CalendarioSkeleton();
                final mapa = _construirMapa(snapEmp.data!, snapVeh.data!);
                return _buildContenido(mapa);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildContenido(Map<DateTime, List<VencimientoItem>> mapa) {
    final selKey = _selectedDay == null
        ? null
        : DateTime(
            _selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final eventosDelDia = selKey != null
        ? (mapa[selKey] ?? const <VencimientoItem>[])
        : const <VencimientoItem>[];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Bento responsive: en pantalla ancha (desktop/tablet) el calendario
        // y la lista del día van lado a lado (span ~8 / ~4). En angosta
        // (móvil) se apilan, con la lista debajo en su propia card.
        final esAncho = constraints.maxWidth >= 820;

        final calendario = _CalendarioCard(
          focusedDay: _focusedDay,
          selectedDay: _selectedDay,
          format: _format,
          mapa: mapa,
          colorPorUrgencia: _colorPorUrgencia,
          onDaySelected: (selected, focused) {
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
          },
          onPageChanged: (f) => _focusedDay = f,
          onFormatChanged: (f) => setState(() => _format = f),
        );

        final listaDia = _ListaDelDia(
          dia: _selectedDay,
          eventos: eventosDelDia,
          colorPorUrgencia: _colorPorUrgencia,
        );

        final children = <Widget>[
          // Header: eyebrow + título.
          const _Header(),
          const SizedBox(height: AppSpacing.lg),
          // Franja de KPIs (span ancho).
          _KpiVencimientos(mapa: mapa),
          const SizedBox(height: AppSpacing.lg),
          // Bento: calendario + lista del día.
          if (esAncho)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 8, child: calendario),
                  const SizedBox(width: AppSpacing.mdDense),
                  Expanded(flex: 4, child: listaDia),
                ],
              ),
            )
          else ...[
            calendario,
            const SizedBox(height: AppSpacing.mdDense),
            listaDia,
          ],
        ];

        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 80),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        );
      },
    );
  }
}

/// Header de la pantalla: eyebrow + título grande.
class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppEyebrow('Personal + flota'),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Calendario de vencimientos',
          style: AppType.h4.copyWith(color: context.colors.text),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// Franja de 5 KPIs (span ancho) derivada del mapa completo de
/// vencimientos. Todos los conteos salen del mismo `mapa` que alimenta
/// el calendario — no es una consulta nueva, es una derivación pura.
///
/// "En revisión" cuenta los trámites pendientes de aprobación, que
/// viven en la colección REVISIONES — esta pantalla no la consulta, así
/// que se muestra como `—` (dato no disponible acá). No se inventa.
class _KpiVencimientos extends StatelessWidget {
  final Map<DateTime, List<VencimientoItem>> mapa;
  const _KpiVencimientos({required this.mapa});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    int total = 0;
    int vencidos = 0;
    int prox7 = 0;
    int prox30 = 0;

    for (final items in mapa.values) {
      for (final it in items) {
        total++;
        final d = it.dias;
        if (d == null) {
          // Fecha presente pero corrupta: la contamos como vencida
          // (es lo más urgente — dato roto que hay que arreglar).
          vencidos++;
          continue;
        }
        if (d < 0) {
          vencidos++;
        } else if (d <= 7) {
          prox7++;
        } else if (d <= 30) {
          prox30++;
        }
      }
    }

    return AppKpiStrip(
      stats: [
        AppStat(label: 'Total', value: '$total'),
        AppStat(
          label: 'Vencidos',
          value: '$vencidos',
          accent: vencidos > 0 ? c.error : c.text,
        ),
        AppStat(
          label: '≤ 7 días',
          value: '$prox7',
          accent: prox7 > 0 ? c.error : c.text,
        ),
        AppStat(
          label: '≤ 30 días',
          value: '$prox30',
          accent: prox30 > 0 ? c.warning : c.text,
        ),
        // En revisión: dato de la colección REVISIONES, no consultada
        // por esta pantalla → `—`.
        const AppStat(label: 'En revisión', value: '—'),
      ],
    );
  }
}

/// Card que envuelve el [TableCalendar] con estilo Núcleo. Los días con
/// vencimientos llevan un [AppDot] del color de su urgencia (rojo
/// vencido/≤7d, ámbar ≤30d, verde al día) + un contador mono si hay más
/// de uno.
class _CalendarioCard extends StatelessWidget {
  final DateTime focusedDay;
  final DateTime? selectedDay;
  final CalendarFormat format;
  final Map<DateTime, List<VencimientoItem>> mapa;
  final Color Function(List<VencimientoItem>) colorPorUrgencia;
  final void Function(DateTime, DateTime) onDaySelected;
  final void Function(DateTime) onPageChanged;
  final void Function(CalendarFormat) onFormatChanged;

  const _CalendarioCard({
    required this.focusedDay,
    required this.selectedDay,
    required this.format,
    required this.mapa,
    required this.colorPorUrgencia,
    required this.onDaySelected,
    required this.onPageChanged,
    required this.onFormatChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return AppCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.md, AppSpacing.lg, AppSpacing.md, AppSpacing.md),
      child: TableCalendar<VencimientoItem>(
        firstDay: DateTime(2024),
        lastDay: DateTime(2030),
        focusedDay: focusedDay,
        calendarFormat: format,
        // Locale español-AR para que día/mes salgan en castellano
        // (Lun, Mar, ... / Enero, Febrero, ...). Requiere que el
        // main.dart haya hecho initializeDateFormatting('es_AR').
        locale: 'es_AR',
        availableCalendarFormats: const {
          CalendarFormat.month: 'Mes',
          CalendarFormat.twoWeeks: '2 sem',
          CalendarFormat.week: 'Sem',
        },
        startingDayOfWeek: StartingDayOfWeek.monday,
        selectedDayPredicate: (d) => isSameDay(d, selectedDay),
        eventLoader: (day) =>
            mapa[DateTime(day.year, day.month, day.day)] ??
            const <VencimientoItem>[],
        onDaySelected: onDaySelected,
        onPageChanged: onPageChanged,
        onFormatChanged: onFormatChanged,
        // Estilos Núcleo: superficie oscura, indigo (brand) como única
        // tinta brillante para hoy/selección.
        calendarStyle: CalendarStyle(
          outsideDaysVisible: false,
          defaultTextStyle: AppType.body.copyWith(color: c.textSecondary),
          weekendTextStyle: AppType.body.copyWith(color: c.textMuted),
          todayDecoration: BoxDecoration(
            color: c.brandGlow,
            shape: BoxShape.circle,
            border: Border.all(color: c.brand),
          ),
          todayTextStyle: AppType.body.copyWith(
            color: c.brand,
            fontWeight: FontWeight.w600,
          ),
          selectedDecoration: BoxDecoration(
            color: c.brand,
            shape: BoxShape.circle,
          ),
          selectedTextStyle: AppType.body.copyWith(
            color: c.brandFg,
            fontWeight: FontWeight.w600,
          ),
        ),
        headerStyle: HeaderStyle(
          titleCentered: true,
          formatButtonShowsNext: false,
          titleTextStyle: AppType.h5.copyWith(color: c.text),
          formatButtonDecoration: BoxDecoration(
            color: c.surface3,
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: c.border),
          ),
          formatButtonTextStyle: AppType.label.copyWith(color: c.textSecondary),
          formatButtonPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          leftChevronIcon: Icon(Icons.chevron_left, color: c.textSecondary),
          rightChevronIcon: Icon(Icons.chevron_right, color: c.textSecondary),
        ),
        daysOfWeekStyle: DaysOfWeekStyle(
          weekdayStyle: AppType.eyebrow.copyWith(color: c.textMuted),
          weekendStyle: AppType.eyebrow.copyWith(color: c.textPlaceholder),
        ),
        calendarBuilders: CalendarBuilders<VencimientoItem>(
          markerBuilder: (ctx, day, items) {
            if (items.isEmpty) return const SizedBox.shrink();
            final color = colorPorUrgencia(items);
            return Positioned(
              bottom: 4,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppDot(color, size: 6),
                  if (items.length > 1) ...[
                    const SizedBox(width: 3),
                    Text(
                      // Cap visual: con celdas estrechas un día con >9
                      // vencimientos puede tapar al vecino. "9+" alcanza.
                      items.length > 9 ? '9+' : '${items.length}',
                      style: AppType.monoSm.copyWith(
                        color: color,
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Panel/card con la lista de vencimientos del día seleccionado. Cada
/// item: AppBadge de urgencia + nombre + fecha en mono. Tap abre el
/// editor.
class _ListaDelDia extends StatelessWidget {
  final DateTime? dia;
  final List<VencimientoItem> eventos;
  final Color Function(List<VencimientoItem>) colorPorUrgencia;

  const _ListaDelDia({
    required this.dia,
    required this.eventos,
    required this.colorPorUrgencia,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fechaTxt =
        dia == null ? '—' : AppFormatters.formatearFecha(dia!);

    return AppCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header de la card: eyebrow (fecha) + contador mono.
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.lg,
                AppSpacing.lg, AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppEyebrow('Día seleccionado'),
                      const SizedBox(height: 2),
                      Text(
                        fechaTxt,
                        style: AppType.mono.copyWith(color: c.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  eventos.isEmpty
                      ? 'sin items'
                      : '${eventos.length} ${eventos.length == 1 ? 'item' : 'items'}',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ],
            ),
          ),
          const AppHairline(),
          // Cuerpo: lista o estado vacío.
          if (eventos.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg, vertical: AppSpacing.xxl),
              child: Column(
                children: [
                  Icon(Icons.event_available_outlined,
                      size: 36, color: c.textMuted),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    dia == null
                        ? 'Tocá un día para ver sus vencimientos'
                        : 'Sin vencimientos este día',
                    textAlign: TextAlign.center,
                    style: AppType.bodySm.copyWith(color: c.textMuted),
                  ),
                ],
              ),
            )
          else
            for (var i = 0; i < eventos.length; i++) ...[
              if (i > 0) const AppHairline(),
              _ItemDelDia(
                item: eventos[i],
                colorPorUrgencia: colorPorUrgencia,
              ),
            ],
        ],
      ),
    );
  }
}

/// Una fila de vencimiento dentro de la lista del día. Badge de urgencia
/// + nombre/tipo + fecha mono. Tap abre el editor (misma acción que las
/// otras auditorías).
class _ItemDelDia extends StatelessWidget {
  final VencimientoItem item;
  final Color Function(List<VencimientoItem>) colorPorUrgencia;

  const _ItemDelDia({required this.item, required this.colorPorUrgencia});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = colorPorUrgencia([item]);
    final dias = item.dias;
    final plazo = dias == null
        ? 'inválida'
        : dias < 0
            ? 'venció ${-dias}d'
            : '${dias}d';

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => VencimientoEditorSheet.show(context, item),
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              AppBadge(text: plazo, color: color, size: AppBadgeSize.sm),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.titulo,
                      style: AppType.body
                          .copyWith(color: c.text, fontWeight: FontWeight.w500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      item.tipoDoc,
                      style: AppType.bodySm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                AppFormatters.formatearFecha(item.fecha),
                style: AppType.mono.copyWith(color: c.textSecondary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton de carga con la forma del contenido: header + franja KPI +
/// bloque del calendario. Se siente más rápido que un spinner centrado.
class _CalendarioSkeleton extends StatelessWidget {
  const _CalendarioSkeleton();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppSkeleton.line(widthFactor: 0.3, height: 10),
          const SizedBox(height: AppSpacing.sm),
          AppSkeleton.line(widthFactor: 0.6, height: 22),
          const SizedBox(height: AppSpacing.lg),
          const AppSkeleton.box(height: 96),
          const SizedBox(height: AppSpacing.lg),
          const AppSkeleton.box(height: 320),
        ],
      ),
    );
  }
}
