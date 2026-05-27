import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/cuit_formatter.dart';
import '../../../shared/utils/digit_only_formatter.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/dato_editable.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/empresa_logistica.dart';
import '../models/ubicacion_logistica.dart';
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
          indicatorColor: AppColors.info,
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

class _ListaEmpresas extends StatefulWidget {
  final TipoEmpresaLogistica tipo;
  const _ListaEmpresas({required this.tipo});

  @override
  State<_ListaEmpresas> createState() => _ListaEmpresasState();
}

class _ListaEmpresasState extends State<_ListaEmpresas> {
  String _filtro = '';
  final FocusNode _buscarFocus = FocusNode();

  @override
  void dispose() {
    _buscarFocus.dispose();
    super.dispose();
  }

  /// Tokeniza el filtro y exige que TODOS los tokens estén presentes
  /// en algún campo de la empresa. Permite buscar "vecchi 2914" y
  /// matchear "Vecchi Ariel SRL" con teléfono 2914567890. Mismo patrón
  /// que `LogisticaUbicacionesScreen`.
  List<EmpresaLogistica> _aplicarFiltro(List<EmpresaLogistica> items) {
    final q = _filtro.trim().toLowerCase();
    if (q.isEmpty) return items;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return items.where((e) {
      final hay = [
        e.nombre,
        e.apodo ?? '',
        e.cuit ?? '',
        e.contacto ?? '',
        e.nombreContacto ?? '',
        e.productos.join(' '),
      ].join(' ').toLowerCase();
      for (final t in tokens) {
        if (!hay.contains(t)) return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return KeyboardShortcutsScope(
      onNuevo: _abrirAlta,
      buscarFocusNode: _buscarFocus,
      child: Stack(
      children: [
        Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                focusNode: _buscarFocus,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: widget.tipo == TipoEmpresaLogistica.cliente
                      ? 'Buscar por nombre, CUIT, contacto, producto…'
                      : 'Buscar por nombre, CUIT, contacto…',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _filtro.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: 'Limpiar búsqueda',
                          onPressed: () => setState(() => _filtro = ''),
                        ),
                ),
                onChanged: (v) => setState(() => _filtro = v),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<EmpresaLogistica>>(
                stream: LogisticaService.streamEmpresas(tipo: widget.tipo),
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
                      title: widget.tipo == TipoEmpresaLogistica.cliente
                          ? 'Sin clientes cargados'
                          : 'Sin dadores de transporte cargados',
                      subtitle: 'Tocá + para agregar el primero',
                    );
                  }
                  final filtrados = _aplicarFiltro(items);
                  if (filtrados.isEmpty) {
                    return AppEmptyState(
                      icon: Icons.search_off,
                      title: 'Sin resultados',
                      subtitle:
                          'Ninguna empresa coincide con "$_filtro". Probá '
                          'con otra palabra o limpiá el filtro.',
                    );
                  }
                  return ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                    itemCount: filtrados.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) => _CardEmpresa(empresa: filtrados[i]),
                  );
                },
              ),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: 16,
          child: FloatingActionButton.extended(
            heroTag: 'fab_empresa_${widget.tipo.codigo}',
            backgroundColor: AppColors.info,
            onPressed: _abrirAlta,
            icon: const Icon(Icons.add),
            label: Text(
              widget.tipo == TipoEmpresaLogistica.cliente
                  ? 'NUEVO CLIENTE'
                  : 'NUEVO DADOR',
            ),
          ),
        ),
      ],
      ),
    );
  }

  Future<void> _abrirAlta() async {
    await showDialog(
      context: context,
      builder: (_) => _AltaEmpresaDialog(tipo: widget.tipo),
    );
  }
}

class _CardEmpresa extends StatelessWidget {
  final EmpresaLogistica empresa;
  const _CardEmpresa({required this.empresa});

