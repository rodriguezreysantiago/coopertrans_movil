import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_proveedor.dart';
import '../models/cubierta_recapado.dart';
import '../services/gomeria_service.dart';

/// Pantalla de recapados — tabs:
/// - **EN PROCESO**: cubiertas que están ahora en el proveedor.
/// - **HISTÓRICO**: las últimas 100 ya cerradas.
///
/// FAB: enviar una nueva cubierta a recapar (selecciona del stock +
/// proveedor del catálogo `CUBIERTAS_PROVEEDORES`).
class GomeriaRecapadosScreen extends StatelessWidget {
  const GomeriaRecapadosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = GomeriaService();
    return DefaultTabController(
      length: 2,
      child: AppScaffold(
        title: 'Recapados',
        bottom: const TabBar(
          tabs: [
            Tab(text: 'EN PROCESO'),
            Tab(text: 'HISTÓRICO'),
          ],
          indicatorColor: AppColors.accentTeal,
        ),
        body: TabBarView(
          children: [
            _EnProcesoTab(service: service),
            _HistoricoTab(service: service),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          backgroundColor: AppColors.accentTeal,
          onPressed: () => _abrirEnvio(context, service),
          icon: const Icon(Icons.send_outlined),
          label: const Text('MANDAR A RECAPAR'),
        ),
      ),
    );
  }

  Future<void> _abrirEnvio(BuildContext context, GomeriaService service) async {
    await showDialog(
      context: context,
      builder: (ctx) => _EnviarRecapadoDialog(service: service),
    );
  }
}

// =============================================================================
// TABS
// =============================================================================

class _EnProcesoTab extends StatelessWidget {
  final GomeriaService service;
  const _EnProcesoTab({required this.service});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CubiertaRecapado>>(
      stream: service.streamRecapadosEnProceso(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return AppErrorState(
            title: 'No se pudieron cargar los recapados',
            subtitle: snap.error.toString(),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final recapados = snap.data ?? const <CubiertaRecapado>[];
        if (recapados.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Text(
                'No hay recapados en proceso.\nTocá + para mandar una cubierta a recapar.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 14),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          itemCount: recapados.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _RecapadoTile(
            r: recapados[i],
            onTap: () => _abrirCierre(context, service, recapados[i]),
          ),
        );
      },
    );
  }

  Future<void> _abrirCierre(
      BuildContext context, GomeriaService service, CubiertaRecapado r) async {
    await showDialog(
      context: context,
      builder: (ctx) => _CerrarRecapadoDialog(recapado: r, service: service),
    );
  }
}

class _HistoricoTab extends StatelessWidget {
  final GomeriaService service;
  const _HistoricoTab({required this.service});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CubiertaRecapado>>(
      stream: service.streamRecapadosCerrados(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return AppErrorState(
            title: 'No se pudo cargar el histórico',
            subtitle: snap.error.toString(),
          );
        }
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        final recs = snap.data ?? const <CubiertaRecapado>[];
        if (recs.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(40),
              child: Text(
                'Aún no hay recapados cerrados.',
                style: TextStyle(color: Colors.white60),
              ),
            ),
          );
        }
        // Calculamos totales para mostrar en cabecera de la tab.
        var costoTotal = 0.0;
        var recibidas = 0;
        var descartadas = 0;
        for (final r in recs) {
          if (r.costo != null) costoTotal += r.costo!;
          if (r.resultado == ResultadoRecapado.recibida) {
            recibidas++;
          } else if (r.resultado == ResultadoRecapado.descartadaPorProveedor) {
            descartadas++;
          }
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 80),
          itemCount: recs.length + 1,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) {
            if (i == 0) {
              return _ResumenHistorico(
                total: recs.length,
                recibidas: recibidas,
                descartadas: descartadas,
                costoTotal: costoTotal,
              );
            }
            return _RecapadoTile(r: recs[i - 1], cerrado: true);
          },
        );
      },
    );
  }
}

class _ResumenHistorico extends StatelessWidget {
  final int total;
  final int recibidas;
  final int descartadas;
  final double costoTotal;

  const _ResumenHistorico({
    required this.total,
    required this.recibidas,
    required this.descartadas,
    required this.costoTotal,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ÚLTIMOS RECAPADOS CERRADOS',
            style: TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _stat('Total', '$total', AppColors.accentTeal),
              _stat('Recibidas', '$recibidas', AppColors.success),
              _stat('Descartadas', '$descartadas', AppColors.accentRed),
              if (costoTotal > 0)
                _stat('Costo total',
                    '\$${AppFormatters.formatearMonto(costoTotal)}',
                    Colors.white70),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String valor, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style:
                  const TextStyle(color: Colors.white60, fontSize: 10)),
          const SizedBox(height: 2),
          Text(
            valor,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      );
}

// =============================================================================
// TILE
// =============================================================================

class _RecapadoTile extends StatelessWidget {
  final CubiertaRecapado r;
  final VoidCallback? onTap;
  final bool cerrado;
  const _RecapadoTile({required this.r, this.onTap, this.cerrado = false});

