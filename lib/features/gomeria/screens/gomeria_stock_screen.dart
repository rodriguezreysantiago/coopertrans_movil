import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta.dart';
import '../models/cubierta_modelo.dart';
import '../services/gomeria_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';
/// Stock de cubiertas — la pantalla central de gestión del inventario.
///
/// Presenta TODAS las cubiertas (no solo EN_DEPOSITO). Filtros:
/// - **Estado**: chips arriba (TODAS, DEPÓSITO, INSTALADA, EN_RECAPADO,
///   DESCARTADA). Por default arranca en DEPÓSITO porque es el flujo
///   más común ("¿qué tengo para instalar?"), pero el operador puede
///   ver el universo completo.
/// - **Tipo de uso**: chips abajo (TODAS, DIRECCIÓN, TRACCIÓN).
/// - **Búsqueda**: caja de texto en la AppBar. Filtra por código
///   (CUB-XXXX) o por etiqueta del modelo (marca/medida). Útil cuando
///   un operador busca una cubierta puntual ("¿dónde está la 0042?").
///
/// Tap en un tile → pantalla de detalle de la cubierta (historial
/// completo de instalaciones y recapados).
class GomeriaStockScreen extends StatefulWidget {
  const GomeriaStockScreen({super.key});

  @override
  State<GomeriaStockScreen> createState() => _GomeriaStockScreenState();
}

class _GomeriaStockScreenState extends State<GomeriaStockScreen> {
  final _service = GomeriaService();

  /// Default arranca en EN_DEPOSITO (caso de uso más frecuente). El
  /// operador puede sacar el filtro tappeando "TODAS".
  EstadoCubierta? _estado = EstadoCubierta.enDeposito;
  TipoUsoCubierta? _tipoUso;
  final _busquedaCtrl = TextEditingController();
  String _busqueda = '';

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Stock de cubiertas',
      body: Column(
        children: [
          _BarraBusqueda(
            controller: _busquedaCtrl,
            onChanged: (v) =>
                setState(() => _busqueda = v.trim().toUpperCase()),
          ),
          _FiltrosEstado(
            seleccionado: _estado,
            onChanged: (v) => setState(() => _estado = v),
          ),
          _FiltrosTipoUso(
            seleccionado: _tipoUso,
            onChanged: (v) => setState(() => _tipoUso = v),
          ),
          Expanded(
            child: StreamBuilder<List<Cubierta>>(
              stream: _service.streamCubiertasFiltradas(
                estado: _estado,
                tipoUso: _tipoUso,
              ),
              builder: (ctx, snap) {
                // Error explícito: sin este check el StreamBuilder
                // mostraba CircularProgress eterno si Firestore fallaba
                // (rules, red, índice faltante) y el usuario no entendía
                // qué pasa. Reusamos AppErrorState (helper compartido).
                if (snap.hasError) {
                  return AppErrorState(
                    title: 'No se pudieron cargar las cubiertas',
                    subtitle: snap.error.toString(),
                  );
                }
                if (snap.connectionState == ConnectionState.waiting) {
                  return const AppSkeletonList(count: 8, conAvatar: false);
                }
                final cubiertas = (snap.data ?? const <Cubierta>[]).where(_matchBusqueda).toList()
                  ..sort((a, b) => a.codigo.compareTo(b.codigo));
                if (cubiertas.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Text(
                        _busqueda.isEmpty
                            ? 'No hay cubiertas para este filtro.\nTocá + para agregar una.'
                            : 'No se encontró "$_busqueda".',
                        textAlign: TextAlign.center,
                        style: AppType.body.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    80,
                  ),
                  itemCount: cubiertas.length,
                  separatorBuilder: (_, __) => const SizedBox(height: AppSpacing.sm),
                  itemBuilder: (_, i) => _CubiertaTile(
                    c: cubiertas[i],
                    onTap: () => Navigator.pushNamed(
                      context,
                      AppRoutes.adminGomeriaCubierta,
                      arguments: {'cubiertaId': cubiertas[i].id},
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.info,
        onPressed: () => _abrirAlta(context),
        icon: const Icon(Icons.add),
        label: const Text('Nueva cubierta'),
      ),
    );
  }

  bool _matchBusqueda(Cubierta c) {
    if (_busqueda.isEmpty) return true;
    return c.codigo.toUpperCase().contains(_busqueda) ||
        c.modeloEtiqueta.toUpperCase().contains(_busqueda);
  }

  Future<void> _abrirAlta(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final codigoCreado = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _AltaCubiertaDialog(service: _service),
    );
    if (codigoCreado != null) {
      // El dialog devuelve el código exacto (alta unitaria) o un resumen
      // tipo "CUB-0010 a CUB-0050 (41 cubiertas)" (alta en lote).
      final esLote = codigoCreado.contains('cubiertas)');
      messenger.showSnackBar(SnackBar(
        content: Text(esLote
            ? '✓ $codigoCreado creadas.'
            : '✓ Cubierta $codigoCreado creada.'),
        backgroundColor: AppColors.success,
        duration: const Duration(seconds: 3),
      ));
    }
  }
}

// =============================================================================
// FILTROS / BÚSQUEDA
// =============================================================================

class _BarraBusqueda extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _BarraBusqueda({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textCapitalization: TextCapitalization.characters,
        style: const TextStyle(color: AppColors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          prefixIcon: const Icon(Icons.search,
              color: AppColors.textSecondary, size: 20),
          hintText: 'Buscar por código (CUB-XXXX) o modelo…',
          hintStyle: const TextStyle(
            color: AppColors.textDisabled,
            fontSize: 13,
          ),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear,
                      color: AppColors.textSecondary, size: 18),
                  tooltip: 'Limpiar búsqueda',
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                ),
          filled: true,
          fillColor: AppColors.borderSubtle,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.md - 2,
          ),
        ),
      ),
    );
  }
}

