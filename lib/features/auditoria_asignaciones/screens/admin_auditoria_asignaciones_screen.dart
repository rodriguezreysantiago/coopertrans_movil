import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../asignaciones/models/asignacion_vehiculo.dart';

/// "¿Quién manejaba esta unidad este día?"
///
/// REFACTOR 2026-05-27 (decisión Santiago): la pantalla anterior cruzaba
/// `SITRACK_IBUTTONS_HISTORICO` (iButton físico) vs `ASIGNACIONES_VEHICULO`
/// (lo que decía el sistema) para detectar discrepancias. Esa información
/// no la usaba operativamente. Lo que sí necesita Santiago: dada una
/// **unidad** y una **fecha**, saber qué chofer la tenía asignada según
/// el sistema, más el rango (desde / hasta) en que la usó.
///
/// Query: `ASIGNACIONES_VEHICULO where vehiculoId == X` y filtramos
/// en memoria por `desde <= fecha && (hasta == null || hasta >= fecha)`.
/// Normalmente devuelve 1 asignación (no debería haber 2 choferes a la
/// vez en la misma unidad); si devuelve 0, ese día no había nadie
/// asignado a esa unidad.
///
/// La colección iButton queda viva por si en el futuro se reactiva el
/// cruce, pero esta pantalla ya no la usa.
class AdminAuditoriaAsignacionesScreen extends StatefulWidget {
  const AdminAuditoriaAsignacionesScreen({super.key});

  @override
  State<AdminAuditoriaAsignacionesScreen> createState() =>
      _AdminAuditoriaAsignacionesScreenState();
}

class _AdminAuditoriaAsignacionesScreenState
    extends State<AdminAuditoriaAsignacionesScreen> {
  late DateTime _fecha;
  String _patente = '';

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
    return AppScaffold(
      title: 'Chofer por unidad y fecha',
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          const _BannerInfo(),
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
              subtitulo: 'Seleccioná un tractor y la fecha para ver quién lo manejaba.',
            )
          else
            _ResultadoAsignacion(patente: _patente, fecha: _fecha),
        ],
      ),
    );
  }
}

// ============================================================================
// BANNER + selectores
// ============================================================================

class _BannerInfo extends StatelessWidget {
  const _BannerInfo();

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
              'Mostramos qué chofer tenía asignada la unidad elegida en la '
              'fecha que selecciones, según el historial de asignaciones del '
              'sistema. Sirve para multas tardías y reconciliación.',
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

/// Dropdown de patentes (solo TIPO=TRACTOR — las únicas que se asignan
/// a chofer). Stream de VEHICULOS sin filtro de ESTADO porque la auditoría
/// puede interesarse en unidades que hoy estén dadas de baja.
class _DropdownPatente extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _DropdownPatente({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('VEHICULOS')
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
          Text(titulo,
              style: AppType.heading.copyWith(color: Colors.white70)),
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
// RESULTADO: chofer asignado a la patente en la fecha
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
        .collection('ASIGNACIONES_VEHICULO')
        .where('vehiculo_id', isEqualTo: patente)
        .snapshots();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 40),
            child: Center(child: CircularProgressIndicator()),
          );
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
              .map((a) => _AsignacionCard(asignacion: a))
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

class _AsignacionCard extends StatelessWidget {
  final AsignacionVehiculo asignacion;
  const _AsignacionCard({required this.asignacion});

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
                          style: AppType.heading.copyWith(
                              color: Colors.white, fontSize: 17)),
                      Text('DNI ${asignacion.choferDni}',
                          style: AppType.label.copyWith(
                              color: Colors.white54)),
                    ],
                  ),
                ),
                if (esActual)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.success.withValues(alpha: 0.20),
                      borderRadius:
                          BorderRadius.circular(AppRadius.sm),
                      border: Border.all(
                          color: AppColors.success
                              .withValues(alpha: 0.50)),
                    ),
                    child: Text('ACTUAL',
                        style: AppType.eyebrow.copyWith(
                            color: AppColors.success)),
                  ),
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
          width: 120,
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
