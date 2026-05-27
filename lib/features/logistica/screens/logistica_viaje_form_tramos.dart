// =============================================================================
// TRAMOS — un viaje multi-tramo tiene una lista de _TramoCard.
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// Componentes:
//   - _TramoEditState  — estado mutable de UN tramo (controllers + datos).
//   - _TramoCard       — UI de un tramo (carga + descarga + producto + gastos).
//   - _BotonAgregarTramo — botón "+ AGREGAR TRAMO" debajo de la lista.
//   - _BannerEncadenamiento — warning amarillo cuando fechas no encadenan.
//   - _DropdownProducto — dropdown poblado con productos de la empresa origen.

part of 'logistica_viaje_form_screen.dart';

class _TramoEditState {
  /// Identificador local estable (para el ValueKey de Flutter).
  final String id;

  TarifaLogistica? tarifa;
  String? producto;
  /// Controller del campo "producto libre" — solo se usa cuando la
  /// empresa origen NO tiene productos catalogados (fallback). Vive
  /// en el state del tramo (no se recrea en cada build) para no
  /// perder el foco al tipear.
  final TextEditingController productoLibreCtrl;
  /// Override "monto fijo del chofer" a nivel TRAMO. Si `true`, este
  /// tramo paga al chofer el valor de [montoFijoChoferCtrl] (flat,
  /// sin TN ni 18%). Si `false`, calcula con el 18% sobre la tarifa
  /// chofer. Se inicializa siguiendo a la tarifa elegida — si la
  /// tarifa ya tiene `montoFijoChofer`, arranca activado y precargado
  /// con ese valor. Pedido Santiago 2026-05-19.
  bool montoFijoChoferActivo;
  final TextEditingController montoFijoChoferCtrl;
  final TextEditingController descripcionCargaCtrl;
  DateTime? fechaCarga;
  final TextEditingController kgCargadosCtrl;

  DateTime? fechaDescarga;
  final TextEditingController remitoNumeroCtrl;
  final TextEditingController kgDescargadosCtrl;
  String? remitoUrl;
  String? remitoPathStorage;
  String? remitoNombreLocal;
  Uint8List? remitoBytesPendientes;
  String? remitoExtPendiente;
  String? remitoMimePendiente;

  /// Gastos extraordinarios del tramo (peajes, lavado, viáticos, etc.)
  /// — desde 2026-05-13 viven por tramo, no por viaje.
  List<GastoViaje> gastos;

  _TramoEditState._({
    required this.id,
    this.tarifa,
    this.producto,
    String? descripcionCarga,
    this.fechaCarga,
    String? kgCargados,
    this.fechaDescarga,
    String? remitoNumero,
    String? kgDescargados,
    this.remitoUrl,
    this.remitoPathStorage,
    List<GastoViaje>? gastos,
    double? montoFijoChoferInicial,
  })  : productoLibreCtrl = TextEditingController(text: producto ?? ''),
        montoFijoChoferActivo = montoFijoChoferInicial != null,
        montoFijoChoferCtrl = TextEditingController(
          text: montoFijoChoferInicial != null
              ? AppFormatters.formatearMonto(montoFijoChoferInicial)
              : '',
        ),
        descripcionCargaCtrl =
            TextEditingController(text: descripcionCarga ?? ''),
        kgCargadosCtrl = TextEditingController(text: kgCargados ?? ''),
        remitoNumeroCtrl = TextEditingController(text: remitoNumero ?? ''),
        kgDescargadosCtrl = TextEditingController(text: kgDescargados ?? ''),
        gastos = gastos ?? [];

  factory _TramoEditState.vacio() {
    return _TramoEditState._(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
    );
  }

  // `cloneFrom` se quitó 2026-05-14 junto con el botón "duplicar tramo"
  // (ver _TramoCard). Si vuelve a necesitarse, copiaba: tarifa, producto
  // y descripcionCarga — fechas/kg/remito quedaban vacíos.

  factory _TramoEditState.fromTramoViaje(
    TramoViaje t,
    TarifaLogistica? tarifaResuelta,
  ) {
    return _TramoEditState._(
      id: t.id,
      tarifa: tarifaResuelta,
      producto: t.producto,
      descripcionCarga: t.descripcionCarga,
      fechaCarga: t.fechaCarga,
      kgCargados: t.kgCargados == null
          ? null
          : AppFormatters.formatearMiles(t.kgCargados!.toInt()),
      fechaDescarga: t.fechaDescarga,
      remitoNumero: t.remitoNumero,
      kgDescargados: t.kgDescargados == null
          ? null
          : AppFormatters.formatearMiles(t.kgDescargados!.toInt()),
      remitoUrl: t.remitoUrl,
      remitoPathStorage: t.remitoPathStorage,
      gastos: List.of(t.gastos),
      // El snapshot del tramo manda — puede tener un override del
      // operador distinto al de la tarifa origen. Si snapshot es null
      // (no se usó monto fijo) arranca en modo 18%.
      montoFijoChoferInicial: t.tarifaSnapshot.montoFijoChofer,
    );
  }

