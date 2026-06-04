// lib/features/logistica/screens/logistica_tarifa_form_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — alta/edición de tarifa en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto todo el form:
//   - el State (`_tipoCarga`, `_dador`, `_empOrigen`, `_ubicOrigen`,
//     `_empDestino`, `_ubicDestino`, `_flete`, `_unidad`, `_producto`,
//     toggles `_modoMontoFijoDador` / `_modoMontoFijoChofer`),
//   - TODOS los controllers (`_comisionCtrl`, `_montoFijoDadorCtrl`,
//     `_tarifaRealCtrl`, `_tarifaChoferCtrl`, `_montoFijoChoferCtrl`,
//     `_notasCtrl`) con sus inputFormatters (`AppFormatters.inputMilesDecimal`,
//     el filtro `[0-9.,]` de comisión, etc.),
//   - la carga en edición (`_cargarSiEdicion`) y las validaciones +
//     guardado (`_guardar` → `LogisticaService.crearTarifa` /
//     `actualizarTarifa`) sin tocar ni una regla,
//   - la navegación.
//
// Reskin Núcleo: secciones como AppCard tier 2 con eyebrow + número en
// dot brand; ChoiceChip → pills `_PillSelector`; TextField conserva su
// lógica pero adopta el InputDecoration Núcleo (`_inputDecoration`);
// selectores empresa/ubicación/producto → cards tappeables con bottom
// sheets re-skineados a tokens.
//
// Reglas duras: tokens (context.colors), faltante → "—", sin overflow.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_service.dart';

/// Form full-screen para alta y edición de tarifas. Flujo lineal
/// arriba-abajo:
///
/// 1) Tipo de carga (PROPIA / TERCEROS) → si es TERCEROS aparece el
///    bloque "Dador + comisión".
/// 2) Origen (empresa + ubicación).
/// 3) Destino (empresa + ubicación).
/// 4) Modalidad (flete origen/destino + unidad TN/VIAJE).
/// 5) Tarifas (real + chofer).
/// 6) Notas (opcional).
///
/// Si recibe `arguments={'tarifaId': '...'}` carga la tarifa para editar;
/// si no, es alta.
class LogisticaTarifaFormScreen extends StatefulWidget {
  /// Si es null, el form arranca en modo "alta". Si trae un id, se carga
  /// la tarifa de Firestore y se permite "modificar precio".
  final String? tarifaId;

  const LogisticaTarifaFormScreen({super.key, this.tarifaId});

  @override
  State<LogisticaTarifaFormScreen> createState() =>
      _LogisticaTarifaFormScreenState();
}

class _LogisticaTarifaFormScreenState extends State<LogisticaTarifaFormScreen> {
  // ─── Estado del form ───
  TipoCargaLogistica _tipoCarga = TipoCargaLogistica.propia;
  EmpresaLogistica? _dador;
  final _comisionCtrl = TextEditingController();

  /// `true` → el dador cobra un MONTO FIJO por viaje (caso GASPERINI), en
  /// [_montoFijoDadorCtrl]. `false` → comisión por porcentaje del flete.
  bool _modoMontoFijoDador = false;
  final _montoFijoDadorCtrl = TextEditingController();

  EmpresaLogistica? _empOrigen;
  UbicacionLogistica? _ubicOrigen;
  EmpresaLogistica? _empDestino;
  UbicacionLogistica? _ubicDestino;

  FleteLogistica _flete = FleteLogistica.origen;
  UnidadTarifa _unidad = UnidadTarifa.porTonelada;
  final _tarifaRealCtrl = TextEditingController();
  final _tarifaChoferCtrl = TextEditingController();

  /// Monto fijo del chofer por viaje, alternativa al cálculo del 18%
  /// sobre `tarifaChofer × TN`. Si el toggle [_modoMontoFijoChofer] está
  /// OFF, este controller no se usa al guardar (queda null en Firestore →
  /// cálculo legacy).
  final _montoFijoChoferCtrl = TextEditingController();

  /// `true` → la tarifa del chofer se acuerda como monto fijo por viaje
  /// (sin TN ni 18%). `false` → comportamiento histórico (18% sobre
  /// `tarifaChofer × TN`).
  bool _modoMontoFijoChofer = false;
  final _notasCtrl = TextEditingController();

  /// Producto que se transporta. Opcional — null = tarifa "general" para
  /// esa ruta. Lista de opciones viene del catálogo de productos de la
  /// empresa origen seleccionada.
  String? _producto;

  // ─── Estado de carga ───
  bool _cargando = true;
  bool _guardando = false;
  String? _error;

  /// Tarifa cargada en modo edición — fuente de las vigencias para la
  /// sección "Precio y vigencia". Se refresca tras registrar un precio.
  TarifaLogistica? _tarifaCargada;

  bool get _esEdicion => widget.tarifaId != null;

  @override
  void initState() {
    super.initState();
    _cargarSiEdicion();
  }

  Future<void> _cargarSiEdicion() async {
    if (!_esEdicion) {
      setState(() => _cargando = false);
      return;
    }
    try {
      final snap =
          await LogisticaService.tarifasCol.doc(widget.tarifaId!).get();
      if (!snap.exists) {
        setState(() {
          _cargando = false;
          _error = 'La tarifa no existe.';
        });
        return;
      }
      final t = TarifaLogistica.fromMap(snap.id, snap.data()!);
      _tarifaCargada = t;
      _tipoCarga = t.tipoCarga;
      _flete = t.flete;
      _unidad = t.unidadTarifa;
      _tarifaRealCtrl.text = AppFormatters.formatearMonto(t.tarifaReal);
      _tarifaChoferCtrl.text = AppFormatters.formatearMonto(t.tarifaChofer);
      if (t.montoFijoChofer != null) {
        _modoMontoFijoChofer = true;
        _montoFijoChoferCtrl.text =
            AppFormatters.formatearMonto(t.montoFijoChofer!);
      }
      if (t.porcentajeComisionDador != null) {
        _comisionCtrl.text = t.porcentajeComisionDador!.toStringAsFixed(1);
      }
      if (t.montoFijoDador != null) {
        _modoMontoFijoDador = true;
        _montoFijoDadorCtrl.text =
            AppFormatters.formatearMonto(t.montoFijoDador!);
      }
      _notasCtrl.text = t.notas ?? '';
      _producto = t.producto;

      // Resolver referencias a empresas/ubicaciones por id (para mostrar
      // los dropdowns con la opción seleccionada). Si el doc fue borrado,
      // lo dejamos null y el operador tendrá que re-elegir.
      final futures = await Future.wait([
        LogisticaService.empresasCol.doc(t.empresaOrigenId).get(),
        LogisticaService.ubicacionesCol.doc(t.ubicacionOrigenId).get(),
        LogisticaService.empresasCol.doc(t.empresaDestinoId).get(),
        LogisticaService.ubicacionesCol.doc(t.ubicacionDestinoId).get(),
        if (t.dadorId != null)
          LogisticaService.empresasCol.doc(t.dadorId!).get(),
      ]);

      _empOrigen = futures[0].exists
          ? EmpresaLogistica.fromMap(futures[0].id, futures[0].data()!)
          : null;
      _ubicOrigen = futures[1].exists
          ? UbicacionLogistica.fromMap(futures[1].id, futures[1].data()!)
          : null;
      _empDestino = futures[2].exists
          ? EmpresaLogistica.fromMap(futures[2].id, futures[2].data()!)
          : null;
      _ubicDestino = futures[3].exists
          ? UbicacionLogistica.fromMap(futures[3].id, futures[3].data()!)
          : null;
      if (futures.length == 5 && futures[4].exists) {
        _dador = EmpresaLogistica.fromMap(futures[4].id, futures[4].data()!);
      }
      setState(() => _cargando = false);
    } catch (e) {
      debugPrint('logistica_tarifa_form cargar error: $e');
      setState(() {
        _cargando = false;
        _error = 'No se pudo cargar la tarifa. Probá de nuevo.';
      });
    }
  }

