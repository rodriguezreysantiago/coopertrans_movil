import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../models/empresa_logistica.dart';
import '../services/logistica_service.dart';

/// ABM de empresas con tabs (CLIENTES / DADORES). Cada tipo en una
/// solapa distinta para evitar que el operador se confunda al armar
/// tarifas — un cliente nunca debería figurar en el dropdown de
/// "dador" (tienen lógica distinta) y viceversa.
class LogisticaEmpresasScreen extends StatelessWidget {
  const LogisticaEmpresasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const DefaultTabController(
      length: 2,
      child: AppScaffold(
        title: 'Empresas',
        bottom: TabBar(
          tabs: [
            Tab(text: 'CLIENTES'),
            Tab(text: 'DADORES'),
          ],
          indicatorColor: AppColors.accentBlue,
        ),
        body: TabBarView(
          children: [
            _ListaEmpresas(tipo: TipoEmpresaLogistica.cliente),
            _ListaEmpresas(tipo: TipoEmpresaLogistica.dadorTransporte),
          ],
        ),
      ),
    );
  }
}

class _ListaEmpresas extends StatelessWidget {
  final TipoEmpresaLogistica tipo;
  const _ListaEmpresas({required this.tipo});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        StreamBuilder<List<EmpresaLogistica>>(
          stream: LogisticaService.streamEmpresas(tipo: tipo),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            // Mostrar error real (típico: "requires an index" si falta
            // el índice compuesto en firestore.indexes.json). Sin esto
            // el StreamBuilder mostraría empty state y el operador
            // pensaría que "no se guarda nada" cuando en realidad la
            // query falla en Firestore.
            if (snap.hasError) {
              return AppEmptyState(
                icon: Icons.error_outline,
                title: 'Error cargando la lista',
                subtitle: snap.error.toString(),
              );
            }
            final items = snap.data ?? const [];
            if (items.isEmpty) {
              return AppEmptyState(
                icon: Icons.business_outlined,
                title: tipo == TipoEmpresaLogistica.cliente
                    ? 'Sin clientes cargados'
                    : 'Sin dadores de transporte cargados',
                subtitle: 'Tocá + para agregar el primero',
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (_, i) => _CardEmpresa(empresa: items[i]),
            );
          },
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            heroTag: 'fab_empresa_${tipo.codigo}',
            backgroundColor: AppColors.accentBlue,
            onPressed: () => _abrirAlta(context, tipo),
            icon: const Icon(Icons.add),
            label: Text(
              tipo == TipoEmpresaLogistica.cliente
                  ? 'NUEVO CLIENTE'
                  : 'NUEVO DADOR',
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _abrirAlta(
    BuildContext context,
    TipoEmpresaLogistica tipo,
  ) async {
    await showDialog(
      context: context,
      builder: (_) => _AltaEmpresaDialog(tipo: tipo),
    );
  }
}

class _CardEmpresa extends StatelessWidget {
  final EmpresaLogistica empresa;
  const _CardEmpresa({required this.empresa});

  @override
  Widget build(BuildContext context) {
    final color =
        empresa.activa ? AppColors.accentBlue : Colors.white24;
    return AppCard(
      onTap: () => _abrirEdicion(context),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.business, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      empresa.etiquetaPrincipal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: empresa.activa ? Colors.white : Colors.white38,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        decoration: empresa.activa
                            ? TextDecoration.none
                            : TextDecoration.lineThrough,
                      ),
                    ),
                    if (empresa.etiquetaSecundaria != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        empresa.etiquetaSecundaria!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: empresa.activa
                              ? Colors.white54
                              : Colors.white24,
                          fontSize: 12,
                          decoration: empresa.activa
                              ? TextDecoration.none
                              : TextDecoration.lineThrough,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: empresa.activa,
                onChanged: (v) => LogisticaService.actualizarEmpresa(
                  id: empresa.id,
                  cambios: {'activa': v},
                ),
                activeTrackColor: AppColors.accentBlue,
              ),
            ],
          ),
          if (empresa.cuit != null || empresa.contacto != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (empresa.cuit != null) _Chip('CUIT ${empresa.cuit}'),
                if (empresa.contacto != null) _Chip(empresa.contacto!),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _abrirEdicion(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) => _EditarEmpresaSheet(empresa: empresa),
    );
  }
}

// =============================================================================
// EDICIÓN INLINE — bottom sheet con campos tappeables
// =============================================================================

class _EditarEmpresaSheet extends StatelessWidget {
  final EmpresaLogistica empresa;
  const _EditarEmpresaSheet({required this.empresa});

