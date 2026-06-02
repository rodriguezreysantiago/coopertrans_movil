import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import 'gomeria_v2_stock_screen.dart';
import 'gomeria_v2_unidad_screen.dart';

/// Hub del modelo NUEVO de gomería. La entrada es por BÚSQUEDA (no una lista
/// larga de 127 unidades, que en tablet era incómoda): el gomero busca por
/// chofer (le trae su tractor + enganche), o directo un tractor o un enganche
/// por patente. Arriba quedan los accesos a Stock y (solo admin) al catálogo.
class GomeriaV2HubScreen extends StatefulWidget {
  const GomeriaV2HubScreen({super.key});

  @override
  State<GomeriaV2HubScreen> createState() => _GomeriaV2HubScreenState();
}

class _GomeriaV2HubScreenState extends State<GomeriaV2HubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final _qChofer = TextEditingController();
  final _qTractor = TextEditingController();
  final _qEnganche = TextEditingController();

  bool _cargando = true;
  String? _error;
  final List<_Unidad> _tractores = [];
  final List<_Unidad> _enganches = [];
  final List<_Chofer> _choferes = [];

  static final _reEnganche =
      RegExp(r'BATEA|TOLVA|TANQUE|ENGAN|ACOPL', caseSensitive: false);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    for (final c in [_qChofer, _qTractor, _qEnganche]) {
      c.addListener(() => setState(() {}));
    }
    _cargar();
  }

  @override
  void dispose() {
    _tab.dispose();
    _qChofer.dispose();
    _qTractor.dispose();
    _qEnganche.dispose();
    super.dispose();
  }

  Future<void> _cargar() async {
    try {
      final fs = FirebaseFirestore.instance;
      final vSnap = await fs.collection(AppCollections.vehiculos).get();
      for (final d in vSnap.docs) {
        final data = d.data();
        final u = _Unidad(
          patente: d.id,
          marca: (data['MARCA'] ?? '').toString(),
        );
        (_reEnganche.hasMatch((data['TIPO'] ?? '').toString())
                ? _enganches
                : _tractores)
            .add(u);
      }
      _tractores.sort((a, b) => a.patente.compareTo(b.patente));
      _enganches.sort((a, b) => a.patente.compareTo(b.patente));

      final eSnap = await fs.collection(AppCollections.empleados).get();
      for (final d in eSnap.docs) {
        final data = d.data();
        if (data['ACTIVO'] == false) continue;
        final tractor = (data['VEHICULO'] ?? '').toString().trim();
        final enganche = (data['ENGANCHE'] ?? '').toString().trim();
        final tieneT = tractor.isNotEmpty && tractor != '-';
        final tieneE = enganche.isNotEmpty && enganche != '-';
        if (!tieneT && !tieneE) continue; // solo los que tienen unidad
        _choferes.add(_Chofer(
          nombre: (data['NOMBRE'] ?? d.id).toString(),
          tractor: tieneT ? tractor : null,
          enganche: tieneE ? enganche : null,
        ));
      }
      _choferes.sort((a, b) => a.nombre.compareTo(b.nombre));
      if (mounted) setState(() => _cargando = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _cargando = false;
        });
      }
    }
  }

  void _abrirUnidad(String patente, TipoUnidadCubierta tipo) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            GomeriaV2UnidadScreen(unidadId: patente, unidadTipo: tipo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Gomería (nueva)',
      body: _cargando
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? AppErrorState(
                  title: 'No se pudieron cargar las unidades',
                  subtitle: _error!)
              : Column(
                  children: [
                    _acciones(),
                    TabBar(
                      controller: _tab,
                      tabs: const [
                        Tab(text: 'Por chofer'),
                        Tab(text: 'Tractores'),
                        Tab(text: 'Enganches'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _tab,
                        children: [
                          _tabChofer(),
                          _tabUnidades(_tractores, _qTractor,
                              TipoUnidadCubierta.tractor, 'tractor'),
                          _tabUnidades(_enganches, _qEnganche,
                              TipoUnidadCubierta.enganche, 'enganche'),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }

  // ───────────────────────── acciones (stock / catálogo) ─────────────────
  Widget _acciones() {
    final esAdmin = PrefsService.rol == AppRoles.admin;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: _accionCard(
              icon: Icons.inventory_2,
              label: 'Stock',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GomeriaV2StockScreen()),
              ),
            ),
          ),
          if (esAdmin) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _accionCard(
                icon: Icons.category_outlined,
                label: 'Marcas y modelos',
                onTap: () => Navigator.pushNamed(
                    context, AppRoutes.adminGomeriaMarcasModelos),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _accionCard({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Card(
      color: Theme.of(context).colorScheme.primaryContainer,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buscador(TextEditingController ctrl, String hint) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: ctrl,
        textCapitalization: TextCapitalization.characters,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: hint,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: ctrl.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: ctrl.clear,
                ),
        ),
      ),
    );
  }

  // ───────────────────────── tab: por chofer ─────────────────────────────
  Widget _tabChofer() {
    final q = _qChofer.text.trim().toUpperCase();
    final lista = q.isEmpty
        ? _choferes
        : _choferes
            .where((c) => c.nombre.toUpperCase().contains(q))
            .toList();
    return Column(
      children: [
        _buscador(_qChofer, 'Buscar chofer por nombre'),
        Expanded(
          child: lista.isEmpty
              ? const Center(child: Text('Sin resultados'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  itemCount: lista.length,
                  itemBuilder: (_, i) => _cardChofer(lista[i]),
                ),
        ),
      ],
    );
  }

  Widget _cardChofer(_Chofer c) {
    Widget fila(String etiqueta, String? patente, IconData icono,
        TipoUnidadCubierta tipo) {
      if (patente == null) {
        return ListTile(
          dense: true,
          leading: Icon(icono, color: Colors.grey),
          title: Text(etiqueta),
          subtitle: const Text('Sin asignar'),
        );
      }
      return ListTile(
        dense: true,
        leading: Icon(icono),
        title: Text(etiqueta),
        subtitle: Text(patente),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _abrirUnidad(patente, tipo),
      );
    }

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(c.nombre,
                style: Theme.of(context).textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ),
          fila('Tractor', c.tractor, Icons.local_shipping,
              TipoUnidadCubierta.tractor),
          fila('Enganche', c.enganche, Icons.rv_hookup,
              TipoUnidadCubierta.enganche),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  // ───────────────────────── tabs: tractores / enganches ─────────────────
  Widget _tabUnidades(List<_Unidad> todas, TextEditingController ctrl,
      TipoUnidadCubierta tipo, String nombreTipo) {
    final q = ctrl.text.trim().toUpperCase();
    final lista = q.isEmpty
        ? todas
        : todas
            .where((u) =>
                u.patente.toUpperCase().contains(q) ||
                u.marca.toUpperCase().contains(q))
            .toList();
    return Column(
      children: [
        _buscador(ctrl, 'Buscar $nombreTipo por patente'),
        Expanded(
          child: lista.isEmpty
              ? const Center(child: Text('Sin resultados'))
              : LayoutBuilder(
                  builder: (_, cns) {
                    final cols = cns.maxWidth >= 1200
                        ? 4
                        : cns.maxWidth >= 900
                            ? 3
                            : cns.maxWidth >= 600
                                ? 2
                                : 1;
                    if (cols == 1) {
                      return ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                        itemCount: lista.length,
                        itemBuilder: (_, i) => _tileUnidad(lista[i], tipo),
                      );
                    }
                    const sp = 8.0;
                    final w = (cns.maxWidth - 24 - sp * (cols - 1)) / cols;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Wrap(
                        spacing: sp,
                        runSpacing: sp,
                        children: [
                          for (final u in lista)
                            SizedBox(width: w, child: _tileUnidad(u, tipo)),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _tileUnidad(_Unidad u, TipoUnidadCubierta tipo) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        leading: Icon(tipo == TipoUnidadCubierta.tractor
            ? Icons.local_shipping
            : Icons.rv_hookup),
        title: Text(u.patente, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: u.marca.isEmpty
            ? null
            : Text(u.marca, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _abrirUnidad(u.patente, tipo),
      ),
    );
  }
}

class _Unidad {
  final String patente;
  final String marca;
  _Unidad({required this.patente, required this.marca});
}

class _Chofer {
  final String nombre;
  final String? tractor;
  final String? enganche;
  _Chofer({required this.nombre, this.tractor, this.enganche});
}