  /// Recarga la tarifa de Firestore — tras registrar un nuevo precio, para
  /// refrescar el precio vigente y el historial sin salir del form.
  Future<void> _recargarTarifa() async {
    if (!_esEdicion) return;
    final snap = await LogisticaService.tarifasCol.doc(widget.tarifaId!).get();
    if (!snap.exists || !mounted) return;
    setState(() {
      _tarifaCargada = TarifaLogistica.fromMap(snap.id, snap.data()!);
    });
  }

  @override
  void dispose() {
    _comisionCtrl.dispose();
    _montoFijoDadorCtrl.dispose();
    _tarifaRealCtrl.dispose();
    _tarifaChoferCtrl.dispose();
    _montoFijoChoferCtrl.dispose();
    _notasCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: _esEdicion ? 'Editar tarifa' : 'Nueva tarifa',
      body: _cargando
          ? const AppSkeletonList(count: 5, conAvatar: false)
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    final c = context.colors;
    final mismaEmpresa = _empOrigen != null &&
        _empDestino != null &&
        _empOrigen!.id == _empDestino!.id;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xxxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── 1. TIPO DE CARGA ───────────────────────────────────────
          _Seccion(
            numero: 1,
            titulo: 'Tipo de carga',
            children: [
              Row(
                children: [
                  for (final t in TipoCargaLogistica.values) ...[
                    Expanded(
                      child: _PillSelector(
                        label: t.etiqueta,
                        seleccionado: _tipoCarga == t,
                        onTap: () => setState(() {
                          _tipoCarga = t;
                          if (t == TipoCargaLogistica.propia) {
                            _dador = null;
                            _comisionCtrl.clear();
                            _montoFijoDadorCtrl.clear();
                            _modoMontoFijoDador = false;
                          }
                        }),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                ],
              ),
            ],
          ),

          // ─── 1.b DADOR + COMISIÓN (solo si TERCEROS) ────────────────
          if (_tipoCarga == TipoCargaLogistica.terceros) ...[
            const SizedBox(height: AppSpacing.mdDense),
            _Seccion(
              titulo: 'Dador de transporte',
              accentDot: c.warning,
              children: [
                _SelectorEmpresa(
                  etiqueta: 'Dador de transporte',
                  valor: _dador,
                  soloTipo: TipoEmpresaLogistica.dadorTransporte,
                  onChange: (e) => setState(() => _dador = e),
                ),
                // El importe de la comisión del dador es VERSIONADO: al
                // editar se gestiona en "Precio y vigencia". En alta sí se
                // pide acá para crear la primera vigencia.
                if (!_esEdicion) ...[
                  const SizedBox(height: AppSpacing.md),
                  const AppEyebrow('Comisión del dador'),
                  const SizedBox(height: AppSpacing.sm),
                  Wrap(
                    spacing: AppSpacing.sm,
                    runSpacing: AppSpacing.sm,
                    children: [
                      _PillSelector(
                        label: 'Porcentaje (%)',
                        seleccionado: !_modoMontoFijoDador,
                        onTap: () =>
                            setState(() => _modoMontoFijoDador = false),
                      ),
                      _PillSelector(
                        label: 'Monto fijo por viaje',
                        seleccionado: _modoMontoFijoDador,
                        onTap: () => setState(() => _modoMontoFijoDador = true),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  if (_modoMontoFijoDador)
                    TextField(
                      controller: _montoFijoDadorCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [AppFormatters.inputMilesDecimal],
                      style: AppType.mono.copyWith(color: c.text),
                      decoration: _inputDecoration(
                        context,
                        labelText: 'Monto fijo del dador (por viaje)',
                        prefixText: '\$ ',
                        suffixText: '/viaje',
                      ),
                    )
                  else
                    TextField(
                      controller: _comisionCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                      ],
                      style: AppType.mono.copyWith(color: c.text),
                      decoration: _inputDecoration(
                        context,
                        labelText: 'Comisión del dador (%)',
                        hintText: 'Ej. 12.5',
                        suffixText: '%',
                      ),
                    ),
                ],
              ],
            ),
          ],

          // ─── 2. ORIGEN ──────────────────────────────────────────────
          const SizedBox(height: AppSpacing.mdDense),
          _Seccion(
            numero: 2,
            titulo: 'Origen',
            children: [
              _SelectorEmpresa(
                etiqueta: 'Origen',
                valor: _empOrigen,
                soloTipo: TipoEmpresaLogistica.cliente,
                onChange: (e) => setState(() => _empOrigen = e),
              ),
              const SizedBox(height: AppSpacing.sm),
              _SelectorUbicacion(
                etiqueta: 'Ubicación origen',
                valor: _ubicOrigen,
                filtroEmpresaId: _empOrigen?.id,
                onChange: (u) => setState(() => _ubicOrigen = u),
              ),
            ],
          ),

          // ─── 3. DESTINO ─────────────────────────────────────────────
          const SizedBox(height: AppSpacing.mdDense),
          _Seccion(
            numero: 3,
            titulo: 'Destino',
            children: [
              _SelectorEmpresa(
                etiqueta: 'Destino',
                valor: _empDestino,
                soloTipo: TipoEmpresaLogistica.cliente,
                onChange: (e) => setState(() => _empDestino = e),
              ),
              const SizedBox(height: AppSpacing.sm),
              _SelectorUbicacion(
                etiqueta: 'Ubicación destino',
                valor: _ubicDestino,
                filtroEmpresaId: _empDestino?.id,
                onChange: (u) => setState(() => _ubicDestino = u),
              ),
              // PRODUCTO (opcional). La misma ruta puede tener tarifas
              // distintas según el producto. Opciones del catálogo de la
              // empresa origen.
              if (_empOrigen != null && _empOrigen!.productos.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.md),
                _SelectorProducto(
                  productos: _empOrigen!.productos,
                  valor: _producto,
                  onChange: (p) => setState(() => _producto = p),
                ),
              ],
            ],
          ),

          // ─── 4. MODALIDAD ───────────────────────────────────────────
          const SizedBox(height: AppSpacing.mdDense),
          _Seccion(
            numero: 4,
            titulo: 'Modalidad',
            children: [
              // Si origen y destino son la MISMA empresa, no tiene sentido
              // elegir quién paga el flete — siempre lo paga esa empresa.
              if (mismaEmpresa)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color: c.infoSoft,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    border: Border.all(color: c.info.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, size: 18, color: c.info),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          'Flete a cargo de ${_empOrigen!.nombre} '
                          '(origen y destino son la misma empresa).',
                          style: AppType.bodySm.copyWith(color: c.info),
                        ),
                      ),
                    ],
                  ),
                )
              else
                _FilaSelector<FleteLogistica>(
                  etiqueta: 'Flete pagadero',
                  opciones: FleteLogistica.values,
                  valor: _flete,
                  etiquetaFn: (f) => f.etiqueta,
                  onChange: (f) => setState(() => _flete = f),
                ),
              const SizedBox(height: AppSpacing.md),
              _FilaSelector<UnidadTarifa>(
                etiqueta: 'Unidad de tarifa',
                opciones: UnidadTarifa.values,
                valor: _unidad,
                etiquetaFn: (u) => u.etiqueta,
                onChange: (u) => setState(() => _unidad = u),
              ),
            ],
          ),