class _FiltrosEstado extends StatelessWidget {
  final EstadoCubierta? seleccionado;
  final ValueChanged<EstadoCubierta?> onChanged;
  const _FiltrosEstado({required this.seleccionado, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: SizedBox(
        height: 32,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _ChipFiltro(
              label: 'TODAS',
              seleccionado: seleccionado == null,
              onTap: () => onChanged(null),
              color: AppColors.brand,
            ),
            const SizedBox(width: 6),
            _ChipFiltro(
              label: 'DEPÓSITO',
              seleccionado: seleccionado == EstadoCubierta.enDeposito,
              onTap: () => onChanged(EstadoCubierta.enDeposito),
              color: AppColors.info,
            ),
            const SizedBox(width: 6),
            _ChipFiltro(
              label: 'INSTALADAS',
              seleccionado: seleccionado == EstadoCubierta.instalada,
              onTap: () => onChanged(EstadoCubierta.instalada),
              color: AppColors.success,
            ),
            const SizedBox(width: 6),
            _ChipFiltro(
              label: 'EN RECAPADO',
              seleccionado: seleccionado == EstadoCubierta.enRecapado,
              onTap: () => onChanged(EstadoCubierta.enRecapado),
              color: AppColors.brandSoft,
            ),
            const SizedBox(width: 6),
            _ChipFiltro(
              label: 'DESCARTADAS',
              seleccionado: seleccionado == EstadoCubierta.descartada,
              onTap: () => onChanged(EstadoCubierta.descartada),
              color: AppColors.error,
            ),
          ],
        ),
      ),
    );
  }
}

class _FiltrosTipoUso extends StatelessWidget {
  final TipoUsoCubierta? seleccionado;
  final ValueChanged<TipoUsoCubierta?> onChanged;
  const _FiltrosTipoUso({required this.seleccionado, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Wrap(
        spacing: 6,
        children: [
          _ChipFiltro(
            label: 'TIPO: TODOS',
            seleccionado: seleccionado == null,
            onTap: () => onChanged(null),
            color: AppColors.info,
          ),
          for (final t in TipoUsoCubierta.values)
            _ChipFiltro(
              label: t.etiqueta.toUpperCase(),
              seleccionado: seleccionado == t,
              onTap: () => onChanged(t),
              color: t == TipoUsoCubierta.direccion
                  ? AppColors.warning
                  : AppColors.info,
            ),
        ],
      ),
    );
  }
}

