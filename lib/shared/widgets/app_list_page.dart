import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'app_states.dart';

/// Página genérica de listado para Firestore con buscador, filtro,
/// y estados de carga/error/vacío estandarizados.
///
/// Uso típico:
/// ```
/// AppListPage<QueryDocumentSnapshot>(
///   stream: FirebaseFirestore.instance.collection('VEHICULOS')
///       .where('TIPO', isEqualTo: 'TRACTOR').snapshots(),
///   itemBuilder: (ctx, doc) => MiVehiculoCard(doc: doc),
///   filter: (doc, q) {
///     final data = doc.data() as Map<String, dynamic>;
///     return doc.id.toUpperCase().contains(q) ||
///            (data['MARCA'] ?? '').toString().toUpperCase().contains(q);
///   },
///   searchHint: 'Buscar patente, marca, VIN...',
///   emptyTitle: 'Sin tractores cargados',
/// );
/// ```
///
/// La pantalla automáticamente extrae los `docs` del QuerySnapshot.
class AppListPage extends StatefulWidget {
  final Stream<QuerySnapshot> stream;
  final Widget Function(BuildContext, QueryDocumentSnapshot) itemBuilder;

  /// Filtro de búsqueda. Recibe el doc y la query (ya en uppercase).
  /// Si es null, no se muestra el buscador.
  final bool Function(QueryDocumentSnapshot, String)? filter;

  final String? searchHint;
  final String emptyTitle;
  final String? emptySubtitle;
  final IconData emptyIcon;
  final EdgeInsets padding;

  /// Slot opcional para mostrar algo arriba del listado (ej: un resumen,
  /// chips de filtro extra, etc.). Aparece debajo del buscador.
  final Widget? header;

  const AppListPage({
    super.key,
    required this.stream,
    required this.itemBuilder,
    this.filter,
    this.searchHint,
    this.emptyTitle = 'Sin resultados',
    this.emptySubtitle,
    this.emptyIcon = Icons.inbox_outlined,
    this.padding = const EdgeInsets.fromLTRB(10, 10, 10, 80),
    this.header,
  });

  @override
  State<AppListPage> createState() => _AppListPageState();
}

class _AppListPageState extends State<AppListPage> {
  final TextEditingController _searchCtl = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchCtl.addListener(() {
      if (!mounted) return;
      setState(() => _query = _searchCtl.text.toUpperCase().trim());
    });
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (widget.searchHint != null && widget.filter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: widget.searchHint,
                prefixIcon: Icon(
                  Icons.search,
                  color: Theme.of(context).colorScheme.primary,
                ),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear,
                            color: Colors.white54, size: 18),
                        tooltip: 'Limpiar búsqueda',
                        onPressed: () => _searchCtl.clear(),
                      )
                    : null,
              ),
            ),
          ),
        if (widget.header != null) widget.header!,
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: widget.stream,
            builder: (ctx, snap) {
              if (snap.hasError) {
                return AppErrorState(subtitle: snap.error.toString());
              }
              if (!snap.hasData) {
                return const AppLoadingState();
              }

              List<QueryDocumentSnapshot> items = snap.data!.docs;
              // Aplicamos el filtro SIEMPRE, no solo cuando hay texto: muchos
              // call-sites usan `filter` también para filtros de visibilidad
              // (activos/excluidos/rol) que deben regir aunque el buscador esté
              // vacío. Con query vacío, la parte de búsqueda (`contains('')`) da
              // true y no descarta nada — solo aplican los filtros de estado.
              // (Antes el `_query.isNotEmpty &&` los anulaba sin búsqueda → los
              // chips de rol de Personal y los toggles no hacían nada.)
              if (widget.filter != null) {
                items = items
                    .where((it) => widget.filter!(it, _query))
                    .toList();
              }

              if (items.isEmpty) {
                return AppEmptyState(
                  icon: widget.emptyIcon,
                  title: _query.isNotEmpty
                      ? 'Sin resultados para "${_searchCtl.text}"'
                      : widget.emptyTitle,
                  subtitle: _query.isNotEmpty ? null : widget.emptySubtitle,
                );
              }

              return ListView.builder(
                padding: widget.padding,
                itemCount: items.length,
                itemBuilder: (ctx, idx) =>
                    widget.itemBuilder(ctx, items[idx]),
              );
            },
          ),
        ),
      ],
    );
  }
}
