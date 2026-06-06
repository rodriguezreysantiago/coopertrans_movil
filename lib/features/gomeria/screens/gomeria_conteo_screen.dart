// lib/features/gomeria/screens/gomeria_conteo_screen.dart
//
// Conteo de inventario "a ciegas" — la usa el operador de gomería. Lista todos
// los modelos activos del catálogo y, por cada uno, cuántas NUEVAS y RECAPADAS
// ve físicamente. NO muestra el stock teórico del sistema (eso es lo que el
// admin compara después). Al enviar, crea un doc en GOMERIA_CONTEOS.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/conteo_gomeria.dart';
import '../models/cubierta_modelo.dart';
import '../services/conteos_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
import 'package:coopertrans_movil/core/theme/app_typography.dart';

class GomeriaConteoScreen extends StatefulWidget {
  const GomeriaConteoScreen({super.key});

  @override
  State<GomeriaConteoScreen> createState() => _GomeriaConteoScreenState();
}

class _GomeriaConteoScreenState extends State<GomeriaConteoScreen> {
  final _svc = ConteosService();
  final _ctrlNuevas = <String, TextEditingController>{};
  final _ctrlRecap = <String, TextEditingController>{};
  bool _enviando = false;

  /// `true` una vez que el conteo se envió OK: dejamos salir sin preguntar
  /// (el `Navigator.pop` post-envío no debe disparar la confirmación).
  bool _guardado = false;

  TextEditingController _ctrl(
          Map<String, TextEditingController> m, String id) =>
      m.putIfAbsent(id, () => TextEditingController());

  @override
  void dispose() {
    for (final c in _ctrlNuevas.values) {
      c.dispose();
    }
    for (final c in _ctrlRecap.values) {
      c.dispose();
    }
    super.dispose();
  }

  int _leer(Map<String, TextEditingController> m, String id) =>
      int.tryParse((m[id]?.text ?? '').trim()) ?? 0;

  /// `true` si el gomero tipeó alguna cantidad (cualquier campo no vacío y
  /// distinto de 0). Sirve para avisar antes de salir y no perder el conteo.
  bool _tieneDatos() {
    bool algo(Map<String, TextEditingController> m) =>
        m.values.any((c) => (int.tryParse(c.text.trim()) ?? 0) != 0);
    return algo(_ctrlNuevas) || algo(_ctrlRecap);
  }