class _ChipFiltro extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;
  final Color color;

  const _ChipFiltro({
    required this.label,
    required this.seleccionado,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(label),
      selected: seleccionado,
      onSelected: (_) => onTap(),
      selectedColor: color,
      labelStyle: AppType.eyebrow.copyWith(
        color: seleccionado ? Colors.black : AppColors.textPrimary,
        fontWeight: FontWeight.bold,
      ),
      backgroundColor: AppColors.background,
      visualDensity: VisualDensity.compact,
    );
  }
}

// =============================================================================
// TILE
// =============================================================================

class _CubiertaTile extends StatelessWidget {
  final Cubierta c;
  final VoidCallback onTap;
  const _CubiertaTile({required this.c, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final color = c.tipoUso == TipoUsoCubierta.direccion
        ? AppColors.warning
        : AppColors.info;
    return AppCard(
      onTap: onTap,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg - 2,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(color: color),
            ),
            alignment: Alignment.center,
            child: Icon(Icons.tire_repair, color: color),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      c.codigo,
                      style: AppType.heading.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: _colorEstado(c.estado).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                            color: _colorEstado(c.estado), width: 0.7),
                      ),
                      child: Text(
                        c.estado.codigo,
                        style: TextStyle(
                          color: _colorEstado(c.estado),
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  c.modeloEtiqueta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Wrap(
                  spacing: AppSpacing.sm,
                  children: [
                    Text(
                      c.vidas == 1 ? 'Nueva' : '${c.vidas - 1}× recapada',
                      style: AppType.eyebrow.copyWith(color: color),
                    ),
                    if (c.kmAcumulados > 0)
                      Text(
                        '${AppFormatters.formatearMiles(c.kmAcumulados)} km totales',
                        style: AppType.eyebrow
                            .copyWith(color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppColors.textDisabled),
        ],
      ),
    );
  }

  static Color _colorEstado(EstadoCubierta e) {
    switch (e) {
      case EstadoCubierta.enDeposito:
        return AppColors.info;
      case EstadoCubierta.instalada:
        return AppColors.success;
      case EstadoCubierta.enRecapado:
        return AppColors.brandSoft;
      case EstadoCubierta.descartada:
        return AppColors.error;
    }
  }
}

// =============================================================================
// ALTA
// =============================================================================

class _AltaCubiertaDialog extends StatefulWidget {
  final GomeriaService service;
  const _AltaCubiertaDialog({required this.service});

  @override
  State<_AltaCubiertaDialog> createState() => _AltaCubiertaDialogState();
}

class _AltaCubiertaDialogState extends State<_AltaCubiertaDialog> {
  CubiertaModelo? _modeloSel;
  final _obsCtrl = TextEditingController();
  final _precioCtrl = TextEditingController();
  final _cantidadCtrl = TextEditingController(text: '1');
  bool _guardando = false;
  // Progreso del lote (creadas / total). Solo visible si cantidad > 1.
  int _creadas = 0;
  int _total = 0;
  String? _error;

  @override
  void dispose() {
    _obsCtrl.dispose();
    _precioCtrl.dispose();
    _cantidadCtrl.dispose();
    super.dispose();
  }

