import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/zona_descarga.dart';
import '../services/zonas_descarga_service.dart';

/// Pantalla admin para crear/editar zonas de descarga. El operador
/// define cada zona (YPF Añelo, otras plantas) con su geometría
/// (círculo o polígono). La CF `zonaDescargaPoller` las consume cada
/// 5 min para mantener la cola en vivo del módulo "Descargas".
class AdminZonasDescargaScreen extends StatelessWidget {
  const AdminZonasDescargaScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Zonas de descarga',
      body: StreamBuilder<List<ZonaDescarga>>(
        stream: ZonasDescargaService.stream(),
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final zonas = snap.data ?? const <ZonaDescarga>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _BannerExplicativo(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        zonas.isEmpty
                            ? 'Sin zonas cargadas todavía'
                            : '${zonas.length} zona${zonas.length == 1 ? "" : "s"}',
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 12),
                      ),
                    ),
                    FilledButton.icon(
                      onPressed: () => _abrirForm(context, null),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Nueva zona'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.accentCyan,
                        foregroundColor: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: zonas.isEmpty
                    ? const _EstadoVacio()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        itemCount: zonas.length,
                        itemBuilder: (c, i) => _ZonaCard(zona: zonas[i]),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  static void _abrirForm(BuildContext context, ZonaDescarga? z) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _ZonaForm(zonaExistente: z),
    );
  }
}

class _BannerExplicativo extends StatelessWidget {
  const _BannerExplicativo();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppColors.accentBlue.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: AppColors.accentBlue.withValues(alpha: 0.30),
        ),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, color: AppColors.accentBlue, size: 20),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Cada zona define un lugar de descarga (ej. YPF Añelo). El '
              'sistema detecta cuándo entra y sale cada unidad para armar '
              'la cola en vivo del módulo "Descargas". Definila como '
              'círculo (centro + radio) o polígono (puntos).',
              style: TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

class _EstadoVacio extends StatelessWidget {
  const _EstadoVacio();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.add_location_alt_outlined,
                color: Colors.white24, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Sin zonas cargadas',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              'Cargá la primera zona (YPF Añelo) para que el módulo '
              '"Descargas" empiece a detectar entradas y salidas.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ZonaCard extends StatelessWidget {
  final ZonaDescarga zona;
  const _ZonaCard({required this.zona});

  String get _resumenGeom {
    if (zona.shape == ZonaShape.circulo) {
      if (zona.centro == null || zona.radioMts == null) return 'Sin centro';
      return 'Círculo · ${zona.radioMts!.toStringAsFixed(0)} m radio · '
          '${zona.centro!.latitud.toStringAsFixed(5)}, '
          '${zona.centro!.longitud.toStringAsFixed(5)}';
    }
    return 'Polígono · ${zona.vertices.length} puntos';
  }

  @override
  Widget build(BuildContext context) {
    final color = zona.activo ? AppColors.success : Colors.white24;
    return AppCard(
      onTap: () =>
          AdminZonasDescargaScreen._abrirForm(context, zona),
      child: Opacity(
        opacity: zona.activo ? 1.0 : 0.55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                      color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    zona.nombre,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15),
                  ),
                ),
                Text(
                  zona.activo ? 'Activa' : 'Pausada',
                  style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _resumenGeom,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 2),
            Text(
              'Estadía mínima: ${zona.estadiaMinMin} min · slug ${zona.slug}',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
            if ((zona.notas ?? '').isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                zona.notas!,
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontStyle: FontStyle.italic),
              ),
            ],
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      ZonasDescargaService.setActivo(zona.slug, !zona.activo),
                  icon: Icon(
                      zona.activo
                          ? Icons.pause_circle_outline
                          : Icons.play_circle_outline,
                      size: 18),
                  label: Text(zona.activo ? 'Pausar' : 'Reanudar'),
                  style: TextButton.styleFrom(
                      foregroundColor: Colors.white70),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: AppColors.accentRed),
                  tooltip: 'Eliminar zona',
                  onPressed: () => _confirmarBorrar(context, zona),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmarBorrar(BuildContext context, ZonaDescarga z) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Eliminar zona'),
        content: Text(
            'Vas a eliminar "${z.nombre}". La cola activa y el histórico '
            'no se borran pero quedan huérfanos. ¿Confirmás?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar')),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: AppColors.accentRed),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
    if (ok == true) await ZonasDescargaService.eliminar(z.slug);
  }
}

// ─── Form alta/edit ─────────────────────────────────────────────

class _ZonaForm extends StatefulWidget {
  final ZonaDescarga? zonaExistente;
  const _ZonaForm({this.zonaExistente});

  @override
  State<_ZonaForm> createState() => _ZonaFormState();
}

