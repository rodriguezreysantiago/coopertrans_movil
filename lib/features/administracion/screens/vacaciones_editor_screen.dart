// lib/features/administracion/screens/vacaciones_editor_screen.dart
//
// Editor de vacaciones de UN empleado/año (paso 4b). Permite:
//   - fijar los días que corresponden, con SUGERENCIA automática por
//     antigüedad (LCT) calculada desde la fecha de ingreso del legajo;
//   - cargar / editar / quitar períodos de goce (date pickers);
//   - ver corresponden / tomados / restan en vivo;
//   - guardar (o borrar el registro del año).
//
// No duplica datos: nombre/empresa/área/ingreso llegan por parámetro (los
// resolvió la tabla desde EMPLEADOS). El doc guarda solo lo de vacaciones.

import 'package:flutter/material.dart';

import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/vacacion.dart';
import '../services/vacaciones_calculo.dart';
import '../services/vacaciones_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

/// Período en edición (mutable; al guardar se vuelca a PeriodoVacaciones).
class _PeriodoEdit {
  DateTime inicio;
  DateTime fin;
  _PeriodoEdit(this.inicio, this.fin);
  int get dias {
    final d = fin.difference(inicio).inDays + 1;
    return d < 0 ? 0 : d;
  }
}

class VacacionEditorScreen extends StatefulWidget {
  final String dni;
  final String nombre;
  final String empresa;
  final String area;
  final DateTime? fechaIngreso;
  final int anio;
  final Vacacion? inicial;

  const VacacionEditorScreen({
    super.key,
    required this.dni,
    required this.nombre,
    required this.empresa,
    required this.area,
    required this.fechaIngreso,
    required this.anio,
    required this.inicial,
  });

  @override
  State<VacacionEditorScreen> createState() => _VacacionEditorScreenState();
}

class _VacacionEditorScreenState extends State<VacacionEditorScreen> {
  final _svc = VacacionesService();
  late int _dias;
  late bool _diasAuto;
  late final List<_PeriodoEdit> _periodos;
  late final TextEditingController _diasCtrl;
  bool _guardando = false;

  DiasVacaciones? get _sugerido => widget.fechaIngreso == null
      ? null
      : calcularDiasVacacionesLct(
          ingreso: widget.fechaIngreso!, anio: widget.anio);

  @override
  void initState() {
    super.initState();
    final ini = widget.inicial;
    // Si no hay registro previo y tenemos sugerencia, arrancamos con ella.
    _dias = ini?.diasCorresponden ?? _sugerido?.dias ?? 0;
    _diasAuto = ini?.diasAuto ?? true;
    _periodos = (ini?.periodos ?? const [])
        .map((p) => _PeriodoEdit(p.inicio, p.fin))
        .toList();
    _diasCtrl = TextEditingController(text: '$_dias');
  }

  @override
  void dispose() {
    _diasCtrl.dispose();
    super.dispose();
  }

  int get _tomados => _periodos.fold(0, (a, p) => a + p.dias);
  int get _restan => _dias - _tomados;

  bool get _haySolapados {
    for (var i = 0; i < _periodos.length; i++) {
      for (var j = i + 1; j < _periodos.length; j++) {
        final a = _periodos[i], b = _periodos[j];
        if (!a.inicio.isAfter(b.fin) && !b.inicio.isAfter(a.fin)) return true;
      }
    }
    return false;
  }

  Future<DateTime?> _pickFecha(DateTime inicial) {
    return showDatePicker(
      context: context,
      initialDate: inicial,
      firstDate: DateTime(widget.anio, 1, 1),
      lastDate: DateTime(widget.anio + 2, 12, 31),
      locale: const Locale('es', 'AR'),
      helpText: 'Elegí la fecha',
    );
  }

  void _agregarPeriodo() {
    // Default sensato: enero del año siguiente (como suele cargarse), 7 días.
    final base = _periodos.isEmpty
        ? DateTime(widget.anio + 1, 1, 5)
        : _periodos.last.fin.add(const Duration(days: 30));
    setState(() => _periodos.add(_PeriodoEdit(base, base.add(const Duration(days: 6)))));
  }