  @override
  Widget build(BuildContext context) {
    final color =
        empresa.activa ? AppColors.info : Colors.white24;
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
                activeTrackColor: AppColors.info,
              ),
              // Botón eliminar al lado del switch. El check de
              // referencias en tarifas + ubicaciones se hace
              // server-side; si la empresa está en uso, no se borra
              // y mostramos un mensaje accionable.
              IconButton(
                icon: const Icon(Icons.delete_outline,
                    color: AppColors.error),
                tooltip: 'Eliminar empresa',
                onPressed: () => _confirmarEliminar(context),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (empresa.cuit != null ||
              empresa.contacto != null ||
              empresa.nombreContacto != null) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (empresa.cuit != null) _Chip('CUIT ${empresa.cuit}'),
                // Si tiene tel + nombre, los unimos en un solo chip
                // "Juan Pérez · 2914567890" para verlos al toque.
                if (empresa.contacto != null &&
                    empresa.contacto!.trim().isNotEmpty)
                  _Chip(_chipContacto(empresa))
                else if (empresa.nombreContacto != null &&
                    empresa.nombreContacto!.trim().isNotEmpty)
                  _Chip(empresa.nombreContacto!),
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

  /// Compone el texto del chip de contacto. Si la empresa tiene
  /// nombre + tel → "Juan Pérez · 2914567890". Si solo tel → el tel.
  /// Si solo nombre → solo nombre (manejado afuera, este helper
  /// asume que hay tel).
  String _chipContacto(EmpresaLogistica e) {
    final tel = PhoneFormatter.paraMostrar(e.contacto);
    final nombre = e.nombreContacto?.trim() ?? '';
    if (nombre.isNotEmpty) return '$nombre · $tel';
    return tel;
  }

  /// Confirma + elimina la empresa. El service chequea referencias
  /// (tarifas como origen/destino, ubicaciones que la tienen
  /// asociada) y tira StateError accionable si la empresa está en
  /// uso. En ese caso mostramos el mensaje exacto del service en
  /// SnackBar y no se hace el delete.
  Future<void> _confirmarEliminar(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: Theme.of(dCtx).colorScheme.surface,
        title: const Text('¿Eliminar empresa?'),
        content: Text(
          '${empresa.nombre}\n\n'
          'Esta acción no se puede deshacer. Si la empresa está usada '
          'por alguna tarifa o ubicación, no se va a poder borrar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('CANCELAR'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
            ),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('ELIMINAR'),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await LogisticaService.eliminarEmpresa(empresa.id);
      AppFeedback.successOn(messenger, 'Empresa eliminada.');
    } on StateError catch (e) {
      AppFeedback.errorOn(messenger, e.message);
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar la empresa. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
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
    // Suscribimos al doc para que el sheet se refresque al toque
    // cuando cambien productos, ubicaciones asignadas, datos
    // básicos, etc. Antes el widget era estático y al agregar un
    // producto había que cerrar y reabrir para verlo.
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: LogisticaService.empresasCol.doc(empresa.id).snapshots(),
      // initialData con un fake snapshot — no lo usamos directo,
      // pero evita que el builder reciba un null transitorio al
      // arrancar el sheet (mostraría un flash de "loading" sobre
      // la data que ya tenemos en la prop empresa).
      builder: (ctx, snap) {
        // Si llegó snapshot fresco, usamos ese. Si no (carga
        // inicial o transitorio), usamos el `empresa` de la prop
        // como fallback.
        final actual = (snap.hasData &&
                snap.data!.exists &&
                snap.data!.data() != null)
            ? EmpresaLogistica.fromMap(
                snap.data!.id, snap.data!.data()!)
            : empresa;
        return _EditarEmpresaSheetBody(empresa: actual);
      },
    );
  }
}

/// Body del sheet con la data ya resuelta. Separado para que el
/// StreamBuilder solo se preocupe de la suscripción y este widget
/// se enfoque en renderear / persistir.
class _EditarEmpresaSheetBody extends StatelessWidget {
  final EmpresaLogistica empresa;
  const _EditarEmpresaSheetBody({required this.empresa});

