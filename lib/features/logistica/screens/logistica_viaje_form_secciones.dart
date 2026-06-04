// =============================================================================
// SECCIONES del form (Resumen, Estado, Chofer, Unidad, Adelanto)
// =============================================================================
// Extraído de logistica_viaje_form_screen.dart 2026-05-18 (split del
// archivo principal de 2823 LOC). Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — SOLO PRESENTACIÓN. Toda la lógica intacta:
//   - `_SeccionResumen` lee los MISMOS campos de `MontosViaje`.
//   - `_SeccionEstado` mantiene `EstadoViaje.values` + callbacks.
//   - `_SeccionChofer` conserva VERBATIM el RawAutocomplete (controller +
//     focusNode + optionsBuilder + onSelected) y el StreamBuilder de CHOFER.
//   - `_SeccionUnidad` conserva los inputFormatters (patente + uppercase) y
//     `maxLength: 7`.
//   - `_SeccionAdelantoAsociado` conserva el StreamBuilder + filtro client-side.
// Solo cambia el chrome a tokens (`context.colors`), bento y mono para plata.
//
// Componentes:
//   - _SeccionResumen + _LineaResumen — totales en vivo arriba del form.
//   - _SeccionEstado — dropdown del estado del viaje.
//   - _SeccionChofer + _SeccionChoferState — autocomplete por nombre.
//   - _SeccionUnidad + _UpperCaseFormatter — patentes tractor + enganche.
//   - _SeccionAdelantoAsociado — dropdown para asociar adelanto preexistente.

part of 'logistica_viaje_form_screen.dart';

class _SeccionResumen extends StatelessWidget {
  final MontosViaje? montos;

  /// `true` si hay un tramo con "monto fijo del chofer" activado pero sin
  /// importe válido. En ese caso `montos` se calculó cayendo al 18% para ese
  /// tramo (no es lo que cobra el chofer), así que NO mostramos los montos del
  /// chofer — solo un aviso para completar el monto. Audit 2026-06-04.
  final bool montoFijoIncompleto;

  const _SeccionResumen({required this.montos, this.montoFijoIncompleto = false});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SeccionCard(
      titulo: 'RESUMEN',
      icono: Icons.summarize_outlined,
      accentDot: montos == null ? null : c.success,
      children: [
        if (montos == null)
          Text(
            'Agregá al menos 1 tramo con tarifa para ver el cálculo.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else ...[
          _Linea(
            label: 'Facturado a empresa',
            valor: '\$ ${AppFormatters.formatearMonto(montos!.montoVecchi)}',
            mono: true,
          ),
          if (montoFijoIncompleto) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: c.warning),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Hay un tramo con "monto fijo del chofer" activado sin '
                    'importe. Cargalo (o cambiá a 18%) para ver lo que cobra '
                    'el chofer y la liquidación.',
                    style: AppType.bodySm.copyWith(color: c.warning),
                  ),
                ),
              ],
            ),
          ] else ...[
            _Linea(
              label:
                  'Comisión chofer (${montos!.comisionChoferPct.toStringAsFixed(0)}%)',
              valor: '\$ ${AppFormatters.formatearMonto(montos!.montoChofer)}',
              sub: true,
              mono: true,
            ),
            _Linea(
              label: 'Comisión chofer (redondeada)',
              valor:
                  '\$ ${AppFormatters.formatearMonto(montos!.montoChoferRedondeado)}',
              highlight: true,
              mono: true,
            ),
            _Linea(
              label: 'Gastos extras',
              valor:
                  '+ \$ ${AppFormatters.formatearMonto(montos!.gastosTotal)}',
              mono: true,
            ),
            const SizedBox(height: AppSpacing.sm),
            const AppHairline(),
            const SizedBox(height: AppSpacing.sm),
            _Linea(
              label: 'Liquidación final al chofer',
              valor:
                  '\$ ${AppFormatters.formatearMonto(montos!.liquidacionChofer)}',
              highlight: true,
              mono: true,
            ),
          ],
        ],
      ],
    );
  }
}

// _LineaResumen reemplazada por la primitiva `_Linea` (Núcleo) compartida con
// el viaje_detalle. Se mantiene el nombre del concepto en los call-sites de
// arriba para no perder trazabilidad del refactor.

class _SeccionEstado extends StatelessWidget {
  final EstadoViaje estado;
  final TextEditingController motivoCtrl;
  final DateTime? fechaPostergadoA;
  final ValueChanged<EstadoViaje> onEstadoChanged;
  final ValueChanged<DateTime?> onFechaChanged;

  /// Hook genérico para auto-save del borrador. Se invoca cuando
  /// cambia algún campo "menor" (texto del motivo) que no tiene
  /// callback dedicado pero igual queremos persistirlo.
  final VoidCallback onCambio;