class _ZonaFormState extends State<_ZonaForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nombre;
  late final TextEditingController _lat;
  late final TextEditingController _lng;
  late final TextEditingController _radio;
  late final TextEditingController _verticesText;
  late final TextEditingController _estadia;
  late final TextEditingController _notas;
  late ZonaShape _shape;
  late bool _activo;
  bool _guardando = false;
  String? _error;

  bool get _esEdicion => widget.zonaExistente != null;

  @override
  void initState() {
    super.initState();
    final z = widget.zonaExistente;
    _nombre = TextEditingController(text: z?.nombre ?? '');
    _lat = TextEditingController(
        text: z?.centro?.latitud.toStringAsFixed(6) ?? '');
    _lng = TextEditingController(
        text: z?.centro?.longitud.toStringAsFixed(6) ?? '');
    _radio = TextEditingController(text: z?.radioMts?.toStringAsFixed(0) ?? '200');
    _verticesText = TextEditingController(
      text: (z?.vertices ?? [])
          .map((v) =>
              '${v.latitud.toStringAsFixed(6)}, ${v.longitud.toStringAsFixed(6)}')
          .join('\n'),
    );
    _estadia = TextEditingController(text: (z?.estadiaMinMin ?? 5).toString());
    _notas = TextEditingController(text: z?.notas ?? '');
    _shape = z?.shape ?? ZonaShape.circulo;
    _activo = z?.activo ?? true;
  }

  @override
  void dispose() {
    for (final c in [_nombre, _lat, _lng, _radio, _verticesText, _estadia, _notas]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _guardar() async {
    setState(() => _error = null);
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _guardando = true);
    try {
      LatLngPunto? centro;
      double? radio;
      List<LatLngPunto> vertices = const [];
      if (_shape == ZonaShape.circulo) {
        centro = LatLngPunto(
            double.parse(_lat.text.trim()),
            double.parse(_lng.text.trim()));
        radio = double.parse(_radio.text.trim());
      } else {
        vertices = _parsearVertices(_verticesText.text);
      }
      final z = ZonaDescarga(
        slug: _esEdicion
            ? widget.zonaExistente!.slug
            : ZonasDescargaService.slugDesdeNombre(_nombre.text.trim()),
        nombre: _nombre.text.trim(),
        shape: _shape,
        centro: centro,
        radioMts: radio,
        vertices: vertices,
        estadiaMinMin: int.parse(_estadia.text.trim()),
        activo: _activo,
        notas: _notas.text.trim().isEmpty ? null : _notas.text.trim(),
      );
      if (_esEdicion) {
        await ZonasDescargaService.editar(z);
      } else {
        await ZonasDescargaService.crear(z);
      }
      if (mounted) navigator.pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _guardando = false;
          _error = e.toString().replaceAll('Exception: ', '');
        });
      }
      messenger.showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  /// Parsea líneas "lat, lng" (separadores: coma, espacio o tab).
  /// Tolera "−38.35274, −68.71163" y formatos con/sin signos.
  List<LatLngPunto> _parsearVertices(String texto) {
    final out = <LatLngPunto>[];
    for (final ln in texto.split('\n')) {
      final t = ln.trim();
      if (t.isEmpty) continue;
      // Reemplazar separadores y dividir
      final partes =
          t.replaceAll(RegExp(r'[,;\s]+'), ' ').split(' ').where((s) => s.isNotEmpty).toList();
      if (partes.length < 2) continue;
      final lat = double.tryParse(partes[0]);
      final lng = double.tryParse(partes[1]);
      if (lat != null && lng != null) out.add(LatLngPunto(lat, lng));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _esEdicion ? 'Editar zona' : 'Nueva zona',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 17),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _nombre,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Nombre',
                  hintText: 'Ej. YPF Añelo',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Obligatorio' : null,
                readOnly: _esEdicion, // slug no se cambia
              ),
              const SizedBox(height: 14),
              SegmentedButton<ZonaShape>(
                segments: const [
                  ButtonSegment(
                      value: ZonaShape.circulo,
                      label: Text('Círculo'),
                      icon: Icon(Icons.circle_outlined)),
                  ButtonSegment(
                      value: ZonaShape.poligono,
                      label: Text('Polígono'),
                      icon: Icon(Icons.timeline)),
                ],
                selected: {_shape},
                onSelectionChanged: (s) => setState(() => _shape = s.first),
              ),
              const SizedBox(height: 14),
              if (_shape == ZonaShape.circulo) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _lat,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Latitud',
                          hintText: '-38.352740',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d\-\.]'))
                        ],
                        validator: (v) =>
                            double.tryParse(v?.trim() ?? '') == null
                                ? 'Inválido'
                                : null,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _lng,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Longitud',
                          hintText: '-68.711630',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d\-\.]'))
                        ],
                        validator: (v) =>
                            double.tryParse(v?.trim() ?? '') == null
                                ? 'Inválido'
                                : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _radio,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Radio (metros)',
                    hintText: '200',
                    helperText: 'Típico para zona de descarga: 100-500 m',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    final n = int.tryParse(v?.trim() ?? '');
                    if (n == null || n <= 0) return 'Radio > 0';
                    if (n > 10000) return 'Máx 10 km';
                    return null;
                  },
                ),
              ] else ...[
                TextFormField(
                  controller: _verticesText,
                  style: const TextStyle(
                      color: Colors.white, fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Vértices (lat, lng — uno por línea)',
                    hintText:
                        '-38.352740, -68.711630\n-38.353500, -68.710800\n-38.354100, -68.712200',
                    helperText: 'Mínimo 3 puntos. Orden en sentido horario o '
                        'antihorario, NO mezclados.',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 6,
                  validator: (v) {
                    final pts = _parsearVertices(v ?? '');
                    if (pts.length < 3) return 'Mínimo 3 puntos';
                    return null;
                  },
                ),
              ],
              const SizedBox(height: 14),
              TextFormField(
                controller: _estadia,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Estadía mínima (minutos)',
                  helperText:
                      'Filtra unidades que solo pasaron. 5 min default.',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '');
                  if (n == null || n < 1 || n > 240) {
                    return 'Entre 1 y 240';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _notas,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Notas (opcional)',
                  border: OutlineInputBorder(),
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Zona activa',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  'Si está pausada, el sistema no detecta entradas ni salidas '
                  'pero la configuración queda guardada.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: _activo,
                onChanged: (v) => setState(() => _activo = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!,
                    style: const TextStyle(
                        color: AppColors.accentRed, fontSize: 13)),
              ],
              const SizedBox(height: 18),
              FilledButton.icon(
                onPressed: _guardando ? null : _guardar,
                icon: _guardando
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.save),
                label: Text(_esEdicion ? 'Guardar cambios' : 'Crear zona'),
                style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