  @override
  Widget build(BuildContext context) {
    final messenger = ScaffoldMessenger.of(context);
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
                const Icon(Icons.business, color: AppColors.info),
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
                  // Mostramos el CUIT formateado XX-XXXXXXXX-X (si el
                  // doc tiene solo dígitos lo formatea; si tiene
                  // guiones queda igual).
                  valor: CuitInputFormatter.formatear(empresa.cuit ?? ''),
                  aplicarMayusculas: false,
                  inputFormatters: [CuitInputFormatter()],
                  // Persistimos con guiones también — operador puede
                  // leer el campo tal cual sin re-formatear server-side.
                  onSave: (v) {
                    // Validacion (auditoria 2026-05-17): mismo check que
                    // el alta — sin esto el EDIT permitia CUIT incompleto
                    // (ej "30-7042" → 4 digitos) y rompia reportes /
                    // bsqueda por CUIT.
                    final cuitRaw = v.trim();
                    if (cuitRaw.isNotEmpty) {
                      final digitos = cuitRaw.replaceAll(RegExp(r'\D'), '');
                      if (digitos.length != 11) {
                        AppFeedback.warningOn(
                          messenger,
                          'CUIT debe tener 11 digitos (formato XX-XXXXXXXX-X).',
                        );
                        return;
                      }
                    }
                    setCampo(
                      'cuit',
                      cuitRaw.isEmpty
                          ? null
                          : CuitInputFormatter.formatear(cuitRaw),
                    );
                  },
                ),
                DatoEditableTexto(
                  etiqueta: 'Nombre del contacto (opcional)',
                  valor: empresa.nombreContacto ?? '',
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'nombre_contacto',
                    v.trim().isEmpty ? null : v.trim(),
                  ),
                ),
                DatoEditableTexto(
                  etiqueta: 'Teléfono del contacto (opcional)',
                  // Patrón idéntico al de EMPLEADOS.TELEFONO:
                  //   - paraMostrar() saca el prefijo 549 para
                  //     mostrar solo el código de área + abonado.
                  //   - paraGuardar() agrega el prefijo 549 antes de
                  //     persistir (formato que el bot WhatsApp
                  //     consume con `<numero>@c.us`).
                  //   - DigitOnlyFormatter para garantizar que el
                  //     campo NUNCA tenga chars no-numéricos —
                  //     evita que se cuele un email/texto que
                  //     después rompería el bot.
                  valor: PhoneFormatter.paraMostrar(empresa.contacto),
                  inputFormatters: [DigitOnlyFormatter()],
                  keyboardType: TextInputType.phone,
                  aplicarMayusculas: false,
                  onSave: (v) => setCampo(
                    'contacto',
                    PhoneFormatter.paraGuardar(v),
                  ),
                ),
                const SizedBox(height: 12),
                _BloqueProductos(
                  empresaId: empresa.id,
                  productos: empresa.productos,
                ),
                const SizedBox(height: 12),
                _BloqueUbicacionesDeEmpresa(
                  empresaId: empresa.id,
                  empresaNombre: empresa.nombre,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Bloque "UBICACIONES DE ESTA EMPRESA" en el sheet de edición de
/// empresa. Lista las ubicaciones que tienen esta empresa en su
/// `empresa_ids` (relación N:M, lado opuesto del que se gestiona
/// desde la pantalla de Ubicaciones).
///
/// Decisión Santiago 2026-05-12: además de poder asociar empresas
/// desde una ubicación, también se puede asociar ubicaciones desde
/// una empresa. Es la misma relación, vista desde el otro lado.
/// Útil cuando se carga una empresa nueva y tiene varios puntos de
/// carga/descarga — más natural pensar "Cargill carga en X, Y, Z"
/// que abrir cada ubicación y agregar "Cargill" una por una.
class _BloqueUbicacionesDeEmpresa extends StatelessWidget {
  final String empresaId;
  final String empresaNombre;

  const _BloqueUbicacionesDeEmpresa({
    required this.empresaId,
    required this.empresaNombre,
  });

  Future<void> _editar(
    BuildContext context,
    List<UbicacionLogistica> todasLasUbicaciones,
    Set<String> seleccionadas,
  ) async {
    final res = await showModalBottomSheet<Set<String>>(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
      builder: (_) => _SeleccionUbicacionesSheet(
        todas: todasLasUbicaciones,
        seleccionadasIniciales: seleccionadas,
      ),
    );
    if (res == null) return;
    try {
      await LogisticaService.setUbicacionesDeEmpresa(
        empresaId: empresaId,
        empresaNombre: empresaNombre,
        ubicacionIds: res.toList(),
      );
    } catch (e) {
      if (!context.mounted) return;
      AppFeedback.errorOn(
        ScaffoldMessenger.of(context),
        'No se pudieron actualizar las ubicaciones: $e',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<UbicacionLogistica>>(
      stream: LogisticaService.streamUbicaciones(),
      builder: (ctx, snap) {
        final todas = snap.data ?? const <UbicacionLogistica>[];
        // Ubicaciones que tienen esta empresa asociada.
        final asociadas = todas
            .where((u) => u.empresaIds.contains(empresaId))
            .toList();
        final asociadasIds = asociadas.map((u) => u.id).toSet();

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
                  Icon(Icons.place_outlined,
                      color: AppColors.accentTeal, size: 16),
                  SizedBox(width: 6),
                  Text(
                    'UBICACIONES DE ESTA EMPRESA',
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
              if (asociadas.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Sin ubicaciones asignadas',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: asociadas.map((u) {
                    return Chip(
                      label: Text(
                        u.nombre,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      backgroundColor:
                          AppColors.accentTeal.withValues(alpha: 0.25),
                      side: BorderSide(
                        color: AppColors.accentTeal.withValues(alpha: 0.6),
                      ),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    );
                  }).toList(),
                ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: () => _editar(context, todas, asociadasIds),
                icon: const Icon(Icons.add, size: 16),
                label: Text(
                  asociadas.isEmpty
                      ? 'ASIGNAR UBICACIONES'
                      : 'EDITAR UBICACIONES',
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentTeal,
                  side: const BorderSide(color: AppColors.accentTeal),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Sheet de multi-selección de ubicaciones. Devuelve el set de IDs
/// elegidos (o null si el operador canceló).
class _SeleccionUbicacionesSheet extends StatefulWidget {
  final List<UbicacionLogistica> todas;
  final Set<String> seleccionadasIniciales;

  const _SeleccionUbicacionesSheet({
    required this.todas,
    required this.seleccionadasIniciales,
  });

  @override
  State<_SeleccionUbicacionesSheet> createState() =>
      _SeleccionUbicacionesSheetState();
}

class _SeleccionUbicacionesSheetState
    extends State<_SeleccionUbicacionesSheet> {
  late Set<String> _seleccionadas;
  String _filtro = '';

  @override
  void initState() {
    super.initState();
    _seleccionadas = Set<String>.from(widget.seleccionadasIniciales);
  }

  @override
  Widget build(BuildContext context) {
    final filtroLower = _filtro.toLowerCase();
    final ubicacionesFiltradas = widget.todas.where((u) {
      if (filtroLower.isEmpty) return true;
      return u.nombre.toLowerCase().contains(filtroLower) ||
          u.localidad.toLowerCase().contains(filtroLower);
    }).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
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
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'SELECCIONAR UBICACIONES',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 11,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Buscar por nombre o localidad…',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _filtro = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              itemCount: ubicacionesFiltradas.length,
              itemBuilder: (_, i) {
                final u = ubicacionesFiltradas[i];
                final marcada = _seleccionadas.contains(u.id);
                return CheckboxListTile(
                  value: marcada,
                  onChanged: (val) {
                    setState(() {
                      if (val == true) {
                        _seleccionadas.add(u.id);
                      } else {
                        _seleccionadas.remove(u.id);
                      }
                    });
                  },
                  title: Text(
                    u.nombre,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                  subtitle: Text(
                    u.etiquetaCompleta,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                  activeColor: AppColors.accentTeal,
                  dense: true,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('CANCELAR'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accentTeal,
                      ),
                      onPressed: () =>
                          Navigator.of(context).pop(_seleccionadas),
                      child: Text(
                        'GUARDAR (${_seleccionadas.length})',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
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
  final _nombreContactoCtrl = TextEditingController();
  final _contactoCtrl = TextEditingController();
  bool _guardando = false;
  String? _error;

  @override
  void dispose() {
    _nombreCtrl.dispose();
    _apodoCtrl.dispose();
    _cuitCtrl.dispose();
    _nombreContactoCtrl.dispose();
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
        width: (MediaQuery.of(context).size.width - 80).clamp(240.0, 360.0),
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
              inputFormatters: [CuitInputFormatter()],
              decoration: const InputDecoration(
                labelText: 'CUIT (opcional)',
                hintText: 'XX-XXXXXXXX-X',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nombreContactoCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre del contacto (opcional)',
                hintText: 'Ej. Juan Pérez',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _contactoCtrl,
              keyboardType: TextInputType.phone,
              inputFormatters: [DigitOnlyFormatter()],
              decoration: const InputDecoration(
                labelText: 'Teléfono del contacto (opcional)',
                hintText: '2914567890',
                helperText:
                    'Se guarda con prefijo 549 (formato WhatsApp).',
                helperMaxLines: 2,
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: AppColors.error),
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
      // El TextField del CUIT ya muestra los guiones (vía
      // CuitInputFormatter), así que `_cuitCtrl.text` viene formateado.
      // Persistimos tal cual para que el doc en Firestore quede
      // consistente con lo que ve el operador.
      //
      // CRITICO (auditoria 2026-05-17): antes aceptaba CUIT incompleto
      // (3, 7 digitos, lo que sea) — el formatter formateaba "1234567"
      // como "12-34567" y quedaba en Firestore. Rompia busquedas, AFIP,
      // posibilidad de duplicados con CUITs distintos para misma empresa.
      // Ahora validamos: si el operador puso ALGO en el campo, debe
      // tener 11 digitos. Si lo dejo vacio, OK (campo opcional).
      final cuitRaw = _cuitCtrl.text.trim();
      if (cuitRaw.isNotEmpty) {
        final cuitDigitos = cuitRaw.replaceAll(RegExp(r'\D'), '');
        if (cuitDigitos.length != 11) {
          setState(() {
            _guardando = false;
            _error = 'CUIT debe tener 11 dígitos (formato XX-XXXXXXXX-X).';
          });
          return;
        }
      }
      await LogisticaService.crearEmpresa(
        nombre: nombre,
        tipo: widget.tipo,
        apodo: _apodoCtrl.text.trim().isEmpty ? null : _apodoCtrl.text.trim(),
        cuit: cuitRaw.isEmpty ? null : CuitInputFormatter.formatear(cuitRaw),
        // Teléfono: el TextField ya tiene DigitOnlyFormatter, así
        // que el texto viene como puros dígitos. paraGuardar agrega
        // el prefijo 549 (formato canónico WhatsApp, mismo que
        // EMPLEADOS.TELEFONO). Vacío → null para no guardar campo
        // basura.
        contacto: _contactoCtrl.text.trim().isEmpty
            ? null
            : PhoneFormatter.paraGuardar(_contactoCtrl.text),
        nombreContacto: _nombreContactoCtrl.text.trim().isEmpty
            ? null
            : _nombreContactoCtrl.text.trim(),
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
    final ctrl = TextEditingController();
    final String? nuevo;
    try {
      nuevo = await showDialog<String>(
        context: context,
        builder: (ctx) {
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
    } finally {
      ctrl.dispose();
    }
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
                  color: AppColors.warning, size: 16),
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
                      AppColors.warning.withValues(alpha: 0.2),
                  side: BorderSide(
                    color: AppColors.warning.withValues(alpha: 0.5),
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
              foregroundColor: AppColors.warning,
              side: const BorderSide(color: AppColors.warning),
              padding: const EdgeInsets.symmetric(vertical: 8),
            ),
          ),
        ],
      ),
    );
  }
}