  const _SeccionEstado({
    required this.estado,
    required this.motivoCtrl,
    required this.fechaPostergadoA,
    required this.onEstadoChanged,
    required this.onFechaChanged,
    required this.onCambio,
  });

  /// Color semántico del estado, alineado con el viaje_detalle ya migrado.
  Color _colorEstado(BuildContext context, EstadoViaje e) {
    final c = context.colors;
    return switch (e) {
      EstadoViaje.planeado => c.info,
      EstadoViaje.enCurso => c.brand,
      EstadoViaje.concluido => c.success,
    };
  }

  @override
  Widget build(BuildContext context) {
    return _SeccionCard(
      titulo: 'ESTADO',
      icono: Icons.flag_outlined,
      children: [
        // Estado como pills Núcleo (reemplaza el DropdownButtonFormField).
        // El set de estados es chico (3) — pills entran cómodas y mantienen
        // el gesto del sistema. La lógica `onEstadoChanged` queda igual.
        // Estados removidos 2026-05-14 (Santiago): "cancelado" y "postergado".
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final e in EstadoViaje.values)
              _PillSelector(
                label: e.etiqueta,
                seleccionado: estado == e,
                acento: _colorEstado(context, e),
                onTap: () => onEstadoChanged(e),
              ),
          ],
        ),
      ],
    );
  }
}

/// Selector de chofer con autocomplete (type-ahead). El operador
/// tipea cualquier subcadena del nombre (ej. "PER" → PEREZ JUAN, etc.)
/// y la lista se filtra en vivo. Reemplazó al `DropdownButtonFormField`
/// el 2026-05-14 (Santiago: "tendría que tener un sistema donde vaya
/// filtrando a medida que voy apretando las letras del nombre").
///
/// Stateful porque necesitamos manejar nuestro propio TextEditingController
/// + FocusNode para:
/// 1. Pre-cargar el nombre del chofer en modo edición.
/// 2. Sincronizar el texto si `widget.nombre` cambia desde fuera (carga
///    async del viaje).
/// 3. Revertir el texto del field si el operador tipea algo y se va sin
///    seleccionar — evita texto huérfano que no corresponde al chofer
///    realmente asignado.
class _SeccionChofer extends StatefulWidget {
  final String? dni;
  final String? nombre;
  final void Function(String dni, String nombre, String? vehiculo,
      String? enganche) onChanged;

  const _SeccionChofer({
    required this.dni,
    required this.nombre,
    required this.onChanged,
  });

  @override
  State<_SeccionChofer> createState() => _SeccionChoferState();
}