  @override
  Widget build(BuildContext context) {
    Future<void> setCampo(String campo, dynamic valor) async {
      await LogisticaService.actualizarEmpresa(
        id: empresa.id,
        cambios: {campo: valor},
      );
    }

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (ctx, controller) => Column(
        children: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                const Icon(Icons.business, color: AppColors.accentBlue),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        empresa.etiquetaPrincipal,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (empresa.etiquetaSecundaria != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            empresa.etiquetaSecundaria!,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                DatoEditableTexto(
                  etiqueta: 'Nombre (razón social)',
                  valor: empresa.nombre,
                  onSave: (v) => setCampo('nombre', v),
                ),
                DatoEditableTexto(
                  etiqueta: 'Apodo / nombre comercial (opcional)',
                  valor: empresa.apodo ?? '',
                  // El apodo conserva la grafía como se conoce
                  // comercialmente ("Lartirigoyen", no "LARTIRIGOYEN").
                  // Sin esto el DatoEditableTexto convierte a UPPER
                  // por default, lo que no encaja con un nombre
                  // comercial / de fantasía.
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'apodo',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                DatoEditableEnum(
                  etiqueta: 'Tipo',
                  valorActual: empresa.tipo.codigo,
                  opciones: {
                    for (final t in TipoEmpresaLogistica.values)
                      t.codigo: t.etiqueta,
                  },
                  icono: Icons.category_outlined,
                  onSave: (v) => setCampo('tipo', v),
                ),
                DatoEditableTexto(
                  etiqueta: 'CUIT (opcional)',
                  valor: empresa.cuit ?? '',
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'cuit',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                DatoEditableTexto(
                  etiqueta: 'Contacto (opcional)',
                  valor: empresa.contacto ?? '',
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'contacto',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                const SizedBox(height: 12),
                _BloqueProductos(
                  empresaId: empresa.id,
                  productos: empresa.productos,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// ALTA — dialog corto
// =============================================================================

class _AltaEmpresaDialog extends StatefulWidget {
  final TipoEmpresaLogistica tipo;
  const _AltaEmpresaDialog({required this.tipo});

  @override
  State<_AltaEmpresaDialog> createState() => _AltaEmpresaDialogState();
}

class _AltaEmpresaDialogState extends State<_AltaEmpresaDialog> {
  final _nombreCtrl = TextEditingController();
  final _apodoCtrl = TextEditingController();
  final _cuitCtrl = TextEditingController();
  final _contactoCtrl = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _apodoCtrl.dispose();
    _cuitCtrl.dispose();
    _contactoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.background,
      title: Text(
        widget.tipo == TipoEmpresaLogistica.cliente
            ? 'Nuevo cliente'
            : 'Nuevo dador de transporte',
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _nombreCtrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: 'Nombre / razón social *',
                hintText: 'Ej. ACOPIO LARTIRIGOYEN SRL',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _apodoCtrl,
              decoration: const InputDecoration(
                labelText: 'Apodo / nombre comercial (opcional)',
                hintText: 'Ej. Lartirigoyen',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _cuitCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'CUIT (opcional)',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contactoCtrl,
              decoration: const InputDecoration(
                labelText: 'Contacto (opcional)',
                hintText: 'Tel / email del contacto',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.accentRed),
              ),
            ],
          ],
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
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              : const Text('GUARDAR'),
        ),
      ],
    );
  }

  Future<void> _guardar() async {
    final nombre = _nombreCtrl.text.trim();
    if (nombre.isEmpty) {
      setState(() => _error = 'El nombre es obligatorio.');
      return;
    }
    setState(() {
      _guardando = true;
      _error = null;
    });
    try {
      await LogisticaService.crearEmpresa(
        nombre: nombre,
        tipo: widget.tipo,
        apodo: _apodoCtrl.text.trim().isEmpty ? null : _apodoCtrl.text.trim(),
        cuit: _cuitCtrl.text.trim().isEmpty ? null : _cuitCtrl.text.trim(),
        contacto: _contactoCtrl.text.trim().isEmpty
            ? null
            : _contactoCtrl.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() {
        _guardando = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Z][a-z]+: '), '');
      });
    }
  }
}

// =============================================================================
// CHIP COMPARTIDO
// =============================================================================

class _Chip extends StatelessWidget {
  final String texto;
  const _Chip(this.texto);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Text(
        texto,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 11,
        ),
      ),
    );
  }
}

// =============================================================================
// BLOQUE DE PRODUCTOS — chips con cada producto + botón "+ Agregar"
// que abre un dialog con TextField. Tap en X de un chip lo borra.
// Persiste con setProductosDeEmpresa (lista completa, dedup
// case-insensitive en el service).
// =============================================================================

class _BloqueProductos extends StatelessWidget {
  final String empresaId;
  final List<String> productos;

  const _BloqueProductos({
    required this.empresaId,
    required this.productos,
  });

  Future<void> _agregar(BuildContext context) async {
    final nuevo = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: AppColors.background,
          title: const Text('Agregar producto'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Nombre del producto',
              hintText: 'Ej. Urea granulada',
            ),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('CANCELAR'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('AGREGAR'),
            ),
          ],
        );
      },
    );
    if (nuevo == null || nuevo.isEmpty) return;
    final nueva = [...productos, nuevo];
    await LogisticaService.setProductosDeEmpresa(
      id: empresaId,
      productos: nueva,
    );
  }

  Future<void> _quitar(int index) async {
    final nueva = List<String>.from(productos);
    nueva.removeAt(index);
    await LogisticaService.setProductosDeEmpresa(
      id: empresaId,
      productos: nueva,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.inventory_2_outlined,
                  color: AppColors.accentAmber, size: 16),
              SizedBox(width: 6),
              Text(
                'PRODUCTOS QUE CARGA',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (productos.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Sin productos cargados',
                style: TextStyle(color: Colors.white38, fontSize: 13),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(productos.length, (i) {
                return Chip(
                  label: Text(
                    productos[i],
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                    ),
                  ),
                  backgroundColor:
                      AppColors.accentAmber.withValues(alpha: 0.2),
                  side: BorderSide(
                    color: AppColors.accentAmber.withValues(alpha: 0.5),
                  ),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  deleteIconColor: Colors.white70,
                  onDeleted: () => _quitar(i),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize:
                      MaterialTapTargetSize.shrinkWrap,
                );
              }),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _agregar(context),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('AGREGAR PRODUCTO'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.accentAmber,
              side: const BorderSide(color: AppColors.accentAmber),
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}