  int get _cantidadParsed {
    final txt = _cantidadCtrl.text.trim();
    if (txt.isEmpty) return 1;
    final n = int.tryParse(txt);
    return (n == null || n < 1) ? 1 : n;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: const Text('Nueva cubierta'),
      content: SizedBox(
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 380.0),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: FirebaseFirestore.instance
                    .collection(AppCollections.cubiertasModelos)
                    .snapshots(),
                builder: (ctx, snap) {
                  final modelos = (snap.data?.docs ?? const [])
                      .map(CubiertaModelo.fromDoc)
                      .where((m) => m.activo)
                      .toList()
                    ..sort((a, b) {
                      final byMarca = a.marcaNombre.compareTo(b.marcaNombre);
                      return byMarca != 0 ? byMarca : a.modelo.compareTo(b.modelo);
                    });
                  if (modelos.isEmpty) {
                    return const Text(
                      'No hay modelos cargados.\n'
                      'Cargá los modelos antes (Marcas y Modelos → Modelos).',
                      style: TextStyle(color: AppColors.warning),
                    );
                  }
                  return DropdownButtonFormField<CubiertaModelo>(
                    initialValue: _modeloSel,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Modelo'),
                    items: modelos
                        .map((m) => DropdownMenuItem(
                              value: m,
                              child: Text(
                                m.etiqueta,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _modeloSel = v),
                  );
                },
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _cantidadCtrl,
                decoration: const InputDecoration(
                  labelText: 'Cantidad',
                  hintText: '1',
                  helperText:
                      'Para alta en lote: una sola operación crea las N cubiertas idénticas.',
                ),
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _precioCtrl,
                decoration: const InputDecoration(
                  labelText: 'Precio de compra (\$, opcional)',
                  hintText: 'Ej. 850.000',
                  helperText: 'Habilita el cálculo de costo por km.',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [AppFormatters.inputMiles],
              ),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _obsCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Observaciones (opcional)',
                  hintText: 'Ej. Comprada en oferta de mayo 2026',
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'El código (CUB-XXXX) se asigna automáticamente.',
                style: AppType.label.copyWith(color: AppColors.textSecondary),
              ),
              // Barra de progreso del lote: solo visible mientras se
              // crean cubiertas en lote y muestra "X de Y creadas".
              if (_guardando && _total > 1) ...[
                const SizedBox(height: AppSpacing.md),
                LinearProgressIndicator(
                  value: _creadas / _total,
                  minHeight: 6,
                  backgroundColor: AppColors.borderSubtle,
                  valueColor:
                      const AlwaysStoppedAnimation(AppColors.info),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Creando $_creadas de $_total…',
                  style: AppType.label.copyWith(color: AppColors.textSecondary),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md - 2),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.15),
                    border: Border.all(color: AppColors.error),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    _error!,
                    style: AppType.label.copyWith(color: AppColors.error),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: _guardando ? null : () => Navigator.pop(context),
        ),
        AppButton(
          label: _cantidadParsed > 1
              ? 'Crear $_cantidadParsed cubiertas'
              : 'Guardar',
          isLoading: _guardando,
          onPressed: _guardando ? null : _guardar,
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    final modelo = _modeloSel;
    if (modelo == null) {
      setState(() => _error = 'Seleccioná un modelo del dropdown.');
      return;
    }
    final cantidad = _cantidadParsed;
    if (cantidad < 1 || cantidad > 500) {
      setState(() => _error = 'Cantidad inválida (1 a 500).');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
      _creadas = 0;
      _total = cantidad;
    });
    try {
      final ids = await widget.service.crearCubiertasEnLote(
        modeloId: modelo.id,
        cantidad: cantidad,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
        observaciones: _obsCtrl.text.trim().isEmpty ? null : _obsCtrl.text,
        precioCompra:
            AppFormatters.parsearMiles(_precioCtrl.text)?.toDouble(),
        onProgreso: (creadas, total) {
          if (mounted) {
            setState(() {
              _creadas = creadas;
              _total = total;
            });
          }
        },
      );
      // Para devolver el resumen al caller: si fue 1, el código directo;
      // si fue lote, "CUB-XXXX a CUB-YYYY (N cubiertas)".
      String resumen;
      if (ids.length == 1) {
        final snap = await FirebaseFirestore.instance
            .collection(AppCollections.cubiertas)
            .doc(ids.first)
            .get();
        resumen = snap.data()?['codigo']?.toString() ?? ids.first;
      } else {
        final primerSnap = await FirebaseFirestore.instance
            .collection(AppCollections.cubiertas)
            .doc(ids.first)
            .get();
        final ultimoSnap = await FirebaseFirestore.instance
            .collection(AppCollections.cubiertas)
            .doc(ids.last)
            .get();
        final primero =
            primerSnap.data()?['codigo']?.toString() ?? ids.first;
        final ultimo = ultimoSnap.data()?['codigo']?.toString() ?? ids.last;
        resumen = '$primero a $ultimo (${ids.length} cubiertas)';
      }
      if (mounted) Navigator.pop(context, resumen);
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          // Si fallamos a mitad de un lote, indicamos cuántas alcanzaron.
          if (_total > 1 && _creadas > 0) {
            _error =
                'Se crearon $_creadas de $_total y despues fallo. '
                'Reintentá con la cantidad restante.';
          } else {
            _error = 'No se pudo guardar. Probá de nuevo.';
          }
          debugPrint('gomeria_stock guardar error: $e');
        });
      }
    }
  }
}