  @override
  Widget build(BuildContext context) {
    final color = !cerrado
        ? AppColors.accentTeal
        : r.resultado == ResultadoRecapado.recibida
            ? AppColors.success
            : AppColors.accentRed;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz_outlined, color: color),
              const SizedBox(width: 8),
              Text(
                r.cubiertaCodigo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: color),
                ),
                child: Text(
                  cerrado
                      ? r.resultado == ResultadoRecapado.recibida
                          ? 'RECIBIDA'
                          : 'DESCARTADA'
                      : '${r.diasEnRecapado()}d',
                  style: TextStyle(
                    color: color,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Proveedor: ${r.proveedor}',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          Text(
            cerrado
                ? '${AppFormatters.formatearFecha(r.fechaEnvio)} → ${AppFormatters.formatearFecha(r.fechaRetorno!)} (${r.diasEnRecapado()} días)'
                : 'Para vida ${r.vidaRecapado} · enviada ${AppFormatters.formatearFecha(r.fechaEnvio)}',
            style: const TextStyle(color: Colors.white60, fontSize: 11),
          ),
          if (r.costo != null) ...[
            const SizedBox(height: 4),
            Text(
              'Costo: \$${AppFormatters.formatearMonto(r.costo)}',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          if (r.notas != null && r.notas!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              r.notas!,
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (!cerrado) ...[
            const SizedBox(height: 6),
            const Text(
              'Tocá para cerrar el recapado al recibir.',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// DIALOG ENVIO — usa catálogo de proveedores con autocomplete extensible
// =============================================================================

class _EnviarRecapadoDialog extends StatefulWidget {
  final GomeriaService service;
  const _EnviarRecapadoDialog({required this.service});

  @override
  State<_EnviarRecapadoDialog> createState() => _EnviarRecapadoDialogState();
}

class _EnviarRecapadoDialogState extends State<_EnviarRecapadoDialog> {
  Cubierta? _cubiertaSel;
  CubiertaProveedor? _proveedorSel;
  final _proveedorNuevoCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();
  bool _agregandoProveedor = false;
  bool _guardando = false;

  @override
  void dispose() {
    _proveedorNuevoCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: const Text('Mandar a recapar'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StreamBuilder<List<Cubierta>>(
                stream: widget.service.streamCubiertasEnDeposito(),
                builder: (ctx, snap) {
                  final todas = snap.data ?? const <Cubierta>[];
                  final candidatas =
                      todas.where((c) => c.puedeRecaparse).toList()
                        ..sort((a, b) => a.codigo.compareTo(b.codigo));
                  if (candidatas.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(8),
                      child: Text(
                        'No hay cubiertas en depósito para recapar.',
                        style: TextStyle(color: Colors.amber),
                      ),
                    );
                  }
                  return DropdownButtonFormField<Cubierta>(
                    initialValue: _cubiertaSel,
                    isExpanded: true,
                    decoration:
                        const InputDecoration(labelText: 'Cubierta'),
                    items: candidatas
                        .map((c) => DropdownMenuItem(
                              value: c,
                              child: Text(
                                '${c.codigo} · ${c.modeloEtiqueta} '
                                '(vida ${c.vidas})',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _cubiertaSel = v),
                  );
                },
              ),
              const SizedBox(height: 12),
              _selectorProveedor(),
              const SizedBox(height: 12),
              TextField(
                controller: _notasCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
          style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accentTeal),
          child: _guardando
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator())
              : const Text('ENVIAR'),
        ),
      ],
    );
  }

  /// Dropdown que muestra los proveedores `activo: true` ordenados, con
  /// opción "Otro / nuevo proveedor…" al final que abre un campo de
  /// texto inline. Al guardar, si está en modo nuevo, crea el doc en
  /// `CUBIERTAS_PROVEEDORES` y usa ese nombre.
  Widget _selectorProveedor() {
    if (_agregandoProveedor) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _proveedorNuevoCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Nombre del nuevo proveedor',
                hintText: 'Ej. Recauchutados Sur',
              ),
            ),
          ),
          IconButton(
            tooltip: 'Volver al selector',
            icon: const Icon(Icons.close, color: Colors.white60),
            onPressed: () => setState(() {
              _agregandoProveedor = false;
              _proveedorNuevoCtrl.clear();
            }),
          ),
        ],
      );
    }
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.cubiertasProveedores)
          .snapshots(),
      builder: (ctx, snap) {
        final proveedores = (snap.data?.docs ?? const [])
            .map(CubiertaProveedor.fromDoc)
            .where((p) => p.activo)
            .toList()
          ..sort((a, b) => a.nombre.compareTo(b.nombre));
        return DropdownButtonFormField<Object?>(
          initialValue: _proveedorSel,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Proveedor'),
          items: [
            for (final p in proveedores)
              DropdownMenuItem(value: p, child: Text(p.nombre)),
            const DropdownMenuItem(
              value: 'NUEVO',
              child: Text(
                '+ Nuevo proveedor…',
                style: TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ],
          onChanged: (v) {
            if (v == 'NUEVO') {
              setState(() => _agregandoProveedor = true);
            } else {
              setState(() => _proveedorSel = v as CubiertaProveedor?);
            }
          },
        );
      },
    );
  }

  Future<void> _guardar() async {
    final c = _cubiertaSel;
    if (c == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Seleccioná una cubierta.')),
      );
      return;
    }
    String? nombreProveedor;
    if (_agregandoProveedor) {
      final nuevo = _proveedorNuevoCtrl.text.trim();
      if (nuevo.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escribí el nombre del nuevo proveedor.')),
        );
        return;
      }
      nombreProveedor = nuevo;
    } else {
      nombreProveedor = _proveedorSel?.nombre;
    }
    if (nombreProveedor == null || nombreProveedor.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Elegí un proveedor.')),
      );
      return;
    }
    setState(() => _guardando = true);
    try {
      // Si es nuevo, lo agregamos al catálogo (idempotente: si ya
      // existe, no lo duplicamos por nombre case-insensitive).
      if (_agregandoProveedor) {
        await _persistirProveedorSiNuevo(nombreProveedor);
      }
      await widget.service.mandarARecapar(
        cubiertaId: c.id,
        proveedor: nombreProveedor,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        notas: _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e, s) {
      setState(() => _guardando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo mandar la cubierta a recapar. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }

  /// Crea un proveedor nuevo si no existe ya con ese nombre exacto
  /// (case-insensitive). Idempotente.
  Future<void> _persistirProveedorSiNuevo(String nombre) async {
    final norm = nombre.trim();
    final existentes = await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasProveedores)
        .get();
    final yaExiste = existentes.docs.any((d) =>
        ((d.data()['nombre'] ?? '') as String).toLowerCase() ==
        norm.toLowerCase());
    if (yaExiste) return;
    await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasProveedores)
        .add({'nombre': norm, 'activo': true});
  }
}