  Future<void> _guardar() async {
    // Validar fin >= inicio.
    for (final p in _periodos) {
      if (p.fin.isBefore(p.inicio)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Un período tiene el fin antes del inicio.')));
        return;
      }
    }
    // Aviso si quedan días negativos (cargó más de lo que corresponde).
    if (_restan < 0) {
      final seguir = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Días en negativo'),
          content: Text(
              'Los períodos suman $_tomados días, más que los $_dias que '
              'corresponden (quedan $_restan). ¿Guardar igual?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Revisar')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Guardar igual')),
          ],
        ),
      );
      if (seguir != true) return;
    }

    setState(() => _guardando = true);
    try {
      final v = Vacacion(
        dni: widget.dni,
        anio: widget.anio,
        diasCorresponden: _dias,
        diasAuto: _diasAuto,
        periodos:
            _periodos.map((p) => PeriodoVacaciones(inicio: p.inicio, fin: p.fin)).toList(),
      );
      await _svc.guardar(v, actualizadoPorDni: PrefsService.dni);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Vacaciones de ${widget.nombre} guardadas.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo guardar: $e')));
    }
  }

  Future<void> _borrar() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Borrar registro'),
        content: Text(
            'Vas a borrar las vacaciones ${widget.anio} de ${widget.nombre}. '
            '¿Confirmás?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _guardando = true);
    try {
      await _svc.eliminar(widget.dni, widget.anio);
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _guardando = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo borrar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sug = _sugerido;
    final sub = [
      if (widget.empresa.isNotEmpty) widget.empresa,
      if (widget.area.isNotEmpty) _capitalizar(widget.area),
      'Año ${widget.anio}',
    ].join(' · ');

    return AppScaffold(
      title: 'Vacaciones',
      actions: [
        if (widget.inicial != null)
          IconButton(
            tooltip: 'Borrar registro',
            icon: const Icon(Icons.delete_outline),
            onPressed: _guardando ? null : _borrar,
          ),
      ],
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              // ── Encabezado ──
              Text(widget.nombre, style: AppType.h4.copyWith(color: c.text)),
              const SizedBox(height: 2),
              Text(sub, style: AppType.monoSm.copyWith(color: c.textMuted)),
              if (widget.fechaIngreso != null) ...[
                const SizedBox(height: 2),
                Text('Ingreso: ${_fecha(widget.fechaIngreso!)}',
                    style: AppType.monoSm.copyWith(color: c.textMuted)),
              ],
              const SizedBox(height: AppSpacing.lg),

              // ── Días que corresponden ──
              AppCard(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const AppEyebrow('Días que corresponden'),
                    const SizedBox(height: AppSpacing.sm),
                    Row(
                      children: [
                        SizedBox(
                          width: 90,
                          child: TextField(
                            controller: _diasCtrl,
                            keyboardType: TextInputType.number,
                            style: AppType.h4.copyWith(color: c.text),
                            decoration: InputDecoration(
                              isDense: true,
                              filled: true,
                              fillColor: c.surface3,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            onChanged: (txt) {
                              final n = int.tryParse(txt.trim());
                              setState(() {
                                _dias = n ?? 0;
                                // Tocar el campo = override manual.
                                _diasAuto = false;
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Text('días', style: AppType.bodySm.copyWith(color: c.textMuted)),
                        const Spacer(),
                        Text(_diasAuto ? 'automático' : 'manual',
                            style: AppType.monoSm.copyWith(
                                color: _diasAuto ? AppColors.success : c.textMuted)),
                      ],
                    ),
                    if (sug != null) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Icon(Icons.auto_awesome_outlined, size: 14, color: c.brand),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('Sugerido: ${sug.dias} (${sug.detalle})',
                                style: AppType.monoSm.copyWith(color: c.textSecondary),
                                maxLines: 2, overflow: TextOverflow.ellipsis),
                          ),
                          if (_dias != sug.dias || !_diasAuto)
                            TextButton(
                              onPressed: () => setState(() {
                                _dias = sug.dias;
                                _diasAuto = true;
                                _diasCtrl.text = '${sug.dias}';
                              }),
                              child: const Text('Usar'),
                            ),
                        ],
                      ),
                      if (sug.esProporcional)
                        Text('Es proporcional de primer año — verificá el número.',
                            style: AppType.monoSm.copyWith(color: AppColors.warning)),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.md),

              // ── Resumen en vivo ──
              Row(
                children: [
                  _Resumen('Corresponden', _dias, c.brand),
                  const SizedBox(width: AppSpacing.sm),
                  _Resumen('Tomados', _tomados, c.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  _Resumen('Restan', _restan,
                      _restan < 0 ? AppColors.error : (_restan == 0 ? c.textMuted : AppColors.success)),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),

              // ── Períodos ──
              Row(
                children: [
                  Text('PERÍODOS',
                      style: AppType.eyebrow.copyWith(
                          color: AppColors.success, letterSpacing: 1.2)),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _agregarPeriodo,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Agregar'),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xs),
              if (_periodos.isEmpty)
                Text('Sin períodos. Agregá uno con el botón de arriba.',
                    style: AppType.bodySm.copyWith(color: c.textMuted))
              else
                ...List.generate(_periodos.length, (i) => _filaPeriodo(i)),
              if (_haySolapados) ...[
                const SizedBox(height: AppSpacing.sm),
                Row(children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 15, color: AppColors.error),
                  const SizedBox(width: 6),
                  Text('Hay períodos solapados',
                      style: AppType.monoSm.copyWith(color: AppColors.error)),
                ]),
              ],
              const SizedBox(height: AppSpacing.xl),

              AppButton(
                label: 'Guardar',
                icon: Icons.check,
                expand: true,
                loading: _guardando,
                onPressed: _guardando ? null : _guardar,
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filaPeriodo(int i) {
    final c = context.colors;
    final p = _periodos[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: AppCard(
        tier: 1,
        padding: const EdgeInsets.all(AppSpacing.sm),
        child: Row(
          children: [
            Expanded(
              child: _ChipFecha(
                label: 'Inicio',
                fecha: p.inicio,
                onTap: () async {
                  final d = await _pickFecha(p.inicio);
                  if (d != null) {
                    setState(() {
                      p.inicio = d;
                      if (p.fin.isBefore(d)) p.fin = d;
                    });
                  }
                },
              ),
            ),
            Icon(Icons.arrow_forward, size: 14, color: c.textMuted),
            Expanded(
              child: _ChipFecha(
                label: 'Fin',
                fecha: p.fin,
                onTap: () async {
                  final d = await _pickFecha(p.fin.isBefore(p.inicio) ? p.inicio : p.fin);
                  if (d != null) setState(() => p.fin = d);
                },
              ),
            ),
            SizedBox(
              width: 52,
              child: Text('${p.dias}d',
                  textAlign: TextAlign.center,
                  style: AppType.h5.copyWith(color: c.text)),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.close, size: 18, color: c.textMuted),
              onPressed: () => setState(() => _periodos.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipFecha extends StatelessWidget {
  final String label;
  final DateTime fecha;
  final VoidCallback onTap;
  const _ChipFecha({required this.label, required this.fecha, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label.toUpperCase(),
                style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 9)),
            const SizedBox(height: 2),
            Text(_fecha(fecha),
                style: AppType.bodySm.copyWith(color: c.text),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

class _Resumen extends StatelessWidget {
  final String label;
  final int valor;
  final Color color;
  const _Resumen(this.label, this.valor, this.color);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: c.surface3,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          children: [
            Text('$valor',
                style: AppType.h4.copyWith(color: color, fontWeight: FontWeight.bold)),
            Text(label.toUpperCase(),
                style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 9),
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

String _capitalizar(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();

String _fecha(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}-${d.month.toString().padLeft(2, '0')}-${d.year}';
