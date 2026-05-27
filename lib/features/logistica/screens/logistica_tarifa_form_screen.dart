import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../models/empresa_logistica.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_service.dart';

/// Form full-screen para alta y edición de tarifas. Diseñado como un
/// flujo lineal arriba-abajo:
///
/// 1) Tipo de carga (PROPIA / TERCEROS) → si es TERCEROS aparece el
///    bloque "Dador + comisión".
/// 2) Origen (empresa + ubicación).
/// 3) Destino (empresa + ubicación).
/// 4) Modalidad (flete origen/destino + unidad TN/VIAJE).
/// 5) Tarifas (real + chofer).
/// 6) Notas (opcional).
///
/// Si recibe `arguments={'tarifaId': '...'}` carga la tarifa para
/// editar; si no, es alta.
class LogisticaTarifaFormScreen extends StatefulWidget {
  /// Si es null, el form arranca en modo "alta". Si trae un id, se
  /// carga la tarifa de Firestore y se permite "modificar precio"
  /// (que internamente desactiva la vieja y crea una nueva — para
  /// preservar histórico).
  final String? tarifaId;

  const LogisticaTarifaFormScreen({super.key, this.tarifaId});

  @override
  State<LogisticaTarifaFormScreen> createState() =>
      _LogisticaTarifaFormScreenState();
}