  /// Confirma la salida cuando hay datos sin enviar. Devuelve `true` si el
  /// usuario decide salir igual (descartar lo tipeado).
  Future<bool> _confirmarSalida() async {
    if (_guardado || _enviando || !_tieneDatos()) return true;
    final salir = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('¿Salir sin enviar?'),
        content: const Text(
            'Cargaste cantidades que todavía no enviaste. Si salís ahora se '
            'pierde el conteo.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Seguir contando')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Salir igual')),
        ],
      ),
    );
    return salir ?? false;
  }

  Future<void> _enviar(List<CubiertaModelo> modelos) async {
    final lineas = <LineaConteo>[];
    for (final mod in modelos) {
      final nuevas = _leer(_ctrlNuevas, mod.id);
      final recap = mod.recapable ? _leer(_ctrlRecap, mod.id) : 0;
      lineas.add(LineaConteo(
        modeloId: mod.id,
        modeloEtiqueta: mod.etiqueta,
        nuevas: nuevas,
        recapadas: recap,
      ));
    }
    final conAlgo = lineas.where((l) => l.total > 0).toList();
    final total = conAlgo.fold<int>(0, (a, l) => a + l.total);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enviar conteo'),
        content: Text(conAlgo.isEmpty
            ? 'No cargaste ninguna cubierta. ¿Enviar un conteo vacío (todo en 0)?'
            : 'Vas a enviar $total cubiertas contadas en ${conAlgo.length} modelos. '
                'No vas a ver el stock del sistema — eso lo controla la oficina. ¿Enviar?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Revisar')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Enviar')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _enviando = true);
    try {
      await _svc.crearConteo(
        lineas: lineas,
        responsableDni: PrefsService.dni,
        responsableNombre: PrefsService.nombre,
      );
      if (!mounted) return;
      _guardado = true; // ya se envió: la salida no debe pedir confirmación.
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Conteo enviado. La oficina lo va a controlar.')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _enviando = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('No se pudo enviar: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopScope(
      // Avisar antes de salir si hay un conteo a medio cargar (back del
      // sistema o flecha del AppBar): no perder lo tipeado por un toque.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // Capturamos el Navigator ANTES del await para no usar `context`
        // cruzando el gap async (el `mounted` igual lo confirma).
        final nav = Navigator.of(context);
        if (await _confirmarSalida() && mounted) {
          nav.pop();
        }
      },
      child: AppScaffold(
        title: 'Conteo de inventario',
        body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.cubiertasModelos)
              .where('activo', isEqualTo: true)
              .snapshots(),
          builder: (context, snap) {
            if (snap.hasError) {
              return const AppErrorState(
                  title: 'No se pudieron cargar los modelos');
            }
            if (!snap.hasData) return const AppLoadingState();
            final modelos = snap.data!.docs.map(CubiertaModelo.fromDoc).toList()
              ..sort((a, b) =>
                  a.etiqueta.toUpperCase().compareTo(b.etiqueta.toUpperCase()));
            if (modelos.isEmpty) {
              return const AppEmptyState(
                icon: Icons.tire_repair_outlined,
                title: 'Sin modelos en el catálogo',
                subtitle: 'No hay modelos de cubierta activos para contar.',
              );
            }
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
                  child: AppCard(
                    glow: true,
                    padding: const EdgeInsets.all(AppSpacing.md),
                    child: Row(
                      children: [
                        Icon(Icons.inventory_2_outlined,
                            size: 18, color: c.brand),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            'Contá cuántas cubiertas hay en el depósito de cada '
                            'modelo. La oficina compara con el sistema.',
                            style:
                                AppType.bodySm.copyWith(color: c.textSecondary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.lg),
                    itemCount: modelos.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.sm),
                    itemBuilder: (_, i) => _FilaModelo(
                      modelo: modelos[i],
                      ctrlNuevas: _ctrl(_ctrlNuevas, modelos[i].id),
                      ctrlRecap: _ctrl(_ctrlRecap, modelos[i].id),
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.md),
                    child: AppButton(
                      label: 'Enviar conteo',
                      icon: Icons.send_outlined,
                      expand: true,
                      loading: _enviando,
                      onPressed: _enviando ? null : () => _enviar(modelos),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FilaModelo extends StatelessWidget {
  final CubiertaModelo modelo;
  final TextEditingController ctrlNuevas;
  final TextEditingController ctrlRecap;
  const _FilaModelo({
    required this.modelo,
    required this.ctrlNuevas,
    required this.ctrlRecap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Text(
              modelo.etiqueta,
              style: AppType.bodySm.copyWith(color: c.text),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _CampoNum(label: 'Nuevas', ctrl: ctrlNuevas),
          if (modelo.recapable) ...[
            const SizedBox(width: AppSpacing.xs),
            _CampoNum(label: 'Recap.', ctrl: ctrlRecap),
          ],
        ],
      ),
    );
  }
}

class _CampoNum extends StatelessWidget {
  final String label;
  final TextEditingController ctrl;
  const _CampoNum({required this.label, required this.ctrl});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 62,
      child: Column(
        children: [
          Text(label.toUpperCase(),
              style: AppType.eyebrow.copyWith(color: c.textMuted, fontSize: 8),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          TextField(
            controller: ctrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.center,
            style: AppType.h5.copyWith(color: c.text),
            decoration: InputDecoration(
              isDense: true,
              hintText: '0',
              hintStyle: AppType.h5.copyWith(color: c.textMuted),
              contentPadding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              filled: true,
              fillColor: c.surface3,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