  void dispose() {
    productoLibreCtrl.dispose();
    montoFijoChoferCtrl.dispose();
    descripcionCargaCtrl.dispose();
    kgCargadosCtrl.dispose();
    remitoNumeroCtrl.dispose();
    kgDescargadosCtrl.dispose();
  }

  /// Aplica al `TarifaSnapshot` el override del monto fijo del
  /// operador. Si `montoFijoChoferActivo` y el campo está vacío
  /// (operador activó override pero no escribió monto), devuelve el
  /// snapshot con `montoFijoChofer: null` para que el cálculo no
  /// asuma 0. La validación de "monto fijo obligatorio si activo" se
  /// hace al guardar el viaje.
  TarifaSnapshot snapshotConOverride() {
    final base = TarifaSnapshot.fromTarifa(tarifa!);
    if (!montoFijoChoferActivo) {
      // Explícitamente null para limpiar el override que la tarifa
      // pueda traer — el operador eligió volver al 18%.
      return base.copyWith(montoFijoChofer: null);
    }
    final parsed =
        AppFormatters.parsearMonto(montoFijoChoferCtrl.text);
    if (parsed == null || parsed <= 0) {
      // Activo pero sin valor válido — no aplicar override (queda
      // null y el cálculo cae al 18%). El form valida esto antes de
      // permitir guardar el viaje.
      return base.copyWith(montoFijoChofer: null);
    }
    return base.copyWith(montoFijoChofer: parsed);
  }

  TramoViaje toTramoViaje() {
    final kgC = AppFormatters.parsearMiles(kgCargadosCtrl.text)?.toDouble();
    final kgD = AppFormatters.parsearMiles(kgDescargadosCtrl.text)?.toDouble();
    return TramoViaje(
      id: id,
      tarifaId: tarifa!.id,
      tarifaSnapshot: snapshotConOverride(),
      producto: producto?.trim().isEmpty ?? true ? null : producto!.trim(),
      descripcionCarga: descripcionCargaCtrl.text.trim().isEmpty
          ? null
          : descripcionCargaCtrl.text.trim(),
      fechaCarga: fechaCarga,
      kgCargados: kgC,
      fechaDescarga: fechaDescarga,
      remitoNumero: remitoNumeroCtrl.text.trim().isEmpty
          ? null
          : remitoNumeroCtrl.text.trim(),
      remitoUrl: remitoUrl,
      remitoPathStorage: remitoPathStorage,
      kgDescargados: kgD,
      gastos: List.of(gastos),
    );
  }
}

// =============================================================================
// _TramoCard — un tramo en el form (card con todos sus campos)
// =============================================================================

class _TramoCard extends StatelessWidget {
  final int numero;
  final _TramoEditState state;
  /// Mensaje de warning sobre las fechas del propio tramo (descarga
  /// anterior a carga). Null si no hay problema. Calculado por el
  /// padre, no por este widget — así el padre puede usar la misma
  /// función al guardar para mostrar un resumen.
  final String? warningFechasInternas;
  final bool puedeEliminar;
  final VoidCallback onEliminar;
  final VoidCallback onCambio;

  const _TramoCard({
    super.key,
    required this.numero,
    required this.state,
    required this.warningFechasInternas,
    required this.puedeEliminar,
    required this.onEliminar,
    required this.onCambio,
  });