          // ─── 5. TARIFAS (alta) · PRECIO Y VIGENCIA (edición) ─────────
          // En alta se pide el precio inicial (crea la 1ª vigencia). En
          // edición el precio NO se edita acá: se gestiona por vigencias
          // ("Registrar nuevo precio"), así queda el historial de cambios.
          const SizedBox(height: AppSpacing.mdDense),
          if (!_esEdicion)
            _Seccion(
              numero: 5,
              titulo: 'Tarifas',
              accentDot: c.success,
              children: [
                _campoTarifa(
                  controller: _tarifaRealCtrl,
                  etiqueta: 'Tarifa real (lo que cobra Vecchi)',
                  color: c.success,
                ),
                const SizedBox(height: AppSpacing.lg),
                // Toggle pago al chofer: 18% sobre la tarifa chofer (default
                // histórico) o monto fijo por viaje (viajes cortos).
                const AppEyebrow('Pago al chofer'),
                const SizedBox(height: AppSpacing.sm),
                Wrap(
                  spacing: AppSpacing.sm,
                  runSpacing: AppSpacing.sm,
                  children: [
                    _PillSelector(
                      label: '18% sobre tarifa chofer',
                      seleccionado: !_modoMontoFijoChofer,
                      onTap: () => setState(() => _modoMontoFijoChofer = false),
                    ),
                    _PillSelector(
                      label: 'Monto fijo por viaje',
                      seleccionado: _modoMontoFijoChofer,
                      onTap: () => setState(() => _modoMontoFijoChofer = true),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.md),
                if (_modoMontoFijoChofer)
                  // En modo monto fijo NO se muestra la tarifa chofer (%): el
                  // chofer cobra el monto fijo y tarifa_chofer queda en 0.
                  _campoMontoFijoChofer()
                else
                  _campoTarifa(
                    controller: _tarifaChoferCtrl,
                    etiqueta: 'Tarifa chofer (lo que se le paga)',
                    color: c.info,
                  ),
              ],
            )
          else if (_tarifaCargada != null)
            _SeccionPrecioVigencia(
              tarifa: _tarifaCargada!,
              tipoCarga: _tipoCarga,
              onRegistrado: (n) async {
                await _recargarTarifa();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(n == 0
                        ? 'Nuevo precio registrado.'
                        : 'Nuevo precio registrado · $n viaje(s) '
                            'recalculado(s).'),
                  ),
                );
              },
            ),

          // ─── 6. NOTAS ───────────────────────────────────────────────
          const SizedBox(height: AppSpacing.mdDense),
          _Seccion(
            numero: 6,
            titulo: 'Notas (opcional)',
            children: [
              TextField(
                controller: _notasCtrl,
                maxLines: 3,
                style: AppType.body.copyWith(color: c.text),
                decoration: _inputDecoration(
                  context,
                  hintText: 'Ej. Cliente exige descarga antes de las 14 hs.',
                ),
              ),
            ],
          ),