class _LogisticaTarifaFormScreenState
    extends State<LogisticaTarifaFormScreen> {
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
  /// sobre `tarifaChofer × TN`. Pedido Santiago 2026-05-19: para
  /// viajes cortos donde acuerda un monto a mano con el chofer. Si el
  /// toggle [_modoMontoFijoChofer] está OFF, este controller no se
  /// usa al guardar (queda null en Firestore → cálculo legacy).
  final _montoFijoChoferCtrl = TextEditingController();
  /// `true` → la tarifa del chofer se acuerda como monto fijo por
  /// viaje (sin TN ni 18%). `false` → comportamiento histórico (18%
  /// sobre `tarifaChofer × TN`).
  bool _modoMontoFijoChofer = false;
  final _notasCtrl = TextEditingController();
  /// Producto que se transporta. Opcional — null = tarifa "general"
  /// para esa ruta. Lista de opciones viene del catálogo de productos
  /// de la empresa origen seleccionada.
  String? _producto;

  // ─── Estado de carga ───
  bool _cargando = true;
  bool _guardando = false;
  String? _error;

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
      final snap = await LogisticaService.tarifasCol
          .doc(widget.tarifaId!)
          .get();
      if (!snap.exists) {
        setState(() {
          _cargando = false;
          _error = 'La tarifa no existe.';
        });
        return;
      }
      final t = TarifaLogistica.fromMap(snap.id, snap.data()!);
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
        _comisionCtrl.text =
            t.porcentajeComisionDador!.toStringAsFixed(1);
      }
      if (t.montoFijoDador != null) {
        _modoMontoFijoDador = true;
        _montoFijoDadorCtrl.text =
            AppFormatters.formatearMonto(t.montoFijoDador!);
      }
      _notasCtrl.text = t.notas ?? '';
      _producto = t.producto;

      // Resolver referencias a empresas/ubicaciones por id (para mostrar
      // los dropdowns con la opción seleccionada). Si el doc fue
      // borrado, lo dejamos null y el operador tendrá que re-elegir.
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
        _dador =
            EmpresaLogistica.fromMap(futures[4].id, futures[4].data()!);
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
          ? const Center(child: CircularProgressIndicator())
          : _buildForm(),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ─── 1. TIPO DE CARGA ───────────────────────────────────────
          const _SeccionTitulo(numero: 1, texto: 'Tipo de carga'),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                for (final t in TipoCargaLogistica.values) ...[
                  Expanded(
                    child: ChoiceChip(
                      label: Text(t.etiqueta),
                      selected: _tipoCarga == t,
                      onSelected: (sel) {
                        if (sel) {
                          setState(() {
                            _tipoCarga = t;
                            if (t == TipoCargaLogistica.propia) {
                              _dador = null;
                              _comisionCtrl.clear();
                              _montoFijoDadorCtrl.clear();
                              _modoMontoFijoDador = false;
                            }
                          });
                        }
                      },
                      selectedColor:
                          AppColors.success.withValues(alpha: 0.4),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
          ),
          // ─── 1.b DADOR + COMISIÓN (solo si TERCEROS) ────────────────
          if (_tipoCarga == TipoCargaLogistica.terceros) ...[
            const SizedBox(height: 12),
            const _SeccionTitulo(numero: null, texto: 'Dador de transporte'),
            _SelectorEmpresa(
              etiqueta: 'Dador de transporte',
              valor: _dador,
              soloTipo: TipoEmpresaLogistica.dadorTransporte,
              onChange: (e) => setState(() => _dador = e),
            ),
            const SizedBox(height: 8),
            AppCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'COMISIÓN DEL DADOR',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('Porcentaje (%)'),
                        selected: !_modoMontoFijoDador,
                        onSelected: (sel) {
                          if (sel) {
                            setState(() => _modoMontoFijoDador = false);
                          }
                        },
                        selectedColor:
                            AppColors.info.withValues(alpha: 0.4),
                      ),
                      ChoiceChip(
                        label: const Text('Monto fijo por viaje'),
                        selected: _modoMontoFijoDador,
                        onSelected: (sel) {
                          if (sel) {
                            setState(() => _modoMontoFijoDador = true);
                          }
                        },
                        selectedColor:
                            AppColors.warning.withValues(alpha: 0.4),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_modoMontoFijoDador)
                    TextField(
                      controller: _montoFijoDadorCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [AppFormatters.inputMilesDecimal],
                      decoration: const InputDecoration(
                        labelText: 'Monto fijo del dador (por viaje)',
                        prefixText: '\$ ',
                        suffixText: '/viaje',
                      ),
                      style: const TextStyle(
                          color: Colors.white, fontSize: 16),
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
                      decoration: const InputDecoration(
                        labelText: 'Comisión del dador (%)',
                        hintText: 'Ej. 12.5',
                        suffixText: '%',
                      ),
                    ),
                ],
              ),
            ),
          ],

          // ─── 2. ORIGEN ──────────────────────────────────────────────
          const SizedBox(height: 16),
          const _SeccionTitulo(numero: 2, texto: 'Origen'),
          _SelectorEmpresa(
            etiqueta: 'Origen',
            valor: _empOrigen,
            soloTipo: TipoEmpresaLogistica.cliente,
            onChange: (e) => setState(() => _empOrigen = e),
          ),
          const SizedBox(height: 8),
          _SelectorUbicacion(
            etiqueta: 'Ubicación origen',
            valor: _ubicOrigen,
            filtroEmpresaId: _empOrigen?.id,
            onChange: (u) => setState(() => _ubicOrigen = u),
          ),

          // ─── 3. DESTINO ─────────────────────────────────────────────
          const SizedBox(height: 16),
          const _SeccionTitulo(numero: 3, texto: 'Destino'),
          _SelectorEmpresa(
            etiqueta: 'Destino',
            valor: _empDestino,
            soloTipo: TipoEmpresaLogistica.cliente,
            onChange: (e) => setState(() => _empDestino = e),
          ),
          const SizedBox(height: 8),
          _SelectorUbicacion(
            etiqueta: 'Ubicación destino',
            valor: _ubicDestino,
            filtroEmpresaId: _empDestino?.id,
            onChange: (u) => setState(() => _ubicDestino = u),
          ),

          // ─── PRODUCTO (opcional) ─────────────────────────────────
          // La misma ruta puede tener tarifas distintas según el
          // producto que se transporta. Las opciones vienen del
          // catálogo de productos de la empresa origen.
          if (_empOrigen != null && _empOrigen!.productos.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SelectorProducto(
              productos: _empOrigen!.productos,
              valor: _producto,
              onChange: (p) => setState(() => _producto = p),
            ),
          ],

          // ─── 4. MODALIDAD ───────────────────────────────────────────
          const SizedBox(height: 16),
          const _SeccionTitulo(numero: 4, texto: 'Modalidad'),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                // Si origen y destino son la MISMA empresa (ej. de un
                // depósito de Profertil a otro depósito de Profertil),
                // no tiene sentido elegir si paga el origen o el destino
                // — siempre lo paga esa empresa. Mostramos un info chip
                // en lugar del selector. (Santiago 2026-05-14.)
                if (_empOrigen != null &&
                    _empDestino != null &&
                    _empOrigen!.id == _empDestino!.id)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color:
                          AppColors.info.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: AppColors.info
                              .withValues(alpha: 0.4)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 18, color: AppColors.info),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Flete a cargo de ${_empOrigen!.nombre} '
                            '(origen y destino son la misma empresa).',
                            style: const TextStyle(
                              color: AppColors.info,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  _filaSelector<FleteLogistica>(
                    etiqueta: 'Flete pagadero',
                    opciones: FleteLogistica.values,
                    valor: _flete,
                    etiquetaFn: (f) => f.etiqueta,
                    onChange: (f) => setState(() => _flete = f),
                  ),
                const SizedBox(height: 8),
                _filaSelector<UnidadTarifa>(
                  etiqueta: 'Unidad de tarifa',
                  opciones: UnidadTarifa.values,
                  valor: _unidad,
                  etiquetaFn: (u) => u.etiqueta,
                  onChange: (u) => setState(() => _unidad = u),
                ),
              ],
            ),
          ),

          // ─── 5. TARIFAS ─────────────────────────────────────────────
          const SizedBox(height: 16),
          const _SeccionTitulo(numero: 5, texto: 'Tarifas'),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _campoTarifa(
                  controller: _tarifaRealCtrl,
                  etiqueta: 'Tarifa real (lo que cobra Vecchi)',
                  color: AppColors.success,
                ),
                const SizedBox(height: 16),
                // Toggle pago al chofer: 18% sobre la tarifa chofer
                // (default histórico) o monto fijo por viaje (pedido
                // Santiago 2026-05-19 para viajes cortos donde el 18%
                // no cuadra y se acuerda un monto a mano).
                const Text(
                  'PAGO AL CHOFER',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('18% sobre tarifa chofer'),
                      selected: !_modoMontoFijoChofer,
                      onSelected: (sel) {
                        if (sel) {
                          setState(() => _modoMontoFijoChofer = false);
                        }
                      },
                      selectedColor:
                          AppColors.info.withValues(alpha: 0.4),
                    ),
                    ChoiceChip(
                      label: const Text('Monto fijo por viaje'),
                      selected: _modoMontoFijoChofer,
                      onSelected: (sel) {
                        if (sel) {
                          setState(() => _modoMontoFijoChofer = true);
                        }
                      },
                      selectedColor:
                          AppColors.warning.withValues(alpha: 0.4),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_modoMontoFijoChofer) ...[
                  _campoMontoFijoChofer(),
                  // En modo monto fijo NO se muestra la tarifa chofer (%): el
                  // chofer cobra el monto fijo y la tarifa_chofer queda en 0
                  // (pedido Santiago 2026-05-21 — antes confundía y bloqueaba
                  // el guardado al quedar en 0).
                ] else ...[
                  _campoTarifa(
                    controller: _tarifaChoferCtrl,
                    etiqueta: 'Tarifa chofer (lo que se le paga)',
                    color: AppColors.info,
                  ),
                ],
              ],
            ),
          ),

          // ─── 6. NOTAS ───────────────────────────────────────────────
          const SizedBox(height: 16),
          const _SeccionTitulo(numero: 6, texto: 'Notas (opcional)'),
          AppCard(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _notasCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                hintText:
                    'Ej. Cliente exige descarga antes de las 14 hs.',
                border: InputBorder.none,
              ),
            ),
          ),

          // ─── ERROR ──────────────────────────────────────────────────
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.error.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: AppColors.error.withValues(alpha: 0.4),
                ),
              ),
              child: Text(
                _error!,
                style: const TextStyle(color: AppColors.error),
              ),
            ),
          ],

          // ─── ACCIONES ───────────────────────────────────────────────
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed:
                      _guardando ? null : () => Navigator.pop(context),
                  child: const Text('CANCELAR'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: _guardando ? null : _guardar,
                  icon: _guardando
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(
                    _esEdicion ? 'GUARDAR CAMBIOS' : 'GUARDAR TARIFA',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.success,
                  ),
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
      decoration: InputDecoration(
        labelText: etiqueta,
        prefixText: '\$ ',
        prefixStyle: TextStyle(color: color, fontWeight: FontWeight.bold),
        suffixText: _unidad.sufijoMonto,
      ),
      style: const TextStyle(color: Colors.white, fontSize: 16),
    );
  }

  /// Campo dedicado al monto fijo del chofer — flat por viaje, no
  /// arrastra el sufijo de unidad (`/TN` o `/viaje`) porque su unidad
  /// es siempre "por viaje" independientemente de [_unidad].
  Widget _campoMontoFijoChofer() {
    return TextField(
      controller: _montoFijoChoferCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [AppFormatters.inputMilesDecimal],
      decoration: const InputDecoration(
        labelText: 'Monto fijo al chofer (por viaje)',
        prefixText: '\$ ',
        prefixStyle: TextStyle(
          color: AppColors.warning,
          fontWeight: FontWeight.bold,
        ),
        suffixText: '/viaje',
      ),
      style: const TextStyle(color: Colors.white, fontSize: 16),
    );
  }

  Widget _filaSelector<T>({
    required String etiqueta,
    required List<T> opciones,
    required T valor,
    required String Function(T) etiquetaFn,
    required ValueChanged<T> onChange,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          etiqueta.toUpperCase(),
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: [
            for (final op in opciones)
              ChoiceChip(
                label: Text(etiquetaFn(op)),
                selected: op == valor,
                onSelected: (sel) {
                  if (sel) onChange(op);
                },
                selectedColor:
                    AppColors.success.withValues(alpha: 0.4),
              ),
          ],
        ),
      ],
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
    // Tarifas con monto = 0 ahora son válidas (Santiago 2026-05-14):
    // muchas veces no se sabe el monto hasta que el viaje termina, y
    // necesitamos poder armar el viaje con la tarifa "preliminar".
    // Cuando se actualice la tarifa con el monto real, basta con
    // editar el viaje y guardar — el snapshot se refresca solo
    // (ver `TarifaSnapshot.fromTarifa` en el form de viaje).
    //
    // El parser devuelve null si está vacío o no parsea — lo
    // tratamos como 0 (tarifa por definir).
    final tarifaReal = AppFormatters.parsearMonto(_tarifaRealCtrl.text) ?? 0;
    // En modo "monto fijo por viaje" la tarifa_chofer (%) no se usa → 0: el
    // chofer cobra el monto fijo. Así no bloquea el guardado ni deja un %
    // viejo confuso (pedido Santiago 2026-05-21).
    final tarifaChofer = _modoMontoFijoChofer
        ? 0.0
        : (AppFormatters.parsearMonto(_tarifaChoferCtrl.text) ?? 0);
    if (tarifaReal < 0 || tarifaChofer < 0) {
      setState(() => _error = 'Las tarifas no pueden ser negativas.');
      return;
    }
    // La validación "chofer no puede superar real" sigue valiendo —
    // pero solo cuando AMBOS están definidos (ambos > 0). Si alguno
    // es 0 (por definir), no hay nada que comparar.
    if (tarifaReal > 0 && tarifaChofer > 0 && tarifaChofer > tarifaReal) {
      setState(() => _error =
          'La tarifa del chofer no puede superar la tarifa real.');
      return;
    }
    // Si el operador eligió "monto fijo por viaje", parseamos y
    // validamos. Si está vacío o = 0, error — sino la tarifa quedaría
    // ambigua entre "modo monto fijo" y "no se cargó nada".
    double? montoFijoChofer;
    if (_modoMontoFijoChofer) {
      montoFijoChofer =
          AppFormatters.parsearMonto(_montoFijoChoferCtrl.text);
      if (montoFijoChofer == null || montoFijoChofer <= 0) {
        setState(() => _error =
            'Cargá el monto fijo del chofer (debe ser mayor a 0).');
        return;
      }
    }

    // Si origen y destino son la misma empresa, el campo `_flete` no
    // se le pide al operador. Normalizamos a `origen` para tener data
    // consistente — semánticamente da igual (mismo empresa paga).
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
        montoFijoDador =
            AppFormatters.parsearMonto(_montoFijoDadorCtrl.text);
        if (montoFijoDador == null || montoFijoDador <= 0) {
          setState(() => _error =
              'Cargá el monto fijo del dador (debe ser mayor a 0).');
          return;
        }
      } else if (_comisionCtrl.text.trim().isNotEmpty) {
        // Aceptamos coma o punto como separador decimal (input AR).
        final raw = _comisionCtrl.text.trim().replaceAll(',', '.');
        comision = double.tryParse(raw);
        if (comision == null || comision < 0 || comision > 100) {
          setState(() =>
              _error = 'El % de comisión debe estar entre 0 y 100.');
          return;
        }
      }
    }

    setState(() => _guardando = true);
    try {
      if (_esEdicion) {
        // Modo edición: si cambió alguna tarifa, conviene crear una
        // nueva para preservar histórico (la práctica recomendada). Si
        // solo cambió notas / tipo / etc, hacemos update directo.
        // Para simplificar la primera versión: hacemos update directo
        // siempre, y dejamos la creación de "nueva versión" como flujo
        // explícito (botón "Modificar precio") en una iteración futura.
        await LogisticaService.actualizarTarifa(
          id: widget.tarifaId!,
          cambios: {
            'tipo_carga': _tipoCarga.codigo,
            'dador_id': _dador?.id,
            'dador_nombre': _dador?.nombre,
            'porcentaje_comision_dador': comision,
            'monto_fijo_dador': montoFijoDador,
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
            'tarifa_real': tarifaReal,
            'tarifa_chofer': tarifaChofer,
            // Si el operador cambió a modo "monto fijo": guarda el
            // valor. Si lo deshabilitó: setea explícito a null para
            // que la tarifa vuelva al cálculo 18%.
            'monto_fijo_chofer': montoFijoChofer,
            // BUGFIX 2026-05-21: el producto no se incluía en la edición →
            // al reabrir aparecía desasignado. null = lo limpia (correcto).
            'producto': _producto,
            'notas': _notasCtrl.text.trim().isEmpty
                ? null
                : _notasCtrl.text.trim(),
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
// SELECTORES — bottom sheets que muestran la lista de catálogo activa
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
    return AppCard(
      onTap: () => _abrirSelector(context),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.business_outlined,
              color: Colors.white54, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etiqueta.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  valor?.etiquetaPrincipal ?? 'Seleccionar...',
                  style: TextStyle(
                    color: valor == null ? Colors.white38 : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (valor?.etiquetaSecundaria != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      valor!.etiquetaSecundaria!,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ],
      ),
    );
  }

  Future<void> _abrirSelector(BuildContext context) async {
    final res = await showModalBottomSheet<EmpresaLogistica>(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
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
    return TextField(
      onChanged: onChanged,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        prefixIcon:
            const Icon(Icons.search, color: Colors.white54, size: 20),
        isDense: true,
        filled: true,
        fillColor: AppColors.surface,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
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
    final soloTipo = widget.soloTipo;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              soloTipo == TipoEmpresaLogistica.dadorTransporte
                  ? 'SELECCIONAR DADOR'
                  : 'SELECCIONAR EMPRESA',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _BuscadorField(
              hint: 'Buscar empresa...',
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
                  return const Center(child: CircularProgressIndicator());
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
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final e = items[i];
                    return AppCard(
                      onTap: () => Navigator.pop(ctx, e),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.business,
                              color: AppColors.info),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.etiquetaPrincipal,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (e.etiquetaSecundaria != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(
                                      e.etiquetaSecundaria!,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: Colors.white38),
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
  /// Si está seteado, el sheet de selección filtra a las ubicaciones
  /// asociadas a esa empresa (más rápido encontrar para el operador).
  /// El sheet además ofrece un toggle "Mostrar todas" por si la
  /// ubicación todavía no fue asociada.
  final String? filtroEmpresaId;

  const _SelectorUbicacion({
    required this.etiqueta,
    required this.valor,
    required this.onChange,
    this.filtroEmpresaId,
  });

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: () => _abrir(context),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.place_outlined,
              color: Colors.white54, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  etiqueta.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  valor?.nombre ?? 'Seleccionar...',
                  style: TextStyle(
                    color: valor == null ? Colors.white38 : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (valor != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    valor!.etiquetaCompleta,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white38),
        ],
      ),
    );
  }

  Future<void> _abrir(BuildContext context) async {
    final res = await showModalBottomSheet<UbicacionLogistica>(
      context: context,
      backgroundColor: AppColors.background,
      isScrollControlled: true,
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
  /// Si el operador toggleó "Mostrar todas", desactivamos el filtro
  /// por empresa. Útil cuando la ubicación deseada aún no fue
  /// asociada a la empresa.
  bool _mostrarTodas = false;
  String _q = '';

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      minChildSize: 0.4,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Text(
                  'SELECCIONAR UBICACIÓN',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                if (widget.filtroEmpresaId != null)
                  FilterChip(
                    label: Text(
                      _mostrarTodas ? 'Mostrar solo de la empresa' : 'Mostrar todas',
                      style: const TextStyle(fontSize: 11),
                    ),
                    selected: _mostrarTodas,
                    onSelected: (v) =>
                        setState(() => _mostrarTodas = v),
                    selectedColor:
                        AppColors.info.withValues(alpha: 0.4),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _BuscadorField(
              hint: 'Buscar ubicación...',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: StreamBuilder<List<UbicacionLogistica>>(
              stream:
                  LogisticaService.streamUbicaciones(soloActivas: true),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                final all = snap.data ?? const [];
                // Filtrar por empresa si el caller pasó filtroEmpresaId
                // y el usuario NO toggleó "Mostrar todas".
                // M:N: una ubicación puede pertenecer a varias
                // empresas. Filtrar por array-contains client-side
                // (el catálogo es chico, no vale la pena un índice
                // Firestore para esto).
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
                          'ubicaciones, o asociá ubicaciones a esta '
                          'empresa desde el catálogo Ubicaciones.',
                    );
                  }
                  return const AppEmptyState(
                    icon: Icons.place_outlined,
                    title: 'Sin ubicaciones activas',
                    subtitle:
                        'Cargá una desde el catálogo Ubicaciones.',
                  );
                }
                return ListView.separated(
                  controller: controller,
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final u = items[i];
                    return AppCard(
                      onTap: () => Navigator.pop(ctx, u),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      child: Row(
                        children: [
                          const Icon(Icons.place,
                              color: AppColors.accentTeal),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.nombre,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                Text(
                                  u.etiquetaCompleta,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: Colors.white38),
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
// SECCIÓN TÍTULO
// =============================================================================

class _SeccionTitulo extends StatelessWidget {
  final int? numero;
  final String texto;
  const _SeccionTitulo({required this.numero, required this.texto});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
      child: Row(
        children: [
          if (numero != null) ...[
            Container(
              width: 22,
              height: 22,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.success.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: Text(
                '$numero',
                style: const TextStyle(
                  color: AppColors.success,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Text(
            texto.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// SELECTOR DE PRODUCTO — dropdown de los productos de la empresa
// origen (opcional). Si no se elige ninguno, la tarifa es "general"
// para esa ruta sin distinguir producto.
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
    return AppCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.inventory_2_outlined,
                  color: AppColors.warning, size: 16),
              SizedBox(width: 6),
              Text(
                'PRODUCTO (OPCIONAL)',
                style: TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Sin especificar'),
                selected: valor == null,
                onSelected: (v) {
                  if (v) onChange(null);
                },
                selectedColor:
                    AppColors.warning.withValues(alpha: 0.4),
              ),
              ...productos.map(
                (p) => ChoiceChip(
                  label: Text(p),
                  selected: valor == p,
                  onSelected: (v) {
                    if (v) onChange(p);
                  },
                  selectedColor:
                      AppColors.warning.withValues(alpha: 0.4),
                ),
              ),
            ],
          ),
          if (valor == null)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Tarifa general para esta ruta (cualquier producto).',
                style: TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}
