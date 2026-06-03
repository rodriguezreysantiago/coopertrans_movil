// lib/features/logistica/screens/logistica_empresas_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — ABM de empresas en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los tabs CLIENTES / DADORES (DefaultTabController),
//   - el stream `LogisticaService.streamEmpresas(tipo:)`, el filtro
//     token-based (`_aplicarFiltro`), el alta (`_AltaEmpresaDialog` +
//     `LogisticaService.crearEmpresa`), la edición inline (sheet +
//     `actualizarEmpresa` / `setProductosDeEmpresa` /
//     `setUbicacionesDeEmpresa`), el toggle activa, la eliminación con
//     check de referencias server-side, las validaciones de CUIT /
//     teléfono y los atajos de teclado (`KeyboardShortcutsScope`),
//   - los formatters (CUIT / teléfono / dígitos).
//
// Material en formularios: los inputs del alta y de los diálogos (CUIT,
// producto) siguen siendo `TextField` reskineados por el theme; los campos
// del sheet de edición usan los `DatoEditable*` compartidos — NO se tocan
// para no romper la lógica de persistencia. Lo que cambió es la superficie:
// buscador Núcleo (AppInput), cards re-skineadas a tokens (AppCard tier-1 +
// AppBadge + chips bento), FAB brand, bloques productos/ubicaciones a tokens.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
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
    final c = context.colors;
    return DefaultTabController(
      length: 2,
      child: AppScaffold(
        title: 'Empresas',
        bottom: TabBar(
          tabs: const [
            Tab(text: 'CLIENTES'),
            Tab(text: 'DADORES'),
          ],
          indicatorColor: c.brand,
          labelColor: c.text,
          unselectedLabelColor: c.textMuted,
          labelStyle: AppType.label.copyWith(fontWeight: FontWeight.w600),
        ),
        body: const TabBarView(
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
  late final TextEditingController _buscarCtrl;

  @override
  void initState() {
    super.initState();
    _buscarCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _buscarCtrl.dispose();
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
    final esCliente = widget.tipo == TipoEmpresaLogistica.cliente;
    return KeyboardShortcutsScope(
      onNuevo: _abrirAlta,
      buscarFocusNode: _buscarFocus,
      child: Stack(
        children: [
          Column(
            children: [
              // Buscador Núcleo (misma lógica de filtro token-based).
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                child: AppInput(
                  controller: _buscarCtrl,
                  focusNode: _buscarFocus,
                  hint: esCliente
                      ? 'Buscar por nombre, CUIT, contacto, producto…'
                      : 'Buscar por nombre, CUIT, contacto…',
                  icon: Icons.search,
                  onChanged: (v) => setState(() => _filtro = v),
                  trailingAction: _filtro.isEmpty ? null : 'Limpiar',
                  onTrailingTap: _filtro.isEmpty
                      ? null
                      : () {
                          _buscarCtrl.clear();
                          setState(() => _filtro = '');
                        },
                ),
              ),
              Expanded(
                child: StreamBuilder<List<EmpresaLogistica>>(
                  stream: LogisticaService.streamEmpresas(tipo: widget.tipo),
                  builder: (ctx, snap) {
                    if (snap.connectionState == ConnectionState.waiting) {
                      return const AppSkeletonList(count: 8, conAvatar: false);
                    }
                    // Mostrar error real (típico: "requires an index" si falta
                    // el índice compuesto en firestore.indexes.json). Sin esto
                    // el StreamBuilder mostraría empty state y el operador
                    // pensaría que "no se guarda nada" cuando en realidad la
                    // query falla en Firestore.
                    if (snap.hasError) {
                      return AppErrorState(
                        title: 'Error cargando la lista',
                        subtitle: snap.error.toString(),
                      );
                    }
                    final items = snap.data ?? const [];
                    if (items.isEmpty) {
                      return AppEmptyState(
                        icon: Icons.business_outlined,
                        title: esCliente
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
                    return ListView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 90),
                      itemCount: filtrados.length,
                      itemBuilder: (_, i) => _CardEmpresa(empresa: filtrados[i]),
                    );
                  },
                ),
              ),
            ],
          ),
          Positioned(
            right: AppSpacing.lg,
            bottom: AppSpacing.lg,
            child: FloatingActionButton.extended(
              heroTag: 'fab_empresa_${widget.tipo.codigo}',
              backgroundColor: AppColors.brand,
              foregroundColor: AppColors.surface0,
              onPressed: _abrirAlta,
              icon: const Icon(Icons.add),
              label: Text(esCliente ? 'NUEVO CLIENTE' : 'NUEVO DADOR'),
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
    final c = context.colors;
    final activa = empresa.activa;
    final accent = activa ? c.brand : c.textMuted;
    final tituloColor = activa ? c.text : c.textMuted;

    return AppCard(
      tier: 1,
      accent: accent,
      onTap: () => _abrirEdicion(context),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.business_outlined, color: accent, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      empresa.etiquetaPrincipal,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.body.copyWith(
                        color: tituloColor,
                        fontWeight: FontWeight.w700,
                        decoration: activa
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
                        style: AppType.bodySm.copyWith(
                          color: c.textMuted,
                          decoration: activa
                              ? TextDecoration.none
                              : TextDecoration.lineThrough,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!activa) ...[
                AppBadge(
                  text: 'Inactiva',
                  color: c.textMuted,
                  size: AppBadgeSize.sm,
                ),
                const SizedBox(width: AppSpacing.xs),
              ],
              // Switch activa/inactiva. El check de referencias en
              // tarifas + ubicaciones se hace server-side; si la empresa
              // está en uso, no se borra y mostramos un mensaje accionable.
              Switch(
                value: activa,
                onChanged: (v) => LogisticaService.actualizarEmpresa(
                  id: empresa.id,
                  cambios: {'activa': v},
                ),
                activeTrackColor: c.brand,
              ),
              IconButton(
                icon: Icon(Icons.delete_outline, color: c.error, size: 18),
                tooltip: 'Eliminar empresa',
                onPressed: () => _confirmarEliminar(context),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
          if (empresa.cuit != null ||
              empresa.contacto != null ||
              empresa.nombreContacto != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.xs,
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
      backgroundColor: context.colors.surface2,
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
    final c = context.colors;
    final messenger = ScaffoldMessenger.of(context);
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: dCtx.colors.surface2,
        title: const Text('¿Eliminar empresa?'),
        content: Text(
          '${empresa.nombre}\n\n'
          'Esta acción no se puede deshacer. Si la empresa está usada '
          'por alguna tarifa o ubicación, no se va a poder borrar.',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.of(dCtx).pop(false),
          ),
          AppButton.danger(
            label: 'Eliminar',
            onPressed: () => Navigator.of(dCtx).pop(true),
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
            ? EmpresaLogistica.fromMap(snap.data!.id, snap.data!.data()!)
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
    final c = context.colors;
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
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: c.surface3,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(Icons.business_outlined, size: 16, color: c.brand),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        empresa.etiquetaPrincipal,
                        style: AppType.h5.copyWith(color: c.text),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (empresa.etiquetaSecundaria != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            empresa.etiquetaSecundaria!,
                            style: AppType.monoSm.copyWith(color: c.textMuted),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.xxl),
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
                const SizedBox(height: AppSpacing.md),
                _BloqueProductos(
                  empresaId: empresa.id,
                  productos: empresa.productos,
                ),
                const SizedBox(height: AppSpacing.md),
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
      backgroundColor: context.colors.surface2,
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
    final c = context.colors;
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
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: BorderRadius.circular(AppRadius.xl),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.place_outlined, color: c.brand, size: 14),
                  const SizedBox(width: AppSpacing.xs),
                  const AppEyebrow('Ubicaciones de esta empresa'),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              if (asociadas.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    'Sin ubicaciones asignadas',
                    style: AppType.bodySm.copyWith(color: c.textMuted),
                  ),
                )
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: asociadas
                      .map((u) => _Tag(u.nombre, color: c.brand))
                      .toList(),
                ),
              const SizedBox(height: AppSpacing.sm),
              AppButton.secondary(
                label: asociadas.isEmpty
                    ? 'Asignar ubicaciones'
                    : 'Editar ubicaciones',
                icon: Icons.add,
                size: AppButtonSize.sm,
                full: true,
                onPressed: () => _editar(context, todas, asociadasIds),
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
    final c = context.colors;
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
            margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.borderStrong,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(
                AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.sm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AppEyebrow('Seleccionar ubicaciones'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: AppInput(
              hint: 'Buscar por nombre o localidad…',
              icon: Icons.search,
              onChanged: (v) => setState(() => _filtro = v),
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
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
                    style: AppType.body.copyWith(color: c.text),
                  ),
                  subtitle: Text(
                    u.etiquetaCompleta,
                    style: AppType.bodySm.copyWith(color: c.textMuted),
                  ),
                  activeColor: c.brand,
                  dense: true,
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg, AppSpacing.sm, AppSpacing.lg, AppSpacing.md),
              child: Row(
                children: [
                  Expanded(
                    child: AppButton.ghost(
                      label: 'Cancelar',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: AppButton.primary(
                      label: 'Guardar (${_seleccionadas.length})',
                      onPressed: () =>
                          Navigator.of(context).pop(_seleccionadas),
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
    final c = context.colors;
    return AlertDialog(
      backgroundColor: c.surface2,
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
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _apodoCtrl,
              decoration: const InputDecoration(
                labelText: 'Apodo / nombre comercial (opcional)',
                hintText: 'Ej. Lartirigoyen',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _cuitCtrl,
              keyboardType: TextInputType.number,
              inputFormatters: [CuitInputFormatter()],
              decoration: const InputDecoration(
                labelText: 'CUIT (opcional)',
                hintText: 'XX-XXXXXXXX-X',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextField(
              controller: _nombreContactoCtrl,
              decoration: const InputDecoration(
                labelText: 'Nombre del contacto (opcional)',
                hintText: 'Ej. Juan Pérez',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
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
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: AppType.bodySm.copyWith(color: c.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        AppButton.ghost(
          label: 'Cancelar',
          onPressed: _guardando ? null : () => Navigator.pop(context),
        ),
        AppButton.primary(
          label: 'Guardar',
          loading: _guardando,
          onPressed: _guardando ? null : _guardar,
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
// CHIPS / TAGS COMPARTIDOS
// =============================================================================

/// Chip neutro de dato (CUIT, contacto). Hairline + texto eyebrow muted.
class _Chip extends StatelessWidget {
  final String texto;
  const _Chip(this.texto);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border.all(color: c.border),
      ),
      child: Text(
        texto,
        style: AppType.eyebrow.copyWith(color: c.textSecondary),
      ),
    );
  }
}

/// Tag de color tenue (ubicación / producto asignado). Tinte del color +
/// borde del mismo color a baja opacidad.
class _Tag extends StatelessWidget {
  final String texto;
  final Color color;
  final VoidCallback? onDeleted;
  const _Tag(this.texto, {required this.color, this.onDeleted});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(10, 5, onDeleted != null ? 5 : 10, 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              texto,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppType.label.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (onDeleted != null) ...[
            const SizedBox(width: 4),
            InkWell(
              onTap: onDeleted,
              borderRadius: BorderRadius.circular(AppRadius.full),
              child: Icon(Icons.close, size: 14, color: color),
            ),
          ],
        ],
      ),
    );
  }
}

// =============================================================================
// BLOQUE DE PRODUCTOS — tags con cada producto + botón "Agregar producto"
// que abre un dialog con TextField. Tap en X de un tag lo borra.
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
            backgroundColor: ctx.colors.surface2,
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
              AppButton.ghost(
                label: 'Cancelar',
                onPressed: () => Navigator.pop(ctx),
              ),
              AppButton.primary(
                label: 'Agregar',
                onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
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
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.surface1,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: c.warning, size: 14),
              const SizedBox(width: AppSpacing.xs),
              const AppEyebrow('Productos que carga'),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (productos.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                'Sin productos cargados',
                style: AppType.bodySm.copyWith(color: c.textMuted),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: List.generate(
                productos.length,
                (i) => _Tag(
                  productos[i],
                  color: c.warning,
                  onDeleted: () => _quitar(i),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.secondary(
            label: 'Agregar producto',
            icon: Icons.add,
            size: AppButtonSize.sm,
            full: true,
            onPressed: () => _agregar(context),
          ),
        ],
      ),
    );
  }
}