          // ─── ERROR ──────────────────────────────────────────────────
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: c.errorSoft,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: c.error.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(Icons.error_outline, size: 18, color: c.error),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: AppType.bodySm.copyWith(color: c.error),
                    ),
                  ),
                ],
              ),
            ),
          ],

          // ─── ACCIONES ───────────────────────────────────────────────
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              Expanded(
                child: AppButton.secondary(
                  label: 'Cancelar',
                  expand: true,
                  onPressed: _guardando ? null : () => Navigator.pop(context),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                flex: 2,
                child: AppButton.primary(
                  label: _esEdicion ? 'Guardar cambios' : 'Guardar tarifa',
                  icon: Icons.save_outlined,
                  expand: true,
                  isLoading: _guardando,
                  onPressed: _guardando ? null : _guardar,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _campoTarifa({
    required TextEditingController controller,
    required String etiqueta,
    required Color color,
  }) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AppFormatters.inputMilesDecimal],
      style: AppType.mono
          .copyWith(color: context.colors.text, fontWeight: FontWeight.w600),
      decoration: _inputDecoration(
        context,
        labelText: etiqueta,
        prefixText: '\$ ',
        prefixStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
        suffixText: _unidad.sufijoMonto,
      ),
    );
  }

  /// Campo dedicado al monto fijo del chofer — flat por viaje, no arrastra
  /// el sufijo de unidad (`/TN` o `/viaje`) porque su unidad es siempre
  /// "por viaje" independientemente de [_unidad].
  Widget _campoMontoFijoChofer() {
    final c = context.colors;
    return TextField(
      controller: _montoFijoChoferCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AppFormatters.inputMilesDecimal],
      style: AppType.mono.copyWith(color: c.text, fontWeight: FontWeight.w600),
      decoration: _inputDecoration(
        context,
        labelText: 'Monto fijo al chofer (por viaje)',
        prefixText: '\$ ',
        prefixStyle: TextStyle(
          color: c.warning,
          fontWeight: FontWeight.bold,
        ),
        suffixText: '/viaje',
      ),
    );
  }

  // ─── Guardar ─────────────────────────────────────────────────────────
  Future<void> _guardar() async {
    setState(() {
      _error = null;
    });

    // Validaciones del cliente.
    if (_empOrigen == null || _ubicOrigen == null) {
      setState(() => _error = 'Completá empresa y ubicación de origen.');
      return;
    }
    if (_empDestino == null || _ubicDestino == null) {
      setState(() => _error = 'Completá empresa y ubicación de destino.');
      return;
    }
    if (_tipoCarga == TipoCargaLogistica.terceros && _dador == null) {
      setState(() => _error = 'Si la carga es de terceros, elegí el dador.');
      return;
    }
    // Tarifas con monto = 0 son válidas: muchas veces no se sabe el monto
    // hasta que el viaje termina. El parser devuelve null si está vacío o
    // no parsea — lo tratamos como 0 (tarifa por definir).
    final tarifaReal = AppFormatters.parsearMonto(_tarifaRealCtrl.text) ?? 0;
    // En modo "monto fijo por viaje" la tarifa_chofer (%) no se usa → 0: el
    // chofer cobra el monto fijo. Así no bloquea el guardado ni deja un %
    // viejo confuso.
    final tarifaChofer = _modoMontoFijoChofer
        ? 0.0
        : (AppFormatters.parsearMonto(_tarifaChoferCtrl.text) ?? 0);
    if (tarifaReal < 0 || tarifaChofer < 0) {
      setState(() => _error = 'Las tarifas no pueden ser negativas.');
      return;
    }
    // La validación "chofer no puede superar real" solo cuando AMBOS están
    // definidos (ambos > 0). Si alguno es 0 (por definir), no hay nada que
    // comparar.
    if (tarifaReal > 0 && tarifaChofer > 0 && tarifaChofer > tarifaReal) {
      setState(() =>
          _error = 'La tarifa del chofer no puede superar la tarifa real.');
      return;
    }
    // Si el operador eligió "monto fijo por viaje", parseamos y validamos.
    // Si está vacío o = 0, error — sino la tarifa quedaría ambigua entre
    // "modo monto fijo" y "no se cargó nada".
    double? montoFijoChofer;
    if (_modoMontoFijoChofer) {
      montoFijoChofer = AppFormatters.parsearMonto(_montoFijoChoferCtrl.text);
      if (montoFijoChofer == null || montoFijoChofer <= 0) {
        setState(() =>
            _error = 'Cargá el monto fijo del chofer (debe ser mayor a 0).');
        return;
      }
    }

    // Si origen y destino son la misma empresa, el campo `_flete` no se le
    // pide al operador. Normalizamos a `origen` para tener data consistente.
    if (_empOrigen != null &&
        _empDestino != null &&
        _empOrigen!.id == _empDestino!.id) {
      _flete = FleteLogistica.origen;
    }
    // Comisión del dador: % o monto fijo por viaje (excluyentes). Solo
    // aplica a TERCEROS. En PROPIA ambos quedan null.
    double? comision;
    double? montoFijoDador;
    if (_tipoCarga == TipoCargaLogistica.terceros) {
      if (_modoMontoFijoDador) {
        montoFijoDador = AppFormatters.parsearMonto(_montoFijoDadorCtrl.text);
        if (montoFijoDador == null || montoFijoDador <= 0) {
          setState(() =>
              _error = 'Cargá el monto fijo del dador (debe ser mayor a 0).');
          return;
        }
      } else if (_comisionCtrl.text.trim().isNotEmpty) {
        // Aceptamos coma o punto como separador decimal (input AR).
        final raw = _comisionCtrl.text.trim().replaceAll(',', '.');
        comision = double.tryParse(raw);
        if (comision == null || comision < 0 || comision > 100) {
          setState(() => _error = 'El % de comisión debe estar entre 0 y 100.');
          return;
        }
      }
    }

    setState(() => _guardando = true);
    try {
      if (_esEdicion) {
        // Modo edición: update directo (la creación de "nueva versión" para
        // preservar histórico queda como flujo explícito futuro).
        await LogisticaService.actualizarTarifa(
          id: widget.tarifaId!,
          cambios: {
            'tipo_carga': _tipoCarga.codigo,
            'dador_id': _dador?.id,
            'dador_nombre': _dador?.nombre,
            // Los importes (tarifa real/chofer, monto fijo chofer, comisión
            // y monto fijo del dador) NO se tocan acá: son VERSIONADOS y se
            // cambian con "Registrar nuevo precio" (sección Precio y
            // vigencia), para que quede el historial. Editar datos solo
            // cambia ruta/dador/modalidad/producto/notas.
            'empresa_origen_id': _empOrigen!.id,
            'empresa_origen_nombre': _empOrigen!.nombre,
            'ubicacion_origen_id': _ubicOrigen!.id,
            'ubicacion_origen_etiqueta':
                '${_ubicOrigen!.nombre} (${_ubicOrigen!.localidad})',
            'empresa_destino_id': _empDestino!.id,
            'empresa_destino_nombre': _empDestino!.nombre,
            'ubicacion_destino_id': _ubicDestino!.id,
            'ubicacion_destino_etiqueta':
                '${_ubicDestino!.nombre} (${_ubicDestino!.localidad})',
            'flete': _flete.codigo,
            'unidad_tarifa': _unidad.codigo,
            // El producto se incluye en la edición (null = lo limpia).
            'producto': _producto,
            'notas':
                _notasCtrl.text.trim().isEmpty ? null : _notasCtrl.text.trim(),
          },
        );
      } else {
        await LogisticaService.crearTarifa(
          tipoCarga: _tipoCarga,
          dadorId: _dador?.id,
          dadorNombre: _dador?.nombre,
          porcentajeComisionDador: comision,
          montoFijoDador: montoFijoDador,
          empresaOrigenId: _empOrigen!.id,
          empresaOrigenNombre: _empOrigen!.nombre,
          ubicacionOrigenId: _ubicOrigen!.id,
          ubicacionOrigenEtiqueta:
              '${_ubicOrigen!.nombre} (${_ubicOrigen!.localidad})',
          empresaDestinoId: _empDestino!.id,
          empresaDestinoNombre: _empDestino!.nombre,
          ubicacionDestinoId: _ubicDestino!.id,
          ubicacionDestinoEtiqueta:
              '${_ubicDestino!.nombre} (${_ubicDestino!.localidad})',
          flete: _flete,
          unidadTarifa: _unidad,
          tarifaReal: tarifaReal,
          tarifaChofer: tarifaChofer,
          montoFijoChofer: montoFijoChofer,
          producto: _producto,
          notas: _notasCtrl.text,
        );
      }
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
// INPUT DECORATION NÚCLEO — superficie surface2, border hairline, focus brand
// =============================================================================

/// InputDecoration común para los TextField del form, alineada al sistema
/// Núcleo (relleno surface2, border hairline, borde de foco brand). Conserva
/// `prefixText`/`suffixText`/`labelText`/`hintText` y `prefixStyle` del
/// código original.
InputDecoration _inputDecoration(
  BuildContext context, {
  String? labelText,
  String? hintText,
  String? prefixText,
  String? suffixText,
  TextStyle? prefixStyle,
}) {
  final c = context.colors;
  OutlineInputBorder border(Color col) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide(color: col),
      );
  return InputDecoration(
    labelText: labelText,
    labelStyle: AppType.bodySm.copyWith(color: c.textMuted),
    floatingLabelStyle: AppType.bodySm.copyWith(color: c.brand),
    hintText: hintText,
    hintStyle: AppType.body.copyWith(color: c.textPlaceholder),
    prefixText: prefixText,
    prefixStyle: prefixStyle ?? AppType.mono.copyWith(color: c.textSecondary),
    suffixText: suffixText,
    suffixStyle: AppType.monoSm.copyWith(color: c.textMuted),
    isDense: true,
    filled: true,
    fillColor: c.surface2,
    contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md, vertical: AppSpacing.md),
    border: border(c.border),
    enabledBorder: border(c.border),
    focusedBorder: border(c.borderFocus),
  );
}