  Future<void> _pickRemito(BuildContext context) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.first;
    if (f.bytes == null) return;
    final ext = (f.extension ?? 'pdf').toLowerCase();
    final mime = ext == 'pdf' ? 'application/pdf' : 'image/$ext';
    state.remitoBytesPendientes = f.bytes;
    state.remitoExtPendiente = ext;
    state.remitoMimePendiente = mime;
    state.remitoNombreLocal = f.name;
    onCambio();
  }

  @override
  Widget build(BuildContext context) {
    final esTn = state.tarifa?.unidadTarifa == UnidadTarifa.porTonelada;
    final tarifa = state.tarifa;
    return _SeccionCard(
      titulo: 'TRAMO $numero',
      icono: Icons.alt_route_outlined,
      // Botones "↑ ↓ duplicar" del header se quitaron 2026-05-14 por
      // pedido de Santiago — innecesarios en la práctica. Queda solo
      // el "eliminar" para el caso de tramo sobrante.
      trailing: puedeEliminar
          ? IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: AppColors.error, size: 18),
              onPressed: onEliminar,
              tooltip: 'Eliminar tramo',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              padding: const EdgeInsets.all(6),
            )
          : null,
      children: [
        // Warning de fechas internas (descarga < carga). Lo ponemos
        // arriba del todo así el operador lo ve al volver a revisar
        // el tramo. Es NO bloqueante — el guardado igual procede.
        if (warningFechasInternas != null)
          _BannerEncadenamiento(mensaje: warningFechasInternas!),
        // Tarifa. Antes era un DropdownButtonFormField simple — con el
        // catálogo creciendo se volvió impráctico (Santiago 2026-05-13:
        // "hay muchas tarifas creadas"). Ahora es un campo tappeable
        // que abre un modal sheet con buscador token-based filtrando
        // por empresas, ubicaciones y dador, mismo patrón que la
        // lista de tarifas.
        InkWell(
          onTap: () async {
            final elegida = await _abrirSelectorTarifa(
              context,
              tarifaActual: tarifa,
            );
            if (elegida == null) return;
            state.tarifa = elegida;
            // Si cambió la tarifa, reseteamos el producto (porque
            // viene de empresa origen distinta).
            state.producto = null;
            // Sincronizar el override del chofer con la nueva tarifa:
            // si la tarifa elegida tiene `montoFijoChofer`, pre-cargar
            // el modo activado con ese valor. Si no, volver a 18%.
            // El operador después puede cambiar a su gusto en este
            // tramo sin afectar la tarifa origen (override por tramo).
            final fijoTarifa = elegida.montoFijoChofer;
            state.montoFijoChoferActivo = fijoTarifa != null;
            state.montoFijoChoferCtrl.text = fijoTarifa != null
                ? AppFormatters.formatearMonto(fijoTarifa)
                : '';
            onCambio();
          },
          borderRadius: BorderRadius.circular(4),
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: 'Tarifa',
              border: const OutlineInputBorder(),
              suffixIcon: Icon(
                tarifa == null ? Icons.search : Icons.edit_outlined,
                size: 20,
              ),
            ),
            isEmpty: tarifa == null,
            child: tarifa == null
                ? null
                : Text(
                    '${tarifa.ubicacionOrigenEtiqueta} → '
                    '${tarifa.ubicacionDestinoEtiqueta} '
                    '(${tarifa.unidadTarifa.etiqueta})',
                    style: const TextStyle(color: Colors.white),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ),
        if (tarifa != null) ...[
          const SizedBox(height: 8),
          _ResumenTarifa(t: tarifa),
          const SizedBox(height: 12),
          // Override del pago al chofer para ESTE tramo. Útil cuando
          // la tarifa está cargada al 18% pero este viaje paga un
          // monto distinto al chofer (acuerdo a mano). El cambio NO
          // afecta la tarifa origen — vive solo en el snapshot del
          // tramo, así el catálogo de tarifas queda intacto.
          _OverridePagoChofer(state: state, onCambio: onCambio),
        ],
        const SizedBox(height: 12),

        // CARGA — fecha + kg + producto + descripción libre.
        const _SubseccionTitulo('CARGA'),
        const SizedBox(height: 8),
        _BotonFecha(
          label: 'Fecha de carga',
          fecha: state.fechaCarga,
          onChanged: (d) {
            state.fechaCarga = d;
            onCambio();
          },
        ),
        if (esTn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: state.kgCargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg cargados',
              suffixText: 'kg',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onCambio(),
          ),
        ],
        const SizedBox(height: 8),
        // Producto — dropdown poblado con productos de la empresa
        // origen de la tarifa. Si no hay tarifa, queda deshabilitado.
        // Si la empresa NO tiene productos catalogados, cae a texto
        // libre usando `productoLibreCtrl` (persistente del tramo).
        _DropdownProducto(
          empresaOrigenId: tarifa?.empresaOrigenId,
          valor: state.producto,
          libreCtrl: state.productoLibreCtrl,
          onChanged: (p) {
            state.producto = p;
            onCambio();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: state.descripcionCargaCtrl,
          decoration: const InputDecoration(
            labelText: 'Descripción / observación (opcional)',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
          onChanged: (_) => onCambio(),
        ),
        const SizedBox(height: 16),

        // DESCARGA — fecha + remito + comprobante + kg descargados.
        const _SubseccionTitulo('DESCARGA'),
        const SizedBox(height: 8),
        _BotonFecha(
          label: 'Fecha de descarga',
          fecha: state.fechaDescarga,
          onChanged: (d) {
            state.fechaDescarga = d;
            onCambio();
          },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: state.remitoNumeroCtrl,
          decoration: const InputDecoration(
            labelText: 'Número de remito',
            border: OutlineInputBorder(),
          ),
          onChanged: (_) => onCambio(),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _pickRemito(context),
          icon: const Icon(Icons.attach_file, size: 18),
          label: Text(
            state.remitoNombreLocal ??
                (state.remitoUrl != null
                    ? 'Reemplazar comprobante'
                    : 'Subir comprobante firmado (PDF / foto)'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (state.remitoUrl != null && state.remitoNombreLocal == null) ...[
          const SizedBox(height: 4),
          const Text(
            '✓ Comprobante ya cargado.',
            style: TextStyle(color: AppColors.success, fontSize: 11),
          ),
        ],
        if (esTn) ...[
          const SizedBox(height: 8),
          TextField(
            controller: state.kgDescargadosCtrl,
            decoration: const InputDecoration(
              labelText: 'Kg descargados (cifra final para liquidar)',
              suffixText: 'kg',
              border: OutlineInputBorder(),
              helperText:
                  'Si está vacío, se calcula con kg cargados (estimado).',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onCambio(),
          ),
        ],

        // ─── Gastos extraordinarios DEL TRAMO ─────────────────────
        // Cada tramo tiene sus propios gastos (refactor 2026-05-13).
        // Antes vivían a nivel viaje pero un viaje multi-tramo tiene
        // peajes / lavados distintos por tramo, así que se separan.
        const SizedBox(height: 16),
        _SeccionGastos(
          gastos: state.gastos,
          onChanged: (l) {
            state.gastos = l;
            onCambio();
          },
          enmarcadoComoSubseccion: true,
        ),
      ],
    );
  }
}

// =============================================================================
// _OverridePagoChofer — toggle "18% / monto fijo" + campo de monto
// =============================================================================
//
// Vive entre el resumen de tarifa y la sección CARGA. Permite overridear
// el pago al chofer para ESTE tramo sin tocar la tarifa origen del
// catálogo. Pedido Santiago 2026-05-19: viajes cortos donde se acuerda
// un monto a mano con el chofer en vez del 18%.

class _OverridePagoChofer extends StatelessWidget {
  final _TramoEditState state;
  final VoidCallback onCambio;

  const _OverridePagoChofer({
    required this.state,
    required this.onCambio,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PAGO AL CHOFER (ESTE TRAMO)',
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
              label: const Text('18%'),
              selected: !state.montoFijoChoferActivo,
              onSelected: (sel) {
                if (sel) {
                  state.montoFijoChoferActivo = false;
                  onCambio();
                }
              },
              selectedColor: AppColors.accentBlue.withValues(alpha: 0.4),
              visualDensity: VisualDensity.compact,
            ),
            ChoiceChip(
              label: const Text('Monto fijo'),
              selected: state.montoFijoChoferActivo,
              onSelected: (sel) {
                if (sel) {
                  state.montoFijoChoferActivo = true;
                  onCambio();
                }
              },
              selectedColor: AppColors.warning.withValues(alpha: 0.4),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        if (state.montoFijoChoferActivo) ...[
          const SizedBox(height: 8),
          TextField(
            controller: state.montoFijoChoferCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [AppFormatters.inputMilesDecimal],
            decoration: const InputDecoration(
              labelText: 'Monto al chofer (por viaje)',
              prefixText: '\$ ',
              prefixStyle: TextStyle(
                color: AppColors.warning,
                fontWeight: FontWeight.bold,
              ),
              suffixText: '/viaje',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            style: const TextStyle(color: Colors.white, fontSize: 15),
            onChanged: (_) => onCambio(),
          ),
        ],
      ],
    );
  }
}

class _BotonAgregarTramo extends StatelessWidget {
  final VoidCallback onPressed;
  const _BotonAgregarTramo({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.add),
      label: const Text('AGREGAR TRAMO'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentBlue,
        side: const BorderSide(color: AppColors.accentBlue),
        padding: const EdgeInsets.symmetric(vertical: 14),
        textStyle: const TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

/// Banner amarillo que avisa cuando el origen de un tramo no encadena
/// con el destino del anterior. NO bloquea — es un warning informativo
/// (hay casos legítimos: el tractor pasa por la base entre tramos).
/// Visualmente se inserta ENTRE dos cards de tramo.
class _BannerEncadenamiento extends StatelessWidget {
  final String mensaje;
  const _BannerEncadenamiento({required this.mensaje});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: AppColors.warning.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_outlined,
              size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              mensaje,
              style: const TextStyle(
                color: AppColors.warning,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// _DropdownProducto — productos de la empresa origen de la tarifa
// =============================================================================

class _DropdownProducto extends StatefulWidget {
  final String? empresaOrigenId;
  final String? valor;
  /// Controller para el fallback de texto libre (cuando la empresa
  /// origen no tiene productos catalogados). Debe vivir en el state
  /// del padre — si se crea acá en cada build, se pierde el foco al
  /// tipear (cada keystroke triggerea setState).
  final TextEditingController libreCtrl;
  final ValueChanged<String?> onChanged;

  const _DropdownProducto({
    required this.empresaOrigenId,
    required this.valor,
    required this.libreCtrl,
    required this.onChanged,
  });

  @override
  State<_DropdownProducto> createState() => _DropdownProductoState();
}

class _DropdownProductoState extends State<_DropdownProducto> {
  /// Future MEMORIZADO. Antes (Santiago 2026-05-19) este widget era
  /// StatelessWidget y el `future: LogisticaService.empresaPorId(...)`
  /// se evaluaba en cada `build()` — cada keystroke en el TextField de
  /// "producto libre" disparaba setState en el padre → rebuild de este
  /// widget → Future NUEVO → FutureBuilder volvía a `ConnectionState.
  /// waiting` y reemplazaba el TextField por el `LinearProgressIndicator`
  /// → el TextField se desmontaba y el operador perdía el foco después
  /// de tipear una sola letra. Memorizando el Future por
  /// `empresaOrigenId` y re-creándolo solo cuando ese ID cambia
  /// (didUpdateWidget), el TextField sigue montado entre keystrokes.
  Future<EmpresaLogistica?>? _empresaFuture;

  @override
  void initState() {
    super.initState();
    _crearFutureSiHaceFalta();
  }

  @override
  void didUpdateWidget(covariant _DropdownProducto old) {
    super.didUpdateWidget(old);
    if (old.empresaOrigenId != widget.empresaOrigenId) {
      _crearFutureSiHaceFalta();
    }
  }

  void _crearFutureSiHaceFalta() {
    final id = widget.empresaOrigenId;
    if (id == null || id.isEmpty) {
      _empresaFuture = null;
    } else {
      _empresaFuture = LogisticaService.empresaPorId(id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_empresaFuture == null) {
      return const TextField(
        enabled: false,
        decoration: InputDecoration(
          labelText: 'Producto (elegí primero una tarifa)',
          border: OutlineInputBorder(),
        ),
      );
    }
    return FutureBuilder<EmpresaLogistica?>(
      future: _empresaFuture,
      builder: (ctx, snap) {
        final productos = snap.data?.productos ?? const <String>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'Producto',
              border: OutlineInputBorder(),
            ),
            child: SizedBox(
              height: 20,
              child: LinearProgressIndicator(),
            ),
          );
        }
        if (productos.isEmpty) {
          // Empresa sin productos catalogados — caer a texto libre
          // para no bloquear al operador. El controller viene de
          // afuera (persistente) para no perder foco en cada keystroke.
          return TextField(
            controller: widget.libreCtrl,
            decoration: const InputDecoration(
              labelText: 'Producto (libre — la empresa no tiene catálogo)',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onChanged,
          );
        }
        // Si el valor actual no está en la lista (ej. se cargó un
        // producto libre y después se catalogaron otros), lo agregamos
        // a la lista para que no se pierda.
        final items = List<String>.from(productos);
        if (widget.valor != null &&
            widget.valor!.isNotEmpty &&
            !items.contains(widget.valor)) {
          items.add(widget.valor!);
        }
        return DropdownButtonFormField<String>(
          initialValue: items.contains(widget.valor) ? widget.valor : null,
          decoration: const InputDecoration(
            labelText: 'Producto',
            border: OutlineInputBorder(),
          ),
          isExpanded: true,
          items: items
              .map((p) => DropdownMenuItem(value: p, child: Text(p)))
              .toList(),
          onChanged: widget.onChanged,
        );
      },
    );
  }
}
