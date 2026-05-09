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
import '../widgets/vencimiento_item_card.dart';

/// Vista calendario de TODOS los vencimientos (personal + flota).
///
/// Diferencia con las pantallas de auditoría existentes:
/// - Las auditorías muestran lista plana ordenada por urgencia (≤60 días).
/// - Acá vemos un calendario mensual con dots por día. El admin agarra el
///   ritmo del mes a primera vista y puede planear sin scrollear listas.
///
/// Tap en un día con vencimientos abre la lista de ese día abajo del
/// calendario; tap en un item abre el [VencimientoEditorSheet] como en
/// las otras auditorías.
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
  /// día. Si todos están bien (>30 días), gris suave. Si alguno está
  /// próximo (≤7 días) o vencido, rojo. Si hay alguno entre 8-30,
  /// naranja.
  Color _colorPorUrgencia(List<VencimientoItem> items) {
    int minDias = 999;
    for (final it in items) {
      final d = it.dias;
      // En el calendario los items con fecha inválida no llegan acá
      // (tryParseFecha los descarta arriba), pero el tipo es int? así
      // que filtramos defensivamente.
      if (d != null && d < minDias) minDias = d;
    }
    if (minDias <= 7) return AppColors.accentRed;
    if (minDias <= 30) return AppColors.accentOrange;
    return AppColors.accentGreen;
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Calendario de vencimientos',
      body: StreamBuilder<QuerySnapshot>(
        stream: _empleadosStream,
        builder: (ctx, snapEmp) {
          if (snapEmp.hasError) {
            return AppErrorState(subtitle: snapEmp.error.toString());
          }
          if (!snapEmp.hasData) return const AppLoadingState();
          return StreamBuilder<QuerySnapshot>(
            stream: _vehiculosStream,
            builder: (ctx2, snapVeh) {
              if (snapVeh.hasError) {
                return AppErrorState(subtitle: snapVeh.error.toString());
              }
              if (!snapVeh.hasData) return const AppLoadingState();
              final mapa =
                  _construirMapa(snapEmp.data!, snapVeh.data!);
              return _buildContenido(mapa);
            },
          );
        },
      ),
    );
  }

  Widget _buildContenido(Map<DateTime, List<VencimientoItem>> mapa) {
    final selKey = _selectedDay == null
        ? null
        : DateTime(
            _selectedDay!.year, _selectedDay!.month, _selectedDay!.day);
    final eventosDelDia =
        selKey != null ? (mapa[selKey] ?? const <VencimientoItem>[]) : const <VencimientoItem>[];

    return Column(
      children: [
        // Calendario
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: TableCalendar<VencimientoItem>(
            firstDay: DateTime(2024),
            lastDay: DateTime(2030),
            focusedDay: _focusedDay,
            calendarFormat: _format,
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
            selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
            eventLoader: (day) =>
                mapa[DateTime(day.year, day.month, day.day)] ??
                const <VencimientoItem>[],
            onDaySelected: (selected, focused) {
              setState(() {
                _selectedDay = selected;
                _focusedDay = focused;
              });
            },
            onPageChanged: (f) => _focusedDay = f,
            onFormatChanged: (f) => setState(() => _format = f),
            // Estilos consistentes con el resto de la app (oscuro, verde
            // accent para selección).
            calendarStyle: CalendarStyle(
              outsideDaysVisible: false,
              defaultTextStyle: const TextStyle(color: Colors.white70),
              weekendTextStyle:
                  const TextStyle(color: Colors.white54),
              todayDecoration: BoxDecoration(
                color: AppColors.accentGreen.withAlpha(60),
                shape: BoxShape.circle,
              ),
              todayTextStyle: const TextStyle(
                color: AppColors.accentGreen,
                fontWeight: FontWeight.bold,
              ),
              selectedDecoration: const BoxDecoration(
                color: AppColors.accentGreen,
                shape: BoxShape.circle,
              ),
              selectedTextStyle: const TextStyle(
                color: Colors.black,
                fontWeight: FontWeight.bold,
              ),
            ),
            headerStyle: const HeaderStyle(
              titleCentered: true,
              formatButtonShowsNext: false,
              titleTextStyle: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
              leftChevronIcon:
                  Icon(Icons.chevron_left, color: AppColors.accentGreen),
              rightChevronIcon:
                  Icon(Icons.chevron_right, color: AppColors.accentGreen),
            ),
            daysOfWeekStyle: const DaysOfWeekStyle(
              weekdayStyle: TextStyle(
                color: AppColors.accentGreen,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
              weekendStyle: TextStyle(
                color: Colors.white38,
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
            // Marker custom: dot del color de urgencia + contador si
            // hay más de uno.
            calendarBuilders: CalendarBuilders<VencimientoItem>(
              markerBuilder: (ctx, day, items) {
                if (items.isEmpty) return const SizedBox.shrink();
                final color = _colorPorUrgencia(items);
                return Positioned(
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      // Cap visual: con celdas estrechas (375/7 ≈ 53 dp)
                      // un día con >9 vencimientos puede tapar el día
                      // siguiente. "9+" es señal suficiente.
                      items.length > 9 ? '9+' : '${items.length}',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        const Divider(color: Colors.white10, height: 1),
        // Lista del día seleccionado
        Expanded(
          child: eventosDelDia.isEmpty
              ? _ListaVacia(dia: _selectedDay)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
                  itemCount: eventosDelDia.length,
                  itemBuilder: (ctx, idx) => VencimientoItemCard(
                    item: eventosDelDia[idx],
                    onTap: () => VencimientoEditorSheet.show(
                        context, eventosDelDia[idx]),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ListaVacia extends StatelessWidget {
  final DateTime? dia;
  const _ListaVacia({required this.dia});

  @override
  Widget build(BuildContext context) {
    final texto = dia == null
        ? 'Tocá un día para ver los vencimientos'
        : 'Sin vencimientos el ${AppFormatters.formatearFecha(dia!)}';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.event_available,
                size: 56, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              texto,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}