// =============================================================================
// SECCIÓN — AppCard tier 2 con eyebrow (+ número en dot) y contenido
// =============================================================================

class _Seccion extends StatelessWidget {
  final int? numero;
  final String titulo;
  final Color? accentDot;
  final List<Widget> children;

  const _Seccion({
    this.numero,
    required this.titulo,
    this.accentDot,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (numero != null) ...[
                Container(
                  width: 22,
                  height: 22,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: c.brand.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                    border: Border.all(color: c.brand.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    '$numero',
                    style: AppType.monoSm.copyWith(
                      color: c.brand,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
              ] else if (accentDot != null) ...[
                AppDot(accentDot!, size: 7),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(
                child: AppEyebrow(
                  titulo,
                  color: numero == null ? accentDot : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

// =============================================================================
// PILL SELECTOR — reemplaza ChoiceChip; activo = tinte brand + borde
// =============================================================================

class _PillSelector extends StatelessWidget {
  final String label;
  final bool seleccionado;
  final VoidCallback onTap;

  const _PillSelector({
    required this.label,
    required this.seleccionado,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = seleccionado ? c.brand : c.textSecondary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: seleccionado
              ? c.brand.withValues(alpha: 0.16)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color:
                seleccionado ? c.brand.withValues(alpha: 0.5) : c.borderStrong,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppType.label.copyWith(
            color: fg,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

// =============================================================================
// FILA SELECTOR — eyebrow + pills (flete / unidad)
// =============================================================================

class _FilaSelector<T> extends StatelessWidget {
  final String etiqueta;
  final List<T> opciones;
  final T valor;
  final String Function(T) etiquetaFn;
  final ValueChanged<T> onChange;

  const _FilaSelector({
    required this.etiqueta,
    required this.opciones,
    required this.valor,
    required this.etiquetaFn,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppEyebrow(etiqueta),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final op in opciones)
              _PillSelector(
                label: etiquetaFn(op),
                seleccionado: op == valor,
                onTap: () => onChange(op),
              ),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// SELECTORES — cards tappeables con bottom sheets (Núcleo)
// =============================================================================

class _SelectorEmpresa extends StatelessWidget {
  final String etiqueta;
  final EmpresaLogistica? valor;
  final TipoEmpresaLogistica? soloTipo;
  final ValueChanged<EmpresaLogistica> onChange;

  const _SelectorEmpresa({
    required this.etiqueta,
    required this.valor,
    required this.onChange,
    this.soloTipo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => _abrirSelector(context),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.business_outlined, color: c.textMuted, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppEyebrow(etiqueta),
                const SizedBox(height: 2),
                Text(
                  valor?.etiquetaPrincipal ?? 'Seleccionar…',
                  style: AppType.body.copyWith(
                    color: valor == null ? c.textMuted : c.text,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (valor?.etiquetaSecundaria != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      valor!.etiquetaSecundaria!,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: c.textMuted, size: 18),
        ],
      ),
    );
  }

  Future<void> _abrirSelector(BuildContext context) async {
    final res = await showModalBottomSheet<EmpresaLogistica>(
      context: context,
      backgroundColor: context.colors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => _ListaSelectorEmpresa(soloTipo: soloTipo),
    );
    if (res != null) onChange(res);
  }
}

/// Campo de búsqueda reutilizable para los bottom-sheets de selección.
class _BuscadorField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const _BuscadorField({required this.hint, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    OutlineInputBorder border(Color col) => OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          borderSide: BorderSide(color: col),
        );
    return TextField(
      onChanged: onChanged,
      style: AppType.body.copyWith(color: c.text),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppType.body.copyWith(color: c.textPlaceholder),
        prefixIcon: Icon(Icons.search, color: c.textMuted, size: 18),
        isDense: true,
        filled: true,
        fillColor: c.surface2,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md, vertical: AppSpacing.md),
        border: border(c.border),
        enabledBorder: border(c.border),
        focusedBorder: border(c.borderFocus),
      ),
    );
  }
}

/// Handle + título de un bottom sheet de selección.
class _SheetHeader extends StatelessWidget {
  final String titulo;
  final Widget? trailing;
  const _SheetHeader({required this.titulo, this.trailing});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        const SizedBox(height: AppSpacing.sm),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: c.border,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
          child: Row(
            children: [
              Expanded(child: AppEyebrow(titulo)),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ],
    );
  }
}

class _ListaSelectorEmpresa extends StatefulWidget {
  final TipoEmpresaLogistica? soloTipo;
  const _ListaSelectorEmpresa({this.soloTipo});

  @override
  State<_ListaSelectorEmpresa> createState() => _ListaSelectorEmpresaState();
}

class _ListaSelectorEmpresaState extends State<_ListaSelectorEmpresa> {
  String _q = '';

  List<EmpresaLogistica> _filtrar(List<EmpresaLogistica> all) {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((e) {
      final p = e.etiquetaPrincipal.toLowerCase();
      final s = (e.etiquetaSecundaria ?? '').toLowerCase();
      return p.contains(q) || s.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final soloTipo = widget.soloTipo;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          _SheetHeader(
            titulo: soloTipo == TipoEmpresaLogistica.dadorTransporte
                ? 'Seleccionar dador'
                : 'Seleccionar empresa',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: _BuscadorField(
              hint: 'Buscar empresa…',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<EmpresaLogistica>>(
              stream: LogisticaService.streamEmpresas(
                tipo: soloTipo,
                soloActivas: true,
              ),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const AppSkeletonList(count: 5, conAvatar: false);
                }
                final items = _filtrar(snap.data ?? const []);
                if (items.isEmpty) {
                  return AppEmptyState(
                    icon: Icons.business_outlined,
                    title: _q.trim().isNotEmpty
                        ? 'Sin resultados'
                        : 'Sin empresas activas',
                    subtitle: _q.trim().isNotEmpty
                        ? 'Probá con otro texto.'
                        : (soloTipo == TipoEmpresaLogistica.dadorTransporte
                            ? 'Cargá un dador desde el catálogo Empresas.'
                            : 'Cargá un cliente desde el catálogo Empresas.'),
                  );
                }
                return ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.xs, AppSpacing.lg, AppSpacing.xl),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.xs),
                  itemBuilder: (_, i) {
                    final e = items[i];
                    return AppCard(
                      tier: 1,
                      onTap: () => Navigator.pop(ctx, e),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                      child: Row(
                        children: [
                          Icon(Icons.business, color: c.info, size: 18),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.etiquetaPrincipal,
                                  style: AppType.body.copyWith(
                                    color: c.text,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (e.etiquetaSecundaria != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      e.etiquetaSecundaria!,
                                      style: AppType.monoSm
                                          .copyWith(color: c.textMuted),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: c.textMuted, size: 18),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SelectorUbicacion extends StatelessWidget {
  final String etiqueta;
  final UbicacionLogistica? valor;
  final ValueChanged<UbicacionLogistica> onChange;

  /// Si está seteado, el sheet filtra a las ubicaciones de esa empresa. El
  /// sheet ofrece un toggle "Mostrar todas" por si aún no fue asociada.
  final String? filtroEmpresaId;

  const _SelectorUbicacion({
    required this.etiqueta,
    required this.valor,
    required this.onChange,
    this.filtroEmpresaId,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      onTap: () => _abrir(context),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.place_outlined, color: c.textMuted, size: 20),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppEyebrow(etiqueta),
                const SizedBox(height: 2),
                Text(
                  valor?.nombre ?? 'Seleccionar…',
                  style: AppType.body.copyWith(
                    color: valor == null ? c.textMuted : c.text,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (valor != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    valor!.etiquetaCompleta,
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: c.textMuted, size: 18),
        ],
      ),
    );
  }

  Future<void> _abrir(BuildContext context) async {
    final res = await showModalBottomSheet<UbicacionLogistica>(
      context: context,
      backgroundColor: context.colors.surface1,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (_) => _ListaSelectorUbicacion(
        filtroEmpresaId: filtroEmpresaId,
      ),
    );
    if (res != null) onChange(res);
  }
}

class _ListaSelectorUbicacion extends StatefulWidget {
  final String? filtroEmpresaId;
  const _ListaSelectorUbicacion({this.filtroEmpresaId});

  @override
  State<_ListaSelectorUbicacion> createState() =>
      _ListaSelectorUbicacionState();
}

class _ListaSelectorUbicacionState extends State<_ListaSelectorUbicacion> {
  /// Si el operador toggleó "Mostrar todas", desactivamos el filtro por
  /// empresa. Útil cuando la ubicación deseada aún no fue asociada.
  bool _mostrarTodas = false;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (ctx, controller) => Column(
        children: [
          _SheetHeader(
            titulo: 'Seleccionar ubicación',
            trailing: widget.filtroEmpresaId != null
                ? _PillSelector(
                    label:
                        _mostrarTodas ? 'Solo de la empresa' : 'Mostrar todas',
                    seleccionado: _mostrarTodas,
                    onTap: () => setState(() => _mostrarTodas = !_mostrarTodas),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm),
            child: _BuscadorField(
              hint: 'Buscar ubicación…',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<UbicacionLogistica>>(
              stream: LogisticaService.streamUbicaciones(soloActivas: true),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const AppSkeletonList(count: 5, conAvatar: false);
                }
                final all = snap.data ?? const [];
                // Filtrar por empresa si el caller pasó filtroEmpresaId y el
                // usuario NO toggleó "Mostrar todas". M:N: una ubicación
                // puede pertenecer a varias empresas — filtro array-contains
                // client-side (catálogo chico).
                final base = (widget.filtroEmpresaId != null && !_mostrarTodas)
                    ? all
                        .where((u) =>
                            u.empresaIds.contains(widget.filtroEmpresaId))
                        .toList()
                    : all;
                // + filtro por texto del buscador (nombre o etiqueta).
                final q = _q.trim().toLowerCase();
                final items = q.isEmpty
                    ? base
                    : base
                        .where((u) =>
                            u.nombre.toLowerCase().contains(q) ||
                            u.etiquetaCompleta.toLowerCase().contains(q))
                        .toList();
                if (items.isEmpty) {
                  if (widget.filtroEmpresaId != null && !_mostrarTodas) {
                    return const AppEmptyState(
                      icon: Icons.place_outlined,
                      title: 'Sin ubicaciones de esta empresa',
                      subtitle:
                          'Tocá "Mostrar todas" arriba para ver todas las '
                          'ubicaciones, o asociá ubicaciones a esta empresa '
                          'desde el catálogo Ubicaciones.',
                    );
                  }
                  return const AppEmptyState(
                    icon: Icons.place_outlined,
                    title: 'Sin ubicaciones activas',
                    subtitle: 'Cargá una desde el catálogo Ubicaciones.',
                  );
                }
                return ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                      AppSpacing.xs, AppSpacing.lg, AppSpacing.xl),
                  itemCount: items.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.xs),
                  itemBuilder: (_, i) {
                    final u = items[i];
                    return AppCard(
                      tier: 1,
                      onTap: () => Navigator.pop(ctx, u),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
                      child: Row(
                        children: [
                          Icon(Icons.place, color: c.brandSoft, size: 18),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.nombre,
                                  style: AppType.body.copyWith(
                                    color: c.text,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  u.etiquetaCompleta,
                                  style: AppType.monoSm
                                      .copyWith(color: c.textMuted),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right,
                              color: c.textMuted, size: 18),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SELECTOR DE PRODUCTO — pills de los productos de la empresa origen
// (opcional). Si no se elige ninguno, la tarifa es "general" para esa ruta.
// =============================================================================

class _SelectorProducto extends StatelessWidget {
  final List<String> productos;
  final String? valor;
  final ValueChanged<String?> onChange;

  const _SelectorProducto({
    required this.productos,
    required this.valor,
    required this.onChange,
  });

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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.inventory_2_outlined, color: c.warning, size: 16),
              const SizedBox(width: AppSpacing.xs),
              const AppEyebrow('Producto (opcional)'),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _PillSelector(
                label: 'Sin especificar',
                seleccionado: valor == null,
                onTap: () => onChange(null),
              ),
              ...productos.map(
                (p) => _PillSelector(
                  label: p,
                  seleccionado: valor == p,
                  onTap: () => onChange(p),
                ),
              ),
            ],
          ),
          if (valor == null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Tarifa general para esta ruta (cualquier producto).',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// PRECIO Y VIGENCIA (solo edición) — precio vigente hoy + "Registrar nuevo
// precio" (con fecha) + historial de cambios. Reemplaza a la sección "Tarifas"
// editable: el precio se versiona, no se pisa (pedido Santiago 2026-06).
// =============================================================================

String _fmtFechaDDMMAAAA(DateTime d) => '${d.day.toString().padLeft(2, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-${d.year}';

class _SeccionPrecioVigencia extends StatelessWidget {
  final TarifaLogistica tarifa;
  final TipoCargaLogistica tipoCarga;

  /// Llamado tras registrar un precio con la cantidad de viajes recalculados
  /// (para que el padre refresque la tarifa y muestre el SnackBar).
  final void Function(int recalculados) onRegistrado;

  const _SeccionPrecioVigencia({
    required this.tarifa,
    required this.tipoCarga,
    required this.onRegistrado,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hoy = tarifa.vigenteEn(DateTime.now());
    final sufijo = tarifa.unidadTarifa.sufijoMonto;
    final historial = tarifa.vigencias.reversed.toList(); // más reciente arriba
    return _Seccion(
      numero: 5,
      titulo: 'Precio y vigencia',
      accentDot: c.success,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            color: c.surface1,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            border: Border.all(color: c.border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const AppEyebrow('Precio vigente hoy'),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Vecchi: \$${AppFormatters.formatearMonto(hoy.tarifaReal)}$sufijo',
                style: AppType.mono
                    .copyWith(color: c.success, fontWeight: FontWeight.w600),
              ),
              Text(
                hoy.montoFijoChofer != null
                    ? 'Chofer: \$${AppFormatters.formatearMonto(hoy.montoFijoChofer!)}/viaje (fijo)'
                    : 'Chofer: \$${AppFormatters.formatearMonto(hoy.tarifaChofer)}$sufijo',
                style: AppType.mono
                    .copyWith(color: c.info, fontWeight: FontWeight.w600),
              ),
              if (tipoCarga == TipoCargaLogistica.terceros) ...[
                const SizedBox(height: 2),
                Text(
                  hoy.montoFijoDador != null
                      ? 'Dador: \$${AppFormatters.formatearMonto(hoy.montoFijoDador!)}/viaje'
                      : hoy.porcentajeComisionDador != null
                          ? 'Dador: ${hoy.porcentajeComisionDador!.toStringAsFixed(1)}%'
                          : 'Dador: —',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                'Desde el ${_fmtFechaDDMMAAAA(hoy.desde)}',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        AppButton.primary(
          label: 'Registrar nuevo precio',
          icon: Icons.add,
          expand: true,
          onPressed: () async {
            final n = await showModalBottomSheet<int>(
              context: context,
              isScrollControlled: true,
              backgroundColor: c.surface1,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
              ),
              builder: (_) => _SheetNuevoPrecio(
                tarifaId: tarifa.id,
                tipoCarga: tipoCarga,
                vigenteActual: hoy,
              ),
            );
            if (n != null) onRegistrado(n);
          },
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppEyebrow('Historial de precios'),
        const SizedBox(height: AppSpacing.sm),
        ...historial.map((v) {
          final esVigente = identical(v, hoy);
          return Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.xs),
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.sm),
            decoration: BoxDecoration(
              color: c.surface2,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: esVigente ? c.success.withValues(alpha: 0.5) : c.border,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Desde ${_fmtFechaDDMMAAAA(v.desde)}',
                        style: AppType.bodySm.copyWith(
                            color: c.text, fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (esVigente)
                      Text('VIGENTE',
                          style: AppType.monoSm.copyWith(
                              color: c.success, fontWeight: FontWeight.w700)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  'Vecchi \$${AppFormatters.formatearMonto(v.tarifaReal)}$sufijo  ·  '
                  '${v.montoFijoChofer != null ? "Chofer \$${AppFormatters.formatearMonto(v.montoFijoChofer!)}/viaje" : "Chofer \$${AppFormatters.formatearMonto(v.tarifaChofer)}$sufijo"}',
                  style: AppType.monoSm.copyWith(color: c.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        }),
      ],
    );
  }
}

/// Bottom sheet para registrar un nuevo precio (vigencia) de una tarifa.
/// Precarga los campos con el precio vigente. Al confirmar llama a
/// `LogisticaService.registrarNuevoPrecio` y devuelve (pop) la cantidad de
/// viajes recalculados.
class _SheetNuevoPrecio extends StatefulWidget {
  final String tarifaId;
  final TipoCargaLogistica tipoCarga;
  final TarifaVigencia vigenteActual;
  const _SheetNuevoPrecio({
    required this.tarifaId,
    required this.tipoCarga,
    required this.vigenteActual,
  });

  @override
  State<_SheetNuevoPrecio> createState() => _SheetNuevoPrecioState();
}

class _SheetNuevoPrecioState extends State<_SheetNuevoPrecio> {
  late final TextEditingController _realCtrl;
  late final TextEditingController _choferCtrl;
  late final TextEditingController _montoFijoChoferCtrl;
  late final TextEditingController _comisionCtrl;
  late final TextEditingController _montoFijoDadorCtrl;
  late bool _modoMontoFijoChofer;
  late bool _modoMontoFijoDador;
  DateTime _fecha = DateTime.now();
  bool _guardando = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final v = widget.vigenteActual;
    _realCtrl = TextEditingController(
        text:
            v.tarifaReal > 0 ? AppFormatters.formatearMonto(v.tarifaReal) : '');
    _choferCtrl = TextEditingController(
        text: v.tarifaChofer > 0
            ? AppFormatters.formatearMonto(v.tarifaChofer)
            : '');
    _modoMontoFijoChofer = v.montoFijoChofer != null;
    _montoFijoChoferCtrl = TextEditingController(
        text: v.montoFijoChofer != null
            ? AppFormatters.formatearMonto(v.montoFijoChofer!)
            : '');
    _modoMontoFijoDador = v.montoFijoDador != null;
    _comisionCtrl = TextEditingController(
        text: v.porcentajeComisionDador != null
            ? v.porcentajeComisionDador!.toStringAsFixed(1)
            : '');
    _montoFijoDadorCtrl = TextEditingController(
        text: v.montoFijoDador != null
            ? AppFormatters.formatearMonto(v.montoFijoDador!)
            : '');
  }

  @override
  void dispose() {
    _realCtrl.dispose();
    _choferCtrl.dispose();
    _montoFijoChoferCtrl.dispose();
    _comisionCtrl.dispose();
    _montoFijoDadorCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickFecha() async {
    final hoy = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _fecha,
      firstDate: DateTime(hoy.year - 2),
      lastDate: DateTime(hoy.year + 2),
      helpText: 'Vigente desde',
    );
    if (d != null) setState(() => _fecha = d);
  }

  Future<void> _guardar() async {
    setState(() => _error = null);
    final real = AppFormatters.parsearMonto(_realCtrl.text) ?? 0;
    final chofer = _modoMontoFijoChofer
        ? 0.0
        : (AppFormatters.parsearMonto(_choferCtrl.text) ?? 0);
    double? montoFijoChofer;
    if (_modoMontoFijoChofer) {
      montoFijoChofer = AppFormatters.parsearMonto(_montoFijoChoferCtrl.text);
      if (montoFijoChofer == null || montoFijoChofer <= 0) {
        setState(() => _error = 'Cargá el monto fijo del chofer (mayor a 0).');
        return;
      }
    }
    double? comision;
    double? montoFijoDador;
    if (widget.tipoCarga == TipoCargaLogistica.terceros) {
      if (_modoMontoFijoDador) {
        montoFijoDador = AppFormatters.parsearMonto(_montoFijoDadorCtrl.text);
        if (montoFijoDador == null || montoFijoDador <= 0) {
          setState(() => _error = 'Cargá el monto fijo del dador (mayor a 0).');
          return;
        }
      } else if (_comisionCtrl.text.trim().isNotEmpty) {
        comision =
            double.tryParse(_comisionCtrl.text.trim().replaceAll(',', '.'));
        if (comision == null || comision < 0 || comision > 100) {
          setState(() => _error = 'La comisión debe estar entre 0 y 100.');
          return;
        }
      }
    }
    setState(() => _guardando = true);
    try {
      final n = await LogisticaService.registrarNuevoPrecio(
        id: widget.tarifaId,
        desde: _fecha,
        tarifaReal: real,
        tarifaChofer: chofer,
        montoFijoChofer: montoFijoChofer,
        porcentajeComisionDador: comision,
        montoFijoDador: montoFijoDador,
      );
      if (mounted) Navigator.pop(context, n);
    } catch (e) {
      setState(() {
        _guardando = false;
        _error = e.toString().replaceFirst(RegExp(r'^[A-Z][a-z]+: '), '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
              ),
            ),
            const AppEyebrow('Registrar nuevo precio'),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'No borra el precio anterior — queda en el historial. Al subir '
              'la tarifa real, los viajes no liquidados se recalculan según su '
              'fecha de carga. El pago al chofer de viajes ya cargados NO '
              'cambia (el cambio igual queda registrado en el historial).',
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
            const SizedBox(height: AppSpacing.lg),
            InkWell(
              onTap: _pickFecha,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: AppSpacing.md),
                decoration: BoxDecoration(
                  color: c.surface2,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.border),
                ),
                child: Row(
                  children: [
                    Icon(Icons.event, size: 18, color: c.textMuted),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const AppEyebrow('Vigente desde'),
                          const SizedBox(height: 2),
                          Text(
                            _fmtFechaDDMMAAAA(_fecha),
                            style: AppType.body.copyWith(
                                color: c.text, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.edit_outlined, size: 16, color: c.textMuted),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _realCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AppFormatters.inputMilesDecimal],
              style: AppType.mono
                  .copyWith(color: c.text, fontWeight: FontWeight.w600),
              decoration: _inputDecoration(context,
                  labelText: 'Tarifa real (lo que cobra Vecchi)',
                  prefixText: '\$ '),
            ),
            const SizedBox(height: AppSpacing.md),
            const AppEyebrow('Pago al chofer'),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                _PillSelector(
                  label: '18% sobre tarifa chofer',
                  seleccionado: !_modoMontoFijoChofer,
                  onTap: () => setState(() => _modoMontoFijoChofer = false),
                ),
                _PillSelector(
                  label: 'Monto fijo por viaje',
                  seleccionado: _modoMontoFijoChofer,
                  onTap: () => setState(() => _modoMontoFijoChofer = true),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller:
                  _modoMontoFijoChofer ? _montoFijoChoferCtrl : _choferCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [AppFormatters.inputMilesDecimal],
              style: AppType.mono
                  .copyWith(color: c.text, fontWeight: FontWeight.w600),
              decoration: _inputDecoration(context,
                  labelText: _modoMontoFijoChofer
                      ? 'Monto fijo al chofer (por viaje)'
                      : 'Tarifa chofer (lo que se le paga)',
                  prefixText: '\$ '),
            ),
            if (widget.tipoCarga == TipoCargaLogistica.terceros) ...[
              const SizedBox(height: AppSpacing.md),
              const AppEyebrow('Comisión del dador'),
              const SizedBox(height: AppSpacing.sm),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  _PillSelector(
                    label: 'Porcentaje (%)',
                    seleccionado: !_modoMontoFijoDador,
                    onTap: () => setState(() => _modoMontoFijoDador = false),
                  ),
                  _PillSelector(
                    label: 'Monto fijo por viaje',
                    seleccionado: _modoMontoFijoDador,
                    onTap: () => setState(() => _modoMontoFijoDador = true),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              if (_modoMontoFijoDador)
                TextField(
                  controller: _montoFijoDadorCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [AppFormatters.inputMilesDecimal],
                  style: AppType.mono.copyWith(color: c.text),
                  decoration: _inputDecoration(context,
                      labelText: 'Monto fijo del dador (por viaje)',
                      prefixText: '\$ ',
                      suffixText: '/viaje'),
                )
              else
                TextField(
                  controller: _comisionCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
                  ],
                  style: AppType.mono.copyWith(color: c.text),
                  decoration: _inputDecoration(context,
                      labelText: 'Comisión del dador (%)',
                      hintText: 'Ej. 12.5',
                      suffixText: '%'),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(_error!, style: AppType.bodySm.copyWith(color: c.error)),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: AppButton.secondary(
                    label: 'Cancelar',
                    expand: true,
                    onPressed: _guardando ? null : () => Navigator.pop(context),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  flex: 2,
                  child: AppButton.primary(
                    label: 'Registrar precio',
                    icon: Icons.check,
                    expand: true,
                    isLoading: _guardando,
                    onPressed: _guardando ? null : _guardar,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