class _SeccionChoferState extends State<_SeccionChofer> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.nombre ?? '');
    _focusNode = FocusNode()..addListener(_onFocusChange);
  }

  @override
  void didUpdateWidget(covariant _SeccionChofer oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Caso típico: el form arrancó con `nombre = null` (alta o aún no
    // se cargó el doc del viaje), después llega async y hay que sync
    // el field. Solo lo hacemos si el field NO tiene foco — sino el
    // operador estaría tipeando y le interrumpiríamos.
    if (oldWidget.nombre != widget.nombre && !_focusNode.hasFocus) {
      _controller.text = widget.nombre ?? '';
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      // Si tipearon algo y se fueron sin seleccionar, restauramos el
      // valor confirmado (evita inconsistencia visual: el field mostrando
      // "PER" cuando en realidad está asignado "GARCIA MARIA").
      final esperado = widget.nombre ?? '';
      if (_controller.text != esperado) {
        _controller.text = esperado;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SeccionCard(
      titulo: 'CHOFER',
      icono: Icons.person_outline,
      children: [
        StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection(AppCollections.empleados)
              .where('ROL', isEqualTo: 'CHOFER')
              .snapshots(),
          builder: (ctx, snap) {
            // Orden alfabético por NOMBRE (case-insensitive). Client-side
            // para evitar tener que crear índice compuesto (ROL + NOMBRE)
            // en Firestore — son ~50 choferes, el sort es instantáneo.
            final docs = List<QueryDocumentSnapshot<Map<String, dynamic>>>.from(
              snap.data?.docs ?? const [],
            )..sort((a, b) {
                final na = (a.data()['NOMBRE'] ?? '').toString().toUpperCase();
                final nb = (b.data()['NOMBRE'] ?? '').toString().toUpperCase();
                return na.compareTo(nb);
              });

            return RawAutocomplete<QueryDocumentSnapshot<Map<String, dynamic>>>(
              textEditingController: _controller,
              focusNode: _focusNode,
              displayStringForOption: (d) =>
                  (d.data()['NOMBRE'] ?? '').toString(),
              optionsBuilder: (value) {
                final q = value.text.trim().toUpperCase();
                if (q.isEmpty) return docs;
                // Match por subcadena en cualquier lugar del nombre
                // ("PER" matchea "PEREZ" y "ALPER", "GAR" matchea
                // "GARCIA" y "FERNANDEZ GARCIA", etc.).
                return docs.where((d) {
                  final n = (d.data()['NOMBRE'] ?? '').toString().toUpperCase();
                  return n.contains(q);
                });
              },
              onSelected: (d) {
                final data = d.data();
                final dn = (data['DNI'] ?? d.id).toString();
                widget.onChanged(
                  dn,
                  (data['NOMBRE'] ?? dn).toString(),
                  data['VEHICULO']?.toString(),
                  data['ENGANCHE']?.toString(),
                );
                // Quitamos foco para que el listener acomode el texto
                // si hace falta (en este caso ya quedó bien por la
                // selección, pero también dispara la lógica del padre
                // que pasa al próximo campo).
                _focusNode.unfocus();
              },
              fieldViewBuilder: (ctx, ctrl, fn, onSubmit) {
                return TextField(
                  controller: ctrl,
                  focusNode: fn,
                  textCapitalization: TextCapitalization.characters,
                  style: AppType.body.copyWith(color: c.text),
                  decoration: _inputDecoration(
                    context,
                    labelText: 'Chofer',
                    hintText: 'Tipeá para filtrar (ej. PEREZ)',
                    prefixIcon:
                        Icon(Icons.search, size: 18, color: c.textMuted),
                    suffixIcon: ctrl.text.isEmpty
                        ? null
                        : IconButton(
                            icon: Icon(Icons.clear, size: 18, color: c.textMuted),
                            tooltip: 'Limpiar',
                            onPressed: () {
                              ctrl.clear();
                              fn.requestFocus();
                            },
                          ),
                  ),
                );
              },
              optionsViewBuilder: (ctx, onSel, options) {
                return Align(
                  alignment: Alignment.topLeft,
                  child: Material(
                    elevation: 6,
                    color: c.surface3,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      side: BorderSide(color: c.borderStrong),
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxHeight: 280,
                        maxWidth: 360,
                      ),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (ctx, idx) {
                          final d = options.elementAt(idx);
                          final data = d.data();
                          final nom = (data['NOMBRE'] ?? '').toString();
                          final esActual =
                              (data['DNI'] ?? d.id).toString() == widget.dni;
                          return InkWell(
                            onTap: () => onSel(d),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: AppSpacing.lg,
                                  vertical: AppSpacing.md),
                              child: Row(
                                children: [
                                  Icon(
                                    esActual
                                        ? Icons.check_circle
                                        : Icons.person_outline,
                                    size: 16,
                                    color: esActual ? c.success : c.textMuted,
                                  ),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      nom,
                                      overflow: TextOverflow.ellipsis,
                                      style:
                                          AppType.body.copyWith(color: c.text),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

class _SeccionUnidad extends StatelessWidget {
  final TextEditingController vehiculoCtrl;
  final TextEditingController engancheCtrl;
  final VoidCallback onChanged;

  const _SeccionUnidad({
    required this.vehiculoCtrl,
    required this.engancheCtrl,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Formatter que solo permite letras+digitos, hace UPPER y quita
    // espacios/guiones — para que la patente quede normalizada al
    // formato canonico (UPPERCASE sin separadores) que matchea las
    // queries a SITRACK_POSICIONES / VOLVO_ALERTAS / VEHICULOS.
    // (auditoria 2026-05-17: antes aceptaba "ab-123-cd" → no matcheaba.)
    final patenteFormatter = FilteringTextInputFormatter.allow(
      RegExp(r'[A-Za-z0-9]'),
    );
    return _SeccionCard(
      titulo: 'UNIDAD',
      icono: Icons.local_shipping_outlined,
      children: [
        TextField(
          controller: vehiculoCtrl,
          style: AppType.mono.copyWith(color: c.text),
          decoration: _inputDecoration(
            context,
            labelText: 'Patente tractor',
            hintText: 'AB123CD o ABC123',
          ),
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [patenteFormatter, _UpperCaseFormatter()],
          maxLength: 7,
          buildCounter: _sinContador,
          onChanged: (_) => onChanged(),
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: engancheCtrl,
          style: AppType.mono.copyWith(color: c.text),
          decoration: _inputDecoration(
            context,
            labelText: 'Patente enganche',
            hintText: 'AB123CD o ABC123',
          ),
          textCapitalization: TextCapitalization.characters,
          inputFormatters: [patenteFormatter, _UpperCaseFormatter()],
          maxLength: 7,
          buildCounter: _sinContador,
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }

  /// Oculta el contador "x/7" de `maxLength` (gesto Núcleo: el límite es
  /// silencioso, no se muestra debajo del campo). NO cambia la lógica de
  /// `maxLength`, solo su presentación.
  static Widget? _sinContador(BuildContext context,
          {required int currentLength,
          required bool isFocused,
          required int? maxLength}) =>
      null;
}

/// Formatter que fuerza UPPERCASE en cada keystroke. Necesario porque
/// `textCapitalization: TextCapitalization.characters` solo aplica al
/// teclado mobile — en desktop / paste no convierte.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    return TextEditingValue(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}

// `_SeccionAdelanto` (alta inline) removida del form de viaje el
// 2026-05-13. Los adelantos pasaron a ser entidad propia
// (`ADELANTOS_CHOFER`) con su propia pantalla. El operador crea el
// adelanto desde LOGÍSTICA → ADELANTOS y, opcionalmente, lo ASOCIA al
// viaje desde la sección `_SeccionAdelantoAsociado` (dropdown).

/// Dropdown para ASOCIAR un adelanto preexistente al viaje. Muestra:
///   - "(sin adelanto asociado)" como opción default.
///   - Cada adelanto del chofer seleccionado que esté libre (sin
///     `viaje_id`) O que ya esté asociado a ESTE viaje (modo edición).
///
/// Si todavía no se eligió chofer, se muestra un mensaje pidiendo
/// que se seleccione uno primero — los adelantos viven por DNI, no
/// tiene sentido listar.
///
/// La sección NO permite crear adelantos nuevos. Si el operador
/// quiere un adelanto que todavía no existe, lo crea desde
/// `LogisticaAdelantosScreen` y vuelve a este form.
class _SeccionAdelantoAsociado extends StatelessWidget {
  final String? choferDni;

  /// Si es edición, traemos los adelantos ya asociados a este viaje
  /// además de los libres. Null en modo alta.
  final String? viajeIdActual;
  final String? adelantoSeleccionadoId;
  final ValueChanged<String?> onChanged;

  const _SeccionAdelantoAsociado({
    required this.choferDni,
    required this.viajeIdActual,
    required this.adelantoSeleccionadoId,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _SeccionCard(
      titulo: 'ADELANTO ASOCIADO (OPCIONAL)',
      icono: Icons.payments_outlined,
      accentDot: c.warning,
      children: [
        if (choferDni == null || choferDni!.isEmpty)
          Text(
            'Seleccioná un chofer primero — los adelantos viven por chofer.',
            style: AppType.bodySm.copyWith(color: c.textMuted),
          )
        else
          StreamBuilder<List<AdelantoChofer>>(
            stream: AdelantosService.streamAdelantosPorChofer(choferDni!),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return Text(
                  'Error cargando adelantos: ${snap.error}',
                  style: AppType.bodySm.copyWith(color: c.error),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
                  child: LinearProgressIndicator(minHeight: 2),
                );
              }
              // Filtro client-side: adelantos sin viaje O ya
              // asociados a ESTE viaje. Los asociados a otro viaje
              // se excluyen — no queremos robarle el adelanto a otro
              // viaje sin querer.
              final candidatos = snap.data!
                  .where((a) =>
                      a.viajeId == null ||
                      a.viajeId!.isEmpty ||
                      a.viajeId == viajeIdActual)
                  .toList();
              if (candidatos.isEmpty) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'No hay adelantos libres de este chofer.',
                      style: AppType.bodySm.copyWith(color: c.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Si necesitás crear uno, andá a LOGÍSTICA → '
                      'ADELANTOS y volvé.',
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                  ],
                );
              }
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md, vertical: 2),
                decoration: BoxDecoration(
                  color: c.surface3,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                  border: Border.all(color: c.border),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    value: adelantoSeleccionadoId,
                    isExpanded: true,
                    isDense: true,
                    dropdownColor: c.surface3,
                    icon: Icon(Icons.expand_more, color: c.textMuted),
                    style: AppType.body.copyWith(color: c.text),
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: Text(
                          '(sin adelanto asociado)',
                          style: AppType.body.copyWith(color: c.textMuted),
                        ),
                      ),
                      ...candidatos.map((a) {
                        final fecha = AppFormatters.formatearFecha(a.fecha);
                        final monto = AppFormatters.formatearMonto(a.monto);
                        final medio = a.medioPago.etiqueta;
                        final obs = a.observacion?.trim().isNotEmpty == true
                            ? ' · ${a.observacion!.trim()}'
                            : '';
                        return DropdownMenuItem<String?>(
                          value: a.id,
                          child: Text(
                            '$fecha · \$ $monto · $medio$obs',
                            overflow: TextOverflow.ellipsis,
                            style: AppType.body.copyWith(color: c.text),
                          ),
                        );
                      }),
                    ],
                    onChanged: onChanged,
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}
