// =============================================================================
// TRAMOS — un viaje multi-tramo tiene una lista de _TramoCard.
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — SOLO PRESENTACIÓN. Se preserva VERBATIM:
//   - `_TramoEditState` ENTERO (controllers, factories `vacio`/`fromTramoViaje`,
//     `snapshotConOverride`, `toTramoViaje`, `dispose`) — es PURA lógica.
//   - `_pickRemito` (FilePicker + bytes pendientes).
//   - El armado del campo Tarifa (tap → `_abrirSelectorTarifa` → reset producto
//     + sincronizar override monto fijo).
//   - El toggle 18%/monto-fijo de `_OverridePagoChofer` y su parser.
//   - `_DropdownProducto` con su Future MEMORIZADO (clave del foco) + fallback
//     a texto libre.
// Solo cambia el chrome a tokens (`context.colors`), bento y mono para números.
//
// Componentes:
//   - _TramoEditState   — estado mutable de UN tramo (controllers + datos).
//   - _TramoCard        — UI de un tramo (carga + descarga + producto + gastos).
//   - _OverridePagoChofer — toggle "18% / monto fijo" + campo de monto.
//   - _BotonAgregarTramo — botón "+ AGREGAR TRAMO" debajo de la lista.
//   - _BannerEncadenamiento — warning cuando ubicaciones/fechas no encadenan.
//   - _DropdownProducto — dropdown poblado con productos de la empresa origen.

part of 'logistica_viaje_form_screen.dart';

class _TramoEditState {
  /// Identificador local estable (para el ValueKey de Flutter).
  final String id;

  TarifaLogistica? tarifa;
  String? producto;