// =============================================================================
// DIALOG CIERRE
// =============================================================================

class _CerrarRecapadoDialog extends StatefulWidget {
  final CubiertaRecapado recapado;
  final GomeriaService service;
  const _CerrarRecapadoDialog({
    required this.recapado,
    required this.service,
  });

  @override
  State<_CerrarRecapadoDialog> createState() => _CerrarRecapadoDialogState();
}

class _CerrarRecapadoDialogState extends State<_CerrarRecapadoDialog> {
  ResultadoRecapado _resultado = ResultadoRecapado.recibida;
  final _costoCtrl = TextEditingController();
  final _notasCtrl = TextEditingController();
  bool _guardando = false;

  @override
  void initState() {
    super.initState();
    _notasCtrl.text = widget.recapado.notas ?? '';
  }

  @override
  void dispose() {
    _costoCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: Text('Cerrar recapado ${widget.recapado.cubiertaCodigo}'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Resultado:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              RadioGroup<ResultadoRecapado>(
                groupValue: _resultado,
                onChanged: (v) => setState(() => _resultado = v!),
                child: const Column(
                  children: [
                    RadioListTile<ResultadoRecapado>(
                      value: ResultadoRecapado.recibida,
                      title: Text('Recibida (vuelve al depósito)'),
                      activeColor: AppColors.success,
                    ),
                    RadioListTile<ResultadoRecapado>(
                      value: ResultadoRecapado.descartadaPorProveedor,
                      title: Text(
                          'Descartada por el proveedor (estructura dañada)'),
                      activeColor: AppColors.accentRed,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _costoCtrl,
                decoration: const InputDecoration(
                  labelText: 'Costo (\$, opcional)',
                  hintText: 'Ej. 45.000',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [AppFormatters.inputMiles],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notasCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _guardando ? null : () => Navigator.pop(context),
          child: const Text('CANCELAR'),
        ),
        ElevatedButton(
          onPressed: _guardando ? null : _guardar,
          child: _guardando
              ? const SizedBox(
                  width: 18, height: 18, child: CircularProgressIndicator())
              : const Text('CERRAR'),
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    setState(() => _guardando = true);
    try {
      await widget.service.recibirDeRecapado(
        recapadoId: widget.recapado.id,
        resultado: _resultado,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        costo: AppFormatters.parsearMiles(_costoCtrl.text)?.toDouble(),
        notas: _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text,
      );
      if (mounted) Navigator.pop(context);
    } catch (e, s) {
      setState(() => _guardando = false);
      if (mounted) {
        AppFeedback.errorTecnicoOn(
          ScaffoldMessenger.of(context),
          usuario: 'No se pudo cerrar el recapado. Probá de nuevo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }
}
