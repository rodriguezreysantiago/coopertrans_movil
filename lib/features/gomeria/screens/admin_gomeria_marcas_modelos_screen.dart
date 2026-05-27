import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_marca.dart';
import '../models/cubierta_modelo.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// ABM de marcas y modelos de cubiertas. 2 tabs:
/// - **Marcas**: solo nombre + activo (soft-delete).
/// - **Modelos**: marca + modelo + medida + tipo_uso + km_vida_estimada
///   (nueva y recapada) + recapable + activo.
///
/// Acceso: ADMIN (las reglas Firestore CUBIERTAS_MARCAS / CUBIERTAS_MODELOS
/// requieren `isAdmin()` para escritura — el supervisor solo lee).
class AdminGomeriaMarcasModelosScreen extends StatelessWidget {
  const AdminGomeriaMarcasModelosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: AppScaffold(
        title: 'Marcas y Modelos',
        bottom: TabBar(
          tabs: [
            Tab(text: 'MARCAS'),
            Tab(text: 'MODELOS'),
          ],
          indicatorColor: AppColors.brand,
        ),
        body: TabBarView(
          children: [
            _MarcasTab(),
            _ModelosTab(),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// MARCAS
// =============================================================================

class _MarcasTab extends StatelessWidget {
  const _MarcasTab();

  @override
  Widget build(BuildContext context) {
    final col =
        FirebaseFirestore.instance.collection(AppCollections.cubiertasMarcas);
    return Stack(
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: col.orderBy('nombre').snapshots(),
          builder: (ctx, snap) {
            if (snap.hasError) {
              return AppErrorState(
                title: 'No se pudieron cargar las marcas',
                subtitle: snap.error.toString(),
              );
            }
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final marcas = (snap.data?.docs ?? const [])
                .map(CubiertaMarca.fromDoc)
                .toList();
            if (marcas.isEmpty) {
              return const _Vacio(
                texto: 'No hay marcas cargadas. Tocá + para agregar la primera.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                80,
              ),
              itemCount: marcas.length,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) {
                final m = marcas[i];
                return AppCard(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg - 2,
                    vertical: AppSpacing.md,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.label_outline,
                        color:
                            m.activo ? AppColors.brand : AppColors.textTertiary,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Expanded(
                        child: Text(
                          m.nombre,
                          style: AppType.body.copyWith(
                            color: m.activo
                                ? AppColors.textPrimary
                                : AppColors.textTertiary,
                            fontSize: 15,
                            decoration: m.activo
                                ? TextDecoration.none
                                : TextDecoration.lineThrough,
                          ),
                        ),
                      ),
                      Switch(
                        value: m.activo,
                        onChanged: (v) => col.doc(m.id).update({'activo': v}),
                        activeTrackColor: AppColors.brand,
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        Positioned(
          right: AppSpacing.lg,
          bottom: AppSpacing.lg,
          child: FloatingActionButton.extended(
            heroTag: 'fab_marca',
            backgroundColor: AppColors.brand,
            onPressed: () => _abrirAltaMarca(context),
            icon: const Icon(Icons.add),
            label: const Text('Nueva marca'),
          ),
        ),
      ],
    );
  }

  Future<void> _abrirAltaMarca(BuildContext context) async {
    final controller = TextEditingController();
    final String? result;
    try {
      result = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.background,
          title: const Text('Nueva marca'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nombre de la marca',
              hintText: 'Ej. Bridgestone',
            ),
            textCapitalization: TextCapitalization.words,
          ),
          actions: [
            AppButton.ghost(
              label: 'Cancelar',
              onPressed: () => Navigator.pop(ctx),
            ),
            AppButton(
              label: 'Guardar',
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (result == null || result.isEmpty || !context.mounted) return;
    await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasMarcas)
        .add({'nombre': result, 'activo': true});
  }
}

// =============================================================================
// MODELOS
// =============================================================================

class _ModelosTab extends StatelessWidget {
  const _ModelosTab();

  @override
  Widget build(BuildContext context) {
    final colModelos =
        FirebaseFirestore.instance.collection(AppCollections.cubiertasModelos);
    return Stack(
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: colModelos.orderBy('marca_nombre').snapshots(),
          builder: (ctx, snap) {
            if (snap.hasError) {
              return AppErrorState(
                title: 'No se pudieron cargar los modelos',
                subtitle: snap.error.toString(),
              );
            }
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            final modelos = (snap.data?.docs ?? const [])
                .map(CubiertaModelo.fromDoc)
                .toList();
            if (modelos.isEmpty) {
              return const _Vacio(
                texto:
                    'No hay modelos cargados. Cargá las marcas y después agregá los modelos.',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.md,
                80,
              ),
              itemCount: modelos.length,
              separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
              itemBuilder: (_, i) {
                final m = modelos[i];
                return AppCard(
                  onTap: () => _abrirEdicion(context, m),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg - 2,
                    vertical: AppSpacing.md,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.tire_repair,
                            color: m.activo
                                ? AppColors.brand
                                : AppColors.textTertiary,
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Text(
                              m.etiqueta,
                              style: AppType.body.copyWith(
                                color: m.activo
                                    ? AppColors.textPrimary
                                    : AppColors.textTertiary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Switch(
                            value: m.activo,
                            onChanged: (v) =>
                                colModelos.doc(m.id).update({'activo': v}),
                            activeTrackColor: AppColors.brand,
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: AppSpacing.md,
                        runSpacing: AppSpacing.xs,
                        children: [
                          _Chip(
                            'Vida nueva: ${_kmStr(m.kmVidaEstimadaNueva)}',
                          ),
                          _Chip(
                            'Recapada: ${_kmStr(m.kmVidaEstimadaRecapada)}',
                          ),
                          _Chip(
                            m.recapable ? 'Recapable' : 'No recapable',
                            color: m.recapable
                                ? AppColors.brandSoft
                                : AppColors.textTertiary,
                          ),
                          if (m.presionRecomendadaPsi != null)
                            _Chip('${m.presionRecomendadaPsi} PSI'),
                          if (m.profundidadBandaMinimaMm != null)
                            _Chip(
                                'Banda mín ${m.profundidadBandaMinimaMm} mm'),
                        ],
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
        Positioned(
          right: AppSpacing.lg,
          bottom: AppSpacing.lg,
          child: FloatingActionButton.extended(
            heroTag: 'fab_modelo',
            backgroundColor: AppColors.brand,
            onPressed: () => _abrirAltaModelo(context),
            icon: const Icon(Icons.add),
            label: const Text('Nuevo modelo'),
          ),
        ),
      ],
    );
  }

  String _kmStr(int? km) {
    if (km == null) return '—';
    return '${AppFormatters.formatearMiles(km)} km';
  }

  Future<void> _abrirAltaModelo(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (ctx) => const _AltaModeloDialog(),
    );
  }

  Future<void> _abrirEdicion(BuildContext context, CubiertaModelo m) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (ctx) => _EditarModeloSheet(modelo: m),
    );
  }
}

// =============================================================================
// EDICIÓN INLINE DE MODELO — bottom sheet con campos tappeables
// =============================================================================

/// Bottom sheet de edición de un `CubiertaModelo`. Pattern inline-edit
/// (cada ListTile abre un dialog que persiste un solo campo) — alineado
/// al pattern de Personal/Flota.
class _EditarModeloSheet extends StatelessWidget {
  final CubiertaModelo modelo;
  const _EditarModeloSheet({required this.modelo});

  @override
  Widget build(BuildContext context) {
    final ref = FirebaseFirestore.instance
        .collection(AppCollections.cubiertasModelos)
        .doc(modelo.id);
    Future<void> setCampo(String campo, dynamic valor) async {
      await ref.update({campo: valor});
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppColors.textHint,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.xs,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                const Icon(Icons.tire_repair,
                    color: AppColors.brand),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    modelo.etiqueta,
                    style: AppType.body.copyWith(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                0,
                AppSpacing.sm,
                AppSpacing.xl,
              ),
              children: [
                _campoTexto(
                  context,
                  etiqueta: 'Modelo',
                  valor: modelo.modelo,
                  onSave: (v) => setCampo('modelo', v),
                ),
                _campoTexto(
                  context,
                  etiqueta: 'Medida',
                  valor: modelo.medida,
                  onSave: (v) => setCampo('medida', v),
                ),
                _campoEnum(
                  context,
                  etiqueta: 'Tipo de uso',
                  valorActual: modelo.tipoUso.codigo,
                  opciones: {
                    for (final t in TipoUsoCubierta.values)
                      t.codigo: t.etiqueta,
                  },
                  onSave: (v) => setCampo('tipo_uso', v),
                ),
                _campoMiles(
                  context,
                  etiqueta: 'Vida estimada (nueva)',
                  valor: modelo.kmVidaEstimadaNueva,
                  sufijo: 'km',
                  onSave: (v) => setCampo('km_vida_estimada_nueva', v),
                ),
                _campoMiles(
                  context,
                  etiqueta: 'Vida estimada (recapada)',
                  valor: modelo.kmVidaEstimadaRecapada,
                  sufijo: 'km',
                  onSave: (v) => setCampo('km_vida_estimada_recapada', v),
                ),
                _campoMiles(
                  context,
                  etiqueta: 'Presión recomendada',
                  valor: modelo.presionRecomendadaPsi,
                  sufijo: 'PSI',
                  onSave: (v) => setCampo('presion_recomendada_psi', v),
                ),
                _campoDecimal(
                  context,
                  etiqueta: 'Profundidad mínima de banda',
                  valor: modelo.profundidadBandaMinimaMm,
                  sufijo: 'mm',
                  onSave: (v) =>
                      setCampo('profundidad_banda_minima_mm', v),
                ),
                SwitchListTile(
                  value: modelo.recapable,
                  title: const Text('Recapable',
                      style: TextStyle(color: AppColors.textPrimary)),
                  onChanged: (v) => setCampo('recapable', v),
                  activeTrackColor: AppColors.brand,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ListTile _campoTexto(BuildContext context,
      {required String etiqueta,
      required String valor,
      required Future<void> Function(String) onSave}) {
    return ListTile(
      title: Text(etiqueta,
          style: AppType.label.copyWith(color: AppColors.textSecondary)),
      subtitle: Text(valor.isEmpty ? '—' : valor,
          style: AppType.body.copyWith(color: AppColors.textPrimary)),
      trailing:
          const Icon(Icons.edit, color: AppColors.textDisabled, size: 18),
      onTap: () async {
        final ctrl = TextEditingController(text: valor);
        final String? res;
        try {
          res = await showDialog<String>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.background,
              title: Text(etiqueta),
              content: TextField(controller: ctrl, autofocus: true),
              actions: [
                AppButton.ghost(
                  label: 'Cancelar',
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton(
                  label: 'Guardar',
                  onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                ),
              ],
            ),
          );
        } finally {
          ctrl.dispose();
        }
        if (res != null && res != valor) await onSave(res);
      },
    );
  }

  ListTile _campoMiles(BuildContext context,
      {required String etiqueta,
      required int? valor,
      required String sufijo,
      required Future<void> Function(int?) onSave}) {
    return ListTile(
      title: Text(etiqueta,
          style: AppType.label.copyWith(color: AppColors.textSecondary)),
      subtitle: Text(
          valor == null ? '—' : '${AppFormatters.formatearMiles(valor)} $sufijo',
          style: AppType.body.copyWith(color: AppColors.textPrimary)),
      trailing:
          const Icon(Icons.edit, color: AppColors.textDisabled, size: 18),
      onTap: () async {
        final ctrl = TextEditingController(
            text: valor == null ? '' : AppFormatters.formatearMiles(valor));
        final Object? res;
        try {
          res = await showDialog<Object?>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.background,
              title: Text(etiqueta),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [AppFormatters.inputMiles],
                decoration: InputDecoration(suffixText: sufijo),
              ),
              actions: [
                AppButton.ghost(
                  label: 'Cancelar',
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton.danger(
                  label: 'Borrar',
                  onPressed: () => Navigator.pop(ctx, _Sentinela.borrar),
                ),
                AppButton(
                  label: 'Guardar',
                  onPressed: () => Navigator.pop(
                      ctx, AppFormatters.parsearMiles(ctrl.text)),
                ),
              ],
            ),
          );
        } finally {
          ctrl.dispose();
        }
        if (res == _Sentinela.borrar) {
          await onSave(null);
        } else if (res is int && res != valor) {
          await onSave(res);
        }
      },
    );
  }

  ListTile _campoDecimal(BuildContext context,
      {required String etiqueta,
      required double? valor,
      required String sufijo,
      required Future<void> Function(double?) onSave}) {
    return ListTile(
      title: Text(etiqueta,
          style: AppType.label.copyWith(color: AppColors.textSecondary)),
      subtitle: Text(valor == null ? '—' : '$valor $sufijo',
          style: AppType.body.copyWith(color: AppColors.textPrimary)),
      trailing:
          const Icon(Icons.edit, color: AppColors.textDisabled, size: 18),
      onTap: () async {
        final ctrl = TextEditingController(
            text: valor == null ? '' : valor.toString());
        final Object? res;
        try {
          res = await showDialog<Object?>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: AppColors.background,
              title: Text(etiqueta),
              content: TextField(
                controller: ctrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(suffixText: sufijo),
              ),
              actions: [
                AppButton.ghost(
                  label: 'Cancelar',
                  onPressed: () => Navigator.pop(ctx),
                ),
                AppButton.danger(
                  label: 'Borrar',
                  onPressed: () => Navigator.pop(ctx, _Sentinela.borrar),
                ),
                AppButton(
                  label: 'Guardar',
                  onPressed: () => Navigator.pop(
                      ctx,
                      double.tryParse(
                          ctrl.text.trim().replaceAll(',', '.'))),
                ),
              ],
            ),
          );
        } finally {
          ctrl.dispose();
        }
        if (res == _Sentinela.borrar) {
          await onSave(null);
        } else if (res is double && res != valor) {
          await onSave(res);
        }
      },
    );
  }

  ListTile _campoEnum(BuildContext context,
      {required String etiqueta,
      required String valorActual,
      required Map<String, String> opciones,
      required Future<void> Function(String) onSave}) {
    return ListTile(
      title: Text(etiqueta,
          style: AppType.label.copyWith(color: AppColors.textSecondary)),
      subtitle: Text(opciones[valorActual] ?? valorActual,
          style: AppType.body.copyWith(color: AppColors.textPrimary)),
      trailing:
          const Icon(Icons.edit, color: AppColors.textDisabled, size: 18),
      onTap: () async {
        final res = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            backgroundColor: AppColors.background,
            title: Text(etiqueta),
            children: [
              for (final e in opciones.entries)
                SimpleDialogOption(
                  child: Text(e.value,
                      style: TextStyle(
                        color: e.key == valorActual
                            ? AppColors.brand
                            : AppColors.textPrimary,
                      )),
                  onPressed: () => Navigator.pop(ctx, e.key),
                ),
            ],
          ),
        );
        if (res != null && res != valorActual) await onSave(res);
      },
    );
  }
}

/// Sentinela para distinguir "borrar" vs "cancelar" vs "valor vacío" en
/// los dialogs de edición de campos numéricos.
enum _Sentinela { borrar }

class _AltaModeloDialog extends StatefulWidget {
  const _AltaModeloDialog();

  @override
  State<_AltaModeloDialog> createState() => _AltaModeloDialogState();
}

class _AltaModeloDialogState extends State<_AltaModeloDialog> {
  final _modeloCtrl = TextEditingController();
  final _medidaCtrl = TextEditingController();
  final _kmNuevaCtrl = TextEditingController();
  final _kmRecapadaCtrl = TextEditingController();

  CubiertaMarca? _marcaSeleccionada;
  TipoUsoCubierta _tipoUso = TipoUsoCubierta.traccion;
  bool _recapable = true;
  bool _guardando = false;
  final _presionCtrl = TextEditingController();
  final _profundidadCtrl = TextEditingController();

  @override
  void dispose() {
    _modeloCtrl.dispose();
    _medidaCtrl.dispose();
    _kmNuevaCtrl.dispose();
    _kmRecapadaCtrl.dispose();
    _presionCtrl.dispose();
    _profundidadCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: const Text('Nuevo modelo'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Marca (dropdown desde Firestore).
            // NOTA: filtramos `activo` + ordenamos client-side a
            // propósito. La combinación `where('activo') + orderBy('nombre')`
            // exigiría un índice compuesto en Firestore — sin él la query
            // falla silenciosa y el dropdown queda vacío. Como hay
            // típicamente < 50 marcas, el costo es nulo.
            StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection(AppCollections.cubiertasMarcas)
                  .snapshots(),
              builder: (ctx, snap) {
                final marcas = (snap.data?.docs ?? const [])
                    .map(CubiertaMarca.fromDoc)
                    .where((m) => m.activo)
                    .toList()
                  ..sort((a, b) => a.nombre.compareTo(b.nombre));
                if (marcas.isEmpty) {
                  return const Text(
                    'Cargá primero al menos una marca activa.',
                    style: TextStyle(color: AppColors.warning),
                  );
                }
                return DropdownButtonFormField<CubiertaMarca>(
                  initialValue: _marcaSeleccionada,
                  decoration: const InputDecoration(labelText: 'Marca'),
                  items: marcas
                      .map((m) => DropdownMenuItem(
                            value: m,
                            child: Text(m.nombre),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() => _marcaSeleccionada = v),
                );
              },
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _modeloCtrl,
              decoration: const InputDecoration(
                labelText: 'Modelo',
                hintText: 'Ej. R268, M788',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _medidaCtrl,
              decoration: const InputDecoration(
                labelText: 'Medida',
                hintText: 'Ej. 295/80R22.5',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            DropdownButtonFormField<TipoUsoCubierta>(
              initialValue: _tipoUso,
              decoration: const InputDecoration(labelText: 'Tipo de uso'),
              items: TipoUsoCubierta.values
                  .map((t) => DropdownMenuItem(
                        value: t,
                        child: Text(t.etiqueta),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _tipoUso = v ?? _tipoUso),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _kmNuevaCtrl,
              decoration: const InputDecoration(
                labelText: 'Vida estimada (nueva), km',
                hintText: 'Ej. 120.000',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [AppFormatters.inputMiles],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _kmRecapadaCtrl,
              decoration: const InputDecoration(
                labelText: 'Vida estimada (recapada), km',
                hintText: 'Ej. 60.000 (vacío si no recapa)',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [AppFormatters.inputMiles],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _presionCtrl,
              decoration: const InputDecoration(
                labelText: 'Presión recomendada (PSI, opcional)',
                hintText: 'Ej. 110',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [AppFormatters.inputMiles],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _profundidadCtrl,
              decoration: const InputDecoration(
                labelText: 'Profundidad mínima de banda (mm, opcional)',
                hintText: 'Ej. 3.0',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: AppSpacing.md),
            SwitchListTile(
              value: _recapable,
              title: const Text('Recapable'),
              subtitle: Text(
                'Si está apagado, no se va a poder mandar a recapar.',
                style: AppType.label.copyWith(color: AppColors.textSecondary),
              ),
              onChanged: (v) => setState(() => _recapable = v),
              activeTrackColor: AppColors.brand,
            ),
          ],
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: _guardando ? null : () => Navigator.pop(context),
        ),
        AppButton(
          label: 'Guardar',
          isLoading: _guardando,
          onPressed: _guardando ? null : _guardar,
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    final marca = _marcaSeleccionada;
    final modelo = _modeloCtrl.text.trim();
    final medida = _medidaCtrl.text.trim();
    if (marca == null || modelo.isEmpty || medida.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Marca, modelo y medida son obligatorios.'),
      ));
      return;
    }
    setState(() => _guardando = true);
    final nuevo = CubiertaModelo(
      id: '',
      marcaId: marca.id,
      marcaNombre: marca.nombre,
      modelo: modelo,
      medida: medida,
      tipoUso: _tipoUso,
      kmVidaEstimadaNueva: AppFormatters.parsearMiles(_kmNuevaCtrl.text),
      kmVidaEstimadaRecapada: AppFormatters.parsearMiles(_kmRecapadaCtrl.text),
      recapable: _recapable,
      presionRecomendadaPsi:
          AppFormatters.parsearMiles(_presionCtrl.text),
      profundidadBandaMinimaMm:
          double.tryParse(_profundidadCtrl.text.trim().replaceAll(',', '.')),
      activo: true,
    );
    try {
      await FirebaseFirestore.instance
          .collection(AppCollections.cubiertasModelos)
          .add(nuevo.toMap());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _guardando = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error guardando: $e')));
      }
    }
  }
}

// =============================================================================
// HELPERS
// =============================================================================

class _Vacio extends StatelessWidget {
  final String texto;
  const _Vacio({required this.texto});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Text(
          texto,
          textAlign: TextAlign.center,
          style: AppType.body.copyWith(color: AppColors.textSecondary),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String texto;
  final Color? color;
  const _Chip(this.texto, {this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.info;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(AppRadius.sm / 2),
        border: Border.all(color: c, width: 1),
      ),
      child: Text(
        texto,
        style: AppType.eyebrow.copyWith(color: c, fontWeight: FontWeight.bold),
      ),
    );
  }
}