  /// Snapshot ORIGINAL del tramo al EDITAR un viaje existente (null en alta).
  /// Si el operador NO cambia la tarifa, lo conservamos al guardar para que el
  /// viaje mantenga el precio con el que se cargó, aunque la tarifa se haya
  /// actualizado después (pedido Santiago 2026-06). Si elige OTRA tarifa
  /// (cambia el tarifaId), reconstruimos el snapshot del valor ACTUAL.
  final TarifaSnapshot? _snapshotOriginal;
  final String? _tarifaIdOriginal;

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
    TarifaSnapshot? snapshotOriginal,
    String? tarifaIdOriginal,
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
  })  : _snapshotOriginal = snapshotOriginal,
        _tarifaIdOriginal = tarifaIdOriginal,
        productoLibreCtrl = TextEditingController(text: producto ?? ''),
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
      snapshotOriginal: t.tarifaSnapshot,
      tarifaIdOriginal: t.tarifaId,
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
    // IMPORTES: la versión de la tarifa vigente en la FECHA DE CARGA del
    // tramo (versionado 2026-06). Si todavía no hay fecha de carga, el
    // precio de hoy. Así un viaje cargado tarde (carga el día 10, lo entran
    // el 16 tras un aumento) toma el precio que regía el día 10.
    final vig = tarifa!.vigenteEn(fechaCarga ?? DateTime.now());
    // Campos NO versionados (ruta/dador/etiquetas/producto): si EDITAMOS un
    // viaje y el operador NO cambió la tarifa (mismo tarifaId), conservamos
    // los del snapshot original del tramo (la ruta con la que se cargó). En
    // alta, o si eligió OTRA tarifa, tomamos el catálogo actual.
    final baseNoVersionada =
        (_snapshotOriginal != null && tarifa!.id == _tarifaIdOriginal)
            ? _snapshotOriginal!
            : TarifaSnapshot.fromTarifa(tarifa!);
    final base = baseNoVersionada.copyWithImportes(
      tarifaReal: vig.tarifaReal,
      tarifaChofer: vig.tarifaChofer,
      porcentajeComisionDador: vig.porcentajeComisionDador,
      montoFijoDador: vig.montoFijoDador,
    );
    if (!montoFijoChoferActivo) {
      // Explícitamente null para limpiar el override que la tarifa
      // pueda traer — el operador eligió volver al 18%.
      return base.copyWith(montoFijoChofer: null);
    }
    final parsed = AppFormatters.parsearMonto(montoFijoChoferCtrl.text);
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
    final c = context.colors;
    final esTn = state.tarifa?.unidadTarifa == UnidadTarifa.porTonelada;
    final tarifa = state.tarifa;
    return _SeccionCard(
      titulo: 'TRAMO $numero',
      icono: Icons.alt_route_outlined,
      accentDot: c.brand,
      // Botones "↑ ↓ duplicar" del header se quitaron 2026-05-14 por
      // pedido de Santiago — innecesarios en la práctica. Queda solo
      // el "eliminar" para el caso de tramo sobrante.
      trailing: puedeEliminar
          ? IconButton(
              icon: Icon(Icons.delete_outline, color: c.error, size: 18),
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
          borderRadius: BorderRadius.circular(AppRadius.lg),
          child: Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md, vertical: AppSpacing.md),
            decoration: BoxDecoration(
              color: c.surface3,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(
                  tarifa == null ? Icons.search : Icons.local_offer_outlined,
                  size: 18,
                  color: c.textMuted,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const AppEyebrow('Tarifa'),
                      const SizedBox(height: 2),
                      // Consistente con el picker: mostrar dador + ruta. El
                      // detalle (precios, unidad, producto) está en
                      // `_ResumenTarifa` abajo, no hace falta repetirlo acá.
                      Text(
                        tarifa == null
                            ? 'Seleccionar…'
                            : [
                                if ((tarifa.dadorNombre ?? '')
                                    .trim()
                                    .isNotEmpty)
                                  tarifa.dadorNombre!.trim(),
                                '${tarifa.origenDisplay} → ${tarifa.destinoDisplay}',
                              ].join(' · '),
                        style: AppType.body.copyWith(
                          color: tarifa == null ? c.textMuted : c.text,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(
                  tarifa == null ? Icons.chevron_right : Icons.edit_outlined,
                  size: 18,
                  color: c.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (tarifa != null) ...[
          const SizedBox(height: AppSpacing.sm),
          _ResumenTarifa(t: tarifa, fechaCarga: state.fechaCarga),
          const SizedBox(height: AppSpacing.md),
          // Override del pago al chofer para ESTE tramo. Útil cuando
          // la tarifa está cargada al 18% pero este viaje paga un
          // monto distinto al chofer (acuerdo a mano). El cambio NO
          // afecta la tarifa origen — vive solo en el snapshot del
          // tramo, así el catálogo de tarifas queda intacto.
          _OverridePagoChofer(state: state, onCambio: onCambio),
        ],
        const SizedBox(height: AppSpacing.lg),
        const AppHairline(),
        const SizedBox(height: AppSpacing.md),

        // CARGA — fecha + kg + producto + descripción libre.
        const _SubseccionTitulo('CARGA'),
        const SizedBox(height: AppSpacing.sm),
        _BotonFecha(
          label: 'Fecha de carga',
          fecha: state.fechaCarga,
          onChanged: (d) {
            state.fechaCarga = d;
            onCambio();
          },
        ),
        if (esTn) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: state.kgCargadosCtrl,
            style: AppType.mono.copyWith(color: c.text),
            decoration: _inputDecoration(
              context,
              labelText: 'Kg cargados',
              suffixText: 'kg',
            ),
            keyboardType: TextInputType.number,
            inputFormatters: [AppFormatters.inputMiles],
            onChanged: (_) => onCambio(),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
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
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: state.descripcionCargaCtrl,
          style: AppType.body.copyWith(color: c.text),
          decoration: _inputDecoration(
            context,
            labelText: 'Descripción / observación (opcional)',
          ),
          maxLines: 2,
          onChanged: (_) => onCambio(),
        ),
        const SizedBox(height: AppSpacing.lg),
        const AppHairline(),
        const SizedBox(height: AppSpacing.md),

        // DESCARGA — fecha + remito + comprobante + kg descargados.
        const _SubseccionTitulo('DESCARGA'),
        const SizedBox(height: AppSpacing.sm),
        _BotonFecha(
          label: 'Fecha de descarga',
          fecha: state.fechaDescarga,
          onChanged: (d) {
            state.fechaDescarga = d;
            onCambio();
          },
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: state.remitoNumeroCtrl,
          style: AppType.mono.copyWith(color: c.text),
          decoration: _inputDecoration(
            context,
            labelText: 'Número de remito',
          ),
          onChanged: (_) => onCambio(),
        ),
        const SizedBox(height: AppSpacing.sm),
        AppButton.secondary(
          label: state.remitoNombreLocal ??
              (state.remitoUrl != null
                  ? 'Reemplazar comprobante'
                  : 'Subir comprobante firmado (PDF / foto)'),
          icon: Icons.attach_file,
          size: AppButtonSize.sm,
          expand: true,
          onPressed: () => _pickRemito(context),
        ),
        if (state.remitoUrl != null && state.remitoNombreLocal == null) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(Icons.check_circle_outline, size: 14, color: c.success),
              const SizedBox(width: AppSpacing.xs),
              Text(
                'Comprobante ya cargado.',
                style: AppType.monoSm.copyWith(color: c.success),
              ),
            ],
          ),
        ],
        if (esTn) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: state.kgDescargadosCtrl,
            style: AppType.mono.copyWith(color: c.text),
            decoration: _inputDecoration(
              context,
              labelText: 'Kg descargados (cifra final para liquidar)',
              suffixText: 'kg',
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
        const SizedBox(height: AppSpacing.lg),
        const AppHairline(),
        const SizedBox(height: AppSpacing.md),
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
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SubseccionTitulo('PAGO AL CHOFER (ESTE TRAMO)'),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _PillSelector(
              label: '18%',
              seleccionado: !state.montoFijoChoferActivo,
              acento: c.info,
              onTap: () {
                if (state.montoFijoChoferActivo) {
                  state.montoFijoChoferActivo = false;
                  onCambio();
                }
              },
            ),
            _PillSelector(
              label: 'Monto fijo',
              seleccionado: state.montoFijoChoferActivo,
              acento: c.warning,
              onTap: () {
                if (!state.montoFijoChoferActivo) {
                  state.montoFijoChoferActivo = true;
                  onCambio();
                }
              },
            ),
          ],
        ),
        if (state.montoFijoChoferActivo) ...[
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: state.montoFijoChoferCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [AppFormatters.inputMilesDecimal],
            style: AppType.mono
                .copyWith(color: c.text, fontWeight: FontWeight.w600),
            decoration: _inputDecoration(
              context,
              labelText: 'Monto al chofer (por viaje)',
              prefixText: '\$ ',
              prefixStyle: TextStyle(
                color: c.warning,
                fontWeight: FontWeight.bold,
              ),
              suffixText: '/viaje',
            ),
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
    return AppButton.secondary(
      label: 'Agregar tramo',
      icon: Icons.add,
      size: AppButtonSize.md,
      expand: true,
      onPressed: onPressed,
    );
  }
}

/// Banner que avisa cuando el origen de un tramo no encadena con el destino
/// del anterior (o las fechas no son cronológicas). NO bloquea — es un
/// warning informativo (hay casos legítimos: el tractor pasa por la base
/// entre tramos). Visualmente se inserta ENTRE dos cards de tramo o arriba
/// de los campos del tramo.
class _BannerEncadenamiento extends StatelessWidget {
  final String mensaje;
  const _BannerEncadenamiento({required this.mensaje});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, size: 18, color: c.warning),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              mensaje,
              style: AppType.bodySm.copyWith(color: c.warning),
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

  /// Caja decorada (surface3 + border + label eyebrow) que envuelve un
  /// dropdown o el progress mientras carga. Mantiene el gesto Núcleo sin
  /// migrar el dropdown a un widget que rompa la lógica del valor.
  Widget _caja(BuildContext context,
      {required String label, required Widget child}) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: c.surface3,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AppEyebrow(label),
          const SizedBox(height: 2),
          child,
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_empresaFuture == null) {
      return _caja(
        context,
        label: 'Producto',
        child: Text(
          'Elegí primero una tarifa',
          style: AppType.body.copyWith(color: c.textMuted),
        ),
      );
    }
    return FutureBuilder<EmpresaLogistica?>(
      future: _empresaFuture,
      builder: (ctx, snap) {
        final productos = snap.data?.productos ?? const <String>[];
        if (snap.connectionState == ConnectionState.waiting) {
          return _caja(
            context,
            label: 'Producto',
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          );
        }
        if (productos.isEmpty) {
          // Empresa sin productos catalogados — caer a texto libre
          // para no bloquear al operador. El controller viene de
          // afuera (persistente) para no perder foco en cada keystroke.
          return TextField(
            controller: widget.libreCtrl,
            style: AppType.body.copyWith(color: c.text),
            decoration: _inputDecoration(
              context,
              labelText: 'Producto (libre — la empresa no tiene catálogo)',
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
        return _caja(
          context,
          label: 'Producto',
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: items.contains(widget.valor) ? widget.valor : null,
              isExpanded: true,
              isDense: true,
              dropdownColor: c.surface3,
              icon: Icon(Icons.expand_more, color: c.textMuted),
              hint: Text(
                'Seleccionar…',
                style: AppType.body.copyWith(color: c.textMuted),
              ),
              style: AppType.body.copyWith(color: c.text),
              items: items
                  .map((p) => DropdownMenuItem(
                        value: p,
                        child: Text(p, overflow: TextOverflow.ellipsis),
                      ))
                  .toList(),
              onChanged: widget.onChanged,
            ),
          ),
        );
      },
    );
  }
}
