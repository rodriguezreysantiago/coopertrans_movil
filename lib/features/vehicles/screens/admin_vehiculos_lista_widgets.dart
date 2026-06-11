// =============================================================================
// COMPONENTES VISUALES de la lista de vehículos — extraídos para mantener
// navegable el screen principal. Comparten privacidad y los imports via
// `part of`. Si necesitás reusar alguno desde otra pantalla, hacelo público
// y movelo a `lib/features/vehicles/widgets/`.
// =============================================================================

part of 'admin_vehiculos_lista_screen.dart';

// =============================================================================
// LISTA DE FLOTA (un AppListPage filtrado por la card seleccionada)
// =============================================================================

/// Lista de unidades. El stream es FIJO (toda la flota, creado en el screen);
/// el filtro lo da el callback `visible` (escudo + card). Al cambiar de card,
/// el screen reconstruye con un `visible` nuevo y AppListPage re-filtra el
/// MISMO snapshot — sin re-suscribir (mismo patrón que Gestión de Personal,
/// que ya hace stream-fijo + filtro client-side y anda).
class _ListaFlota extends StatelessWidget {
  final Stream<QuerySnapshot> stream;
  final String cardId;
  final bool Function(Map<String, dynamic> data, String patente) visible;
  const _ListaFlota({
    required this.stream,
    required this.cardId,
    required this.visible,
  });

  @override
  Widget build(BuildContext context) {
    return AppListPage(
      stream: stream,
      searchHint: 'Buscar patente, marca, modelo o VIN...',
      emptyTitle: 'Sin ${_cardLabel(cardId).toLowerCase()}',
      emptySubtitle: 'No hay unidades en este filtro.',
      emptyIcon: Icons.local_shipping_outlined,
      filter: (doc, q) {
        final data = doc.data() as Map<String, dynamic>;
        if (!visible(data, doc.id)) return false;
        final hay = '${doc.id} ${data['MARCA'] ?? ''} '
                '${data['MODELO'] ?? ''} ${data['VIN'] ?? ''}'
            .toUpperCase();
        return hay.contains(q);
      },
      itemBuilder: (ctx, doc) => _VehiculoCard(doc: doc),
    );
  }
}

// =============================================================================
// FILA DE VEHÍCULO (Núcleo) — AppCard(tier:1) por fila. Hero de patente en mono,
// AppBadge de estado, km/marca en mono, mini-vencimientos en Wrap. El borde de
// las cards adyacentes hace de hairline natural entre filas. Indigo es la única
// tinta de marca; los colores semánticos (estados de vencimiento, telemetría)
// se conservan por su carga de info operativa.
// =============================================================================

class _VehiculoCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _VehiculoCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = doc.data() as Map<String, dynamic>;
    final patente = doc.id;
    final marca = (data['MARCA'] ?? '').toString().trim();
    final modelo = (data['MODELO'] ?? '').toString().trim();
    final marcaModelo = [marca, modelo].where((s) => s.isNotEmpty).join(' ');
    final estado = (data['ESTADO'] ?? 'LIBRE').toString().toUpperCase();
    final km = data['KM_ACTUAL'];
    // Avatar de la unidad: si tiene foto cargada, la mostramos circular.
    // Si no, fallback a un ícono según el tipo (tractor / enganche).
    final urlFoto = data['ARCHIVO_FOTO']?.toString();
    final tieneFoto = urlFoto != null && urlFoto.isNotEmpty && urlFoto != '-';
    final tipo = (data['TIPO'] ?? 'TRACTOR').toString().toUpperCase();
    final esTractor = tipo == 'TRACTOR';

    return Selector<VehiculoProvider,
        ({bool loading, bool success, String? error})>(
      selector: (_, p) => (
        loading: p.isLoading(patente),
        success: p.isSuccess(patente),
        error: p.getError(patente),
      ),
      builder: (ctx, state, _) {
        return AppCard(
          tier: 1,
          onTap: () => _abrirDetalle(context, patente, data),
          highlighted: state.success || state.error != null,
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md, vertical: AppSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar de la unidad — foto si la cargó el admin; si no,
              // ícono temático (camión para tractor, enganche para acoplados).
              CircleAvatar(
                radius: 22,
                backgroundColor: c.surface3,
                backgroundImage: tieneFoto ? NetworkImage(urlFoto) : null,
                child: !tieneFoto
                    ? Icon(
                        esTractor ? Icons.local_shipping : Icons.rv_hookup,
                        color: c.textMuted,
                        size: 20,
                      )
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: patente (hero mono) + badge estado + indicador
                    // de sync.
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            patente.toUpperCase(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppType.h5.copyWith(
                              fontFamily: 'GeistMono',
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        AppBadge(
                          text: _estadoLabel(estado),
                          color: _estadoColor(estado, c),
                          dot: true,
                          size: AppBadgeSize.sm,
                        ),
                        const Spacer(),
                        if (state.loading)
                          SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: c.brand),
                          ),
                        if (state.success)
                          Icon(Icons.check_circle, color: c.success, size: 16),
                        if (state.error != null)
                          Icon(Icons.error_outline, color: c.error, size: 16),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Subtítulo: marca/modelo + km (ambos en mono).
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            marcaModelo.isEmpty ? '—' : marcaModelo,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                AppType.monoSm.copyWith(color: c.textSecondary),
                          ),
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Icon(Icons.speed, size: 12, color: c.textMuted),
                        const SizedBox(width: AppSpacing.xs),
                        Text(
                          '${AppFormatters.formatearKilometraje(km)} km',
                          style: AppType.mono.copyWith(color: c.text),
                        ),
                      ],
                    ),
                    // Telemetría compacta (combustible + autonomía). Solo
                    // se muestra si la unidad reporta esos datos vía Volvo.
                    _TelemetriaCompacta(data: data),
                    const SizedBox(height: AppSpacing.sm),
                    // Vista rápida de vencimientos (badges compactos). Wrap
                    // para que en pantallas chicas los extintores bajen a una
                    // segunda línea sin truncarse.
                    Wrap(
                      spacing: AppSpacing.md,
                      runSpacing: 6,
                      children: [
                        _MiniVencimiento(
                            label: 'RTO', fecha: data['VENCIMIENTO_RTO']),
                        _MiniVencimiento(
                            label: 'Seguro', fecha: data['VENCIMIENTO_SEGURO']),
                        _MiniVencimiento(
                            label: 'Ext. cabina',
                            fecha: data['VENCIMIENTO_EXTINTOR_CABINA']),
                        _MiniVencimiento(
                            label: 'Ext. exterior',
                            fecha: data['VENCIMIENTO_EXTINTOR_EXTERIOR']),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Dispara el sync con Volvo si corresponde y abre el bottom sheet de detalle.
  void _abrirDetalle(
          BuildContext context, String patente, Map<String, dynamic> data) =>
      abrirDetalleVehiculo(context, patente, data);
}

/// Color semántico del estado de la unidad (token del tema activo).
Color _estadoColor(String estado, AppColorsExt c) {
  switch (estado.toUpperCase()) {
    case 'LIBRE':
      return c.success;
    case 'OCUPADO':
    case 'ASIGNADO':
      return c.info;
    case 'TALLER':
    case 'MANTENIMIENTO':
      return c.warning;
    case 'BAJA':
    case 'INACTIVO':
      return c.error;
    default:
      return c.textMuted;
  }
}

/// Etiqueta legible del estado. Capitaliza (LIBRE → Libre) para no gritar
/// en la pill; '—' si viene vacío.
String _estadoLabel(String estado) {
  final e = estado.trim();
  if (e.isEmpty) return '—';
  return e[0].toUpperCase() + e.substring(1).toLowerCase();
}

/// Abre el detalle (bottom sheet) de un vehículo desde cualquier parte
/// del código.
///
/// Si la unidad es Volvo y tiene VIN, dispara un sync de KM no bloqueante
/// en segundo plano antes de abrir — el stream del doc se refresca solo.
///
/// Pensado para que features externos (CommandPalette / búsqueda Ctrl+K,
/// links profundos, etc.) puedan abrir el detalle sin tener que crear
/// un `_VehiculoCard` artificial.
void abrirDetalleVehiculo(
    BuildContext context, String patente, Map<String, dynamic> data) {
  final marca = (data['MARCA'] ?? '').toString().toUpperCase();
  final vin = (data['VIN'] ?? '').toString();

  // Sync no bloqueante: si es Volvo y tiene VIN, refrescamos el KM en
  // segundo plano. El stream del documento se actualiza solo cuando termina.
  if (marca == 'VOLVO' && vin.isNotEmpty) {
    final p = context.read<VehiculoProvider>();
    if (!p.isLoading(patente) && p.debeSincronizar(patente)) {
      p.sync(patente, vin);
    }
  }

  AppDetailSheet.show(
    context: context,
    title: 'Ficha $patente',
    icon: Icons.local_shipping,
    actions: [
      // Menú overflow con acciones secundarias. Antes había un botón
      // "Editar ficha" que abría un form completo; ahora la edición
      // de datos (marca, modelo, año, VIN, KM, empresa) se hace
      // inline tappeando cada item del sheet — el form completo queda
      // como fallback para fechas/comprobantes/foto.
      _AccionesVehiculoMenu(patente: patente, data: data),
    ],
    builder: (sheetCtx, scrollCtl) => _DetalleVehiculo(
      patente: patente,
      dataInicial: data,
      scrollController: scrollCtl,
    ),
  );
}

/// Menú overflow del sheet de detalle. Agrupa acciones que NO son
/// edición de campo simple (esas se hacen inline en el body):
/// - Editar fechas/comprobantes/foto: abre el form completo (legacy).
/// - Forzar sincro Volvo: refresca KM_ACTUAL desde el API.
/// - Diagnóstico Volvo: abre el visor de diagnóstico (depuración).
class _AccionesVehiculoMenu extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> data;
  const _AccionesVehiculoMenu({required this.patente, required this.data});

  bool get _esVolvo =>
      (data['MARCA'] ?? '').toString().toUpperCase() == 'VOLVO';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, color: c.textSecondary, size: 20),
      tooltip: 'Más acciones',
      onSelected: (val) async {
        switch (val) {
          case 'form':
            Navigator.pop(context);
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => AdminVehiculoFormScreen(
                  vehiculoId: patente,
                  datosIniciales: data,
                ),
              ),
            );
          case 'sync':
            await _forzarSyncVolvo(context);
          case 'diag':
            await _abrirDiagnostico(context);
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'form',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.event_note, color: AppColors.success),
            title: Text('Editar fechas / comprobantes / foto'),
            subtitle: Text(
              'Form completo con vencimientos y archivos',
              style: AppType.eyebrow,
            ),
          ),
        ),
        if (_esVolvo) ...[
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'sync',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.sync, color: AppColors.info),
              title: Text('Forzar sincro Volvo'),
              subtitle: Text(
                'Refrescar KM desde el API',
                style: AppType.eyebrow,
              ),
            ),
          ),
          const PopupMenuItem(
            value: 'diag',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.bug_report_outlined, color: AppColors.warning),
              title: Text('Diagnóstico Volvo'),
              subtitle: Text(
                'Inspeccionar última respuesta del API',
                style: AppType.eyebrow,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _forzarSyncVolvo(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final vin = (data['VIN'] ?? '').toString().trim().toUpperCase();
    if (vin.length < 10) {
      AppFeedback.warningOn(messenger, 'VIN inválido (mínimo 10 chars).');
      return;
    }
    AppFeedback.infoOn(messenger, 'Sincronizando con Volvo...');
    try {
      final metros = await VolvoApiService().traerKilometrajeCualquierVia(vin);
      if (metros != null && metros > 0) {
        // Update directo a Firestore — no usamos VehiculoActions.dato
        // porque su SnackBar requiere un BuildContext que ya cruzó el
        // await. Hacemos el update + audit log manual + feedback con
        // el messenger que capturamos al principio.
        await FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .doc(patente)
            .update({
          'KM_ACTUAL': metros / 1000,
          'fecha_ultima_actualizacion': FieldValue.serverTimestamp(),
          'ULTIMA_SINCRO': FieldValue.serverTimestamp(),
          'SINCRO_TIPO': 'MANUAL',
        });
        AppFeedback.successOn(messenger,
            'KM actualizado: ${AppFormatters.formatearMiles(metros / 1000)} km');
      } else {
        AppFeedback.warningOn(messenger, 'Unidad en reposo o no encontrada.');
      }
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario:
            'No se pudo conectar con Volvo. Verificá tu conexión y probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }

  Future<void> _abrirDiagnostico(BuildContext context) async {
    final vin = (data['VIN'] ?? '').toString().trim().toUpperCase();
    if (vin.length < 10) {
      AppFeedback.warning(context, 'Necesito un VIN válido para diagnosticar.');
      return;
    }
    Navigator.pop(context);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => DiagnosticoVolvoScreen(patente: patente, vin: vin),
      ),
    );
  }
}

// =============================================================================
// DETALLE DEL VEHÍCULO (contenido del bottom sheet)
// =============================================================================

class _DetalleVehiculo extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> dataInicial;
  final ScrollController scrollController;

  const _DetalleVehiculo({
    required this.patente,
    required this.dataInicial,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .snapshots(),
      builder: (ctx, snap) {
        // Mientras llega el primer snapshot mostramos los datos que
        // teníamos del listado, así no parpadea el sheet.
        final data = snap.hasData && snap.data!.exists
            ? snap.data!.data() as Map<String, dynamic>
            : dataInicial;

        return _buildBody(ctx, data);
      },
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> data) {
    final c = context.colors;
    final marca = (data['MARCA'] ?? '').toString();
    final modelo = (data['MODELO'] ?? '').toString();
    final anioInt = ((data['ANIO'] ?? data['AÑO']) as num?)?.toInt() ??
        int.tryParse((data['ANIO'] ?? data['AÑO'] ?? '').toString()) ??
        0;
    final estado = (data['ESTADO'] ?? 'LIBRE').toString().toUpperCase();
    final vin = (data['VIN'] ?? '').toString();
    final tipo = (data['TIPO'] ?? '').toString().toUpperCase();
    final esTractor = tipo == AppTiposVehiculo.tractor;

    // Sugerencias de marca: en Coopertrans los tractores son TODOS
    // VOLVO (Santiago: "no inventes otras marcas, si es necesario yo
    // las agrego"). Para enganches dejamos lista vacía — se carga
    // siempre con "Otro..." y la primera vez queda como sugerencia
    // implícita en el valor actual.
    final sugerenciasMarca =
        esTractor ? const <String>['VOLVO'] : const <String>[];

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(20),
      children: [
        // Header con marca + modelo + estado (solo display, edición
        // inline más abajo en la sección de Identificación).
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    [marca, modelo]
                        .where((s) => s.isNotEmpty)
                        .join(' ')
                        .toUpperCase()
                        .ifEmpty('SIN DATOS'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.h5,
                  ),
                  if (anioInt > 0)
                    Text(
                      'Año $anioInt',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                    ),
                ],
              ),
            ),
            AppBadge(
              text: _estadoLabel(estado),
              color: _estadoColor(estado, c),
              dot: true,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),

        // Panel de telemetría: KM + combustible + autonomía. Si la unidad
        // no tiene combustible/autonomía reportados, el panel cae a una
        // tarjeta simple de KM (compatibilidad con vehículos no-Volvo).
        _PanelTelemetria(data: data),

        // Service: fecha + km restantes hasta el próximo. Sección
        // separada de Identificación para que sea fácil de ver de un
        // vistazo. Si no hay datos cargados, muestra placeholder con
        // CTA para abrir el form completo.
        if (esTractor) ...[
          const SizedBox(height: 18),
          const _SectionTitle(
              icon: Icons.build_circle_outlined, label: 'Service'),
          _ResumenService(patente: patente, data: data),
        ],

        const SizedBox(height: 18),
        const _SectionTitle(icon: Icons.fingerprint, label: 'Identificación'),
        DatoEditableEnumExtensible(
          etiqueta: 'MARCA',
          valorActual: marca,
          sugerencias: sugerenciasMarca,
          icono: Icons.label_outline,
          hintOtro: esTractor ? 'Ej. VOLVO' : 'Ej. RANDON',
          onSave: (v) => VehiculoActions.dato(context, patente, 'MARCA', v),
        ),
        DatoEditableEnumExtensible(
          etiqueta: 'MODELO',
          valorActual: modelo,
          // Sugerencias frecuentes de Volvo (mayoría de la flota).
          // Cualquier modelo nuevo se agrega con "Otro...".
          sugerencias: const ['FH 540', 'FH 460', 'FH 420', 'FM 440', 'VM 270'],
          icono: Icons.directions_car_outlined,
          hintOtro: 'Ej. FH 500',
          onSave: (v) => VehiculoActions.dato(context, patente, 'MODELO', v),
        ),
        _DatoEditableAnio(
          valorActual: anioInt > 0 ? anioInt : null,
          onSave: (v) => VehiculoActions.dato(context, patente, 'ANIO', v),
        ),
        DatoEditableTexto(
          etiqueta: 'VIN',
          valor: vin.isEmpty ? '—' : vin,
          onSave: (v) => VehiculoActions.dato(
              context, patente, 'VIN', v.isEmpty ? null : v),
        ),
        _DatoEditableEmpresa(
          valor: (data['EMPRESA'] ?? '').toString(),
          onSave: (v) => VehiculoActions.dato(context, patente, 'EMPRESA', v),
        ),
        // KM ACTUAL no se edita acá: el valor ya está visible arriba en
        // el panel de telemetría y se sincroniza automático con Volvo.
        // Dejarlo editable acá generaba duplicado visual y riesgo de
        // que el admin lo bajara a mano sobreescribiendo el valor real.

        const SizedBox(height: 18),
        const _SectionTitle(icon: Icons.event_note, label: 'Vencimientos'),
        // Iteramos AppVencimientos.forTipo() para que sumar un vencimiento
        // nuevo a la config (ej. extintores en TRACTOR) aparezca automaticamente
        // en la ficha sin tocar este archivo. Antes estaba hardcoded a RTO+Seguro
        // y los extintores cargados en tractores no se veian aca aunque si en
        // la pantalla del chofer y en el form de edicion.
        for (final spec in AppVencimientos.forTipo(data['TIPO']?.toString()))
          _VencimientoRow(
            patente: patente,
            etiqueta: spec.etiqueta,
            campoFecha: spec.campoFecha,
            campoArchivo: spec.campoArchivo,
            fecha: data[spec.campoFecha],
            url: data[spec.campoArchivo],
            tituloVisor: '${spec.etiqueta} $patente',
          ),

        if (data['ULTIMA_SINCRO'] != null) ...[
          const SizedBox(height: 18),
          const _SectionTitle(icon: Icons.sync, label: 'Sincronización Volvo'),
          Row(
            children: [
              Text(
                _formatTimestamp(data['ULTIMA_SINCRO']),
                style: AppType.mono.copyWith(color: c.textSecondary),
              ),
              const SizedBox(width: AppSpacing.sm),
              if ((data['SINCRO_TIPO'] ?? '') != '')
                AppBadge(
                  text: (data['SINCRO_TIPO'] ?? '').toString(),
                  color: c.brand,
                  size: AppBadgeSize.sm,
                ),
            ],
          ),
        ],

        const SizedBox(height: 30),
        // Acción de soft-delete al final del sheet (mismo patrón que
        // la ficha de Personal).
        _BotonBajaReactivarVehiculo(patente: patente, data: data),
        const SizedBox(height: 30),
      ],
    );
  }

  String _formatTimestamp(dynamic ts) {
    DateTime? d;
    if (ts is Timestamp) {
      d = ts.toDate();
    } else if (ts is DateTime) {
      d = ts;
    } else if (ts is String) {
      d = DateTime.tryParse(ts);
    }
    if (d == null) {
      return '—';
    }

    final diff = DateTime.now().difference(d);
    if (diff.inSeconds < 60) {
      return 'hace ${diff.inSeconds}s';
    }
    if (diff.inMinutes < 60) {
      return 'hace ${diff.inMinutes}min';
    }
    if (diff.inHours < 24) {
      return 'hace ${diff.inHours}h';
    }
    if (diff.inDays < 7) {
      return 'hace ${diff.inDays}d';
    }
    return '${d.day.toString().padLeft(2, '0')}/'
        '${d.month.toString().padLeft(2, '0')}/${d.year}';
  }
}

// =============================================================================
// WIDGETS PRIVADOS DE ESTA PANTALLA (no se reutilizan en otras)
// =============================================================================

/// Botón final del sheet de detalle: muestra "Dar de baja" si la
/// unidad está activa, o un panel "Reactivar" + nota de baja si está
/// inactiva.
class _BotonBajaReactivarVehiculo extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> data;
  const _BotonBajaReactivarVehiculo({
    required this.patente,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final activo = AppActivo.esActivo(data);
    // Dar de baja / reactivar (campo ACTIVO) quedó solo-ADMIN (2026-06-01).
    final puedeBaja =
        Capabilities.can(PrefsService.rol, Capability.eliminarVehiculo);
    if (activo) {
      if (!puedeBaja) return const SizedBox.shrink();
      return Center(
        child: TextButton.icon(
          onPressed: () => VehiculoActions.confirmarYDarDeBaja(
            context,
            patente: patente,
          ),
          icon: Icon(Icons.do_not_disturb_on_outlined, color: c.error),
          label: Text(
            'Dar de baja',
            style: AppType.body
                .copyWith(color: c.error, fontWeight: FontWeight.w600),
          ),
        ),
      );
    }

    final bajaEnTs = data[AppActivo.campoBajaEn];
    final bajaEnFmt = bajaEnTs is Timestamp
        ? AppFormatters.formatearFecha(bajaEnTs.toDate())
        : '?';
    final motivo = (data[AppActivo.campoBajaMotivo] ?? '').toString();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: c.warningSoft,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: c.warning.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.archive_outlined, color: c.warning, size: 18),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow('Unidad dada de baja', color: c.warning),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'Fecha: $bajaEnFmt',
            style: AppType.label.copyWith(color: c.textSecondary),
          ),
          if (motivo.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Motivo: $motivo',
              style: AppType.label.copyWith(color: c.textSecondary),
            ),
          ],
          if (puedeBaja) ...[
            const SizedBox(height: AppSpacing.md),
            Center(
              child: TextButton.icon(
                onPressed: () => VehiculoActions.confirmarYReactivar(
                  context,
                  patente: patente,
                ),
                icon: Icon(Icons.unarchive_outlined, color: c.success),
                label: Text(
                  'Reactivar',
                  style: AppType.body
                      .copyWith(color: c.success, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MiniVencimiento extends StatelessWidget {
  final String label;
  final dynamic fecha;
  const _MiniVencimiento({required this.label, required this.fecha});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppType.eyebrow.copyWith(color: c.textMuted)),
        const SizedBox(width: 6),
        VencimientoBadge(fecha: fecha, compact: true),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionTitle({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Icon(icon, color: c.brand, size: 15),
          const SizedBox(width: AppSpacing.sm),
          AppEyebrow(label, color: c.textSecondary),
        ],
      ),
    );
  }
}

// _InfoRow eliminado — el detalle ahora usa los widgets `DatoEditable*`
// del shared package, que muestran el dato con el mismo estilo + son
// tappeables para editar inline.

// ─────────────────────────────────────────────────────────────────────────────
// TELEMETRÍA (combustible + autonomía leídos de Volvo Connect)
// ─────────────────────────────────────────────────────────────────────────────

double? _toDouble(dynamic v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString());
}

/// Color para la barrita de combustible: verde > 50, naranja 20-50, rojo < 20.
Color _colorCombustible(double pct) {
  if (pct >= 50) return AppColors.success;
  if (pct >= 20) return AppColors.warning;
  return AppColors.error;
}

/// Versión compacta de la telemetría para usar dentro del card de la lista.
/// Fila con chips: combustible, AdBlue, autonomía. Si la unidad no
/// reporta ninguno, el widget devuelve un SizedBox vacío.
class _TelemetriaCompacta extends StatelessWidget {
  final Map<String, dynamic> data;
  const _TelemetriaCompacta({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fuel = _toDouble(data['NIVEL_COMBUSTIBLE']);
    final adblue = _toDouble(data['NIVEL_ADBLUE']);
    final auton = _toDouble(data['AUTONOMIA_KM']);

    if (fuel == null && adblue == null && auton == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if (fuel != null)
            _ChipTelemetria(
              icono: Icons.local_gas_station,
              color: _colorCombustible(fuel),
              texto: '${fuel.clamp(0, 100).toStringAsFixed(0)}%',
            ),
          if (adblue != null)
            _ChipTelemetria(
              icono: Icons.water_drop_outlined,
              color: _colorCombustible(adblue),
              texto: '${adblue.clamp(0, 100).toStringAsFixed(0)}%',
            ),
          if (auton != null)
            _ChipTelemetria(
              icono: Icons.route,
              color: c.brand,
              texto: '${auton.toStringAsFixed(0)} km',
            ),
        ],
      ),
    );
  }
}

class _ChipTelemetria extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String texto;

  const _ChipTelemetria({
    required this.icono,
    required this.color,
    required this.texto,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: color.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: color, size: 12),
          const SizedBox(width: AppSpacing.xs),
          Text(
            texto,
            style: AppType.monoSm.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// Panel de telemetría grande que va en el bottom sheet del detalle.
/// Reemplaza la tarjeta de "Kilometraje" original. Si la unidad solo
/// tiene KM (no es Volvo o no reporta), se ve como antes.
class _PanelTelemetria extends StatelessWidget {
  final Map<String, dynamic> data;
  const _PanelTelemetria({required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final km = _toDouble(data['KM_ACTUAL']);
    final fuel = _toDouble(data['NIVEL_COMBUSTIBLE']);
    final adblue = _toDouble(data['NIVEL_ADBLUE']);
    final auton = _toDouble(data['AUTONOMIA_KM']);
    final hayTelemetria = fuel != null || adblue != null || auton != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.xl),
        border: Border.all(color: c.border),
      ),
      child: hayTelemetria
          // Hasta 4 celdas (ODÓMETRO, COMBUSTIBLE, ADBLUE, AUTONOMÍA).
          // En desktop/tablet entran en una sola fila; en mobile (< 400 dp)
          // 4 Expanded daban ~83 dp por celda y los valores como
          // "350.000 km" overflow. Wrap + width fijo de 50%-spacing
          // garantiza 2x2 en mobile sin que se corte nada.
          ? LayoutBuilder(
              builder: (ctx, constraints) {
                final celdaWidth = constraints.maxWidth >= 480
                    ? (constraints.maxWidth / 4) - 8
                    : (constraints.maxWidth / 2) - 8;
                final celdas = <Widget>[
                  SizedBox(
                    width: celdaWidth,
                    child: _CeldaTelemetria(
                      icono: Icons.speed,
                      color: c.brand,
                      valor: km != null
                          ? AppFormatters.formatearKilometraje(km)
                          : '—',
                      unidad: 'km',
                      etiqueta: 'ODÓMETRO',
                    ),
                  ),
                  if (fuel != null)
                    SizedBox(
                      width: celdaWidth,
                      child: _CeldaPorcentaje(
                        porcentaje: fuel,
                        icono: Icons.local_gas_station,
                        etiqueta: 'COMBUSTIBLE',
                      ),
                    ),
                  if (adblue != null)
                    SizedBox(
                      width: celdaWidth,
                      child: _CeldaPorcentaje(
                        porcentaje: adblue,
                        icono: Icons.water_drop_outlined,
                        etiqueta: 'ADBLUE',
                      ),
                    ),
                  if (auton != null)
                    SizedBox(
                      width: celdaWidth,
                      child: _CeldaTelemetria(
                        icono: Icons.route,
                        color: c.brand,
                        valor: auton.toStringAsFixed(0),
                        unidad: 'km',
                        etiqueta: 'AUTONOMÍA',
                      ),
                    ),
                ];
                return Wrap(
                  spacing: 8,
                  runSpacing: 12,
                  children: celdas,
                );
              },
            )
          // Fallback: solo KM para unidades sin combustible/autonomía.
          : Row(
              children: [
                Icon(Icons.speed, color: c.brand, size: 20),
                const SizedBox(width: 10),
                Text('Kilometraje',
                    style: AppType.label.copyWith(color: c.textSecondary)),
                const Spacer(),
                Text(
                  '${AppFormatters.formatearKilometraje(km)} km',
                  style: AppType.h5.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
    );
  }
}

class _CeldaTelemetria extends StatelessWidget {
  final IconData icono;
  final Color color;
  final String valor;
  final String unidad;
  final String etiqueta;

  const _CeldaTelemetria({
    required this.icono,
    required this.color,
    required this.valor,
    required this.unidad,
    required this.etiqueta,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Icon(icono, color: color, size: 22),
        const SizedBox(height: 6),
        RichText(
          textAlign: TextAlign.center,
          text: TextSpan(
            children: [
              TextSpan(
                text: valor,
                style: AppType.h5.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              TextSpan(
                text: ' $unidad',
                style: AppType.monoSm.copyWith(color: c.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        AppEyebrow(etiqueta, color: c.textMuted),
      ],
    );
  }
}

/// Celda de telemetría tipo "porcentaje con barrita de progreso" —
/// usada para combustible y AdBlue. El color por umbral lo define
/// `_colorCombustible` (mismo criterio que combustible: > 50 verde,
/// 20-50 naranja, < 20 rojo) — útil porque AdBlue bajo también es
/// urgencia operativa (Euro VI deratea en pocos km).
class _CeldaPorcentaje extends StatelessWidget {
  final double porcentaje;
  final IconData icono;
  final String etiqueta;

  const _CeldaPorcentaje({
    required this.porcentaje,
    required this.icono,
    required this.etiqueta,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pct = porcentaje.clamp(0.0, 100.0);
    final color = _colorCombustible(pct);

    return Column(
      children: [
        Icon(icono, color: color, size: 22),
        const SizedBox(height: 6),
        Text(
          '${pct.toStringAsFixed(0)}%',
          style: AppType.h5.copyWith(
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        SizedBox(
          width: 60,
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.full),
            child: LinearProgressIndicator(
              value: pct / 100,
              backgroundColor: c.surface3,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(height: 4),
        AppEyebrow(etiqueta, color: c.textMuted),
      ],
    );
  }
}

class _VencimientoRow extends StatelessWidget {
  final String patente;
  final String etiqueta;
  final String campoFecha;
  final String campoArchivo;
  final dynamic fecha;
  final String? url;
  final String tituloVisor;

  const _VencimientoRow({
    required this.patente,
    required this.etiqueta,
    required this.campoFecha,
    required this.campoArchivo,
    required this.fecha,
    required this.url,
    required this.tituloVisor,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;
    // Tappeable: abre el sheet de VehiculoActions.documento (mismo
    // patrón que la ficha de Personal). Permite editar la fecha o
    // subir/reemplazar el archivo digital del papel.
    return InkWell(
      onTap: () => VehiculoActions.documento(
        context,
        patente: patente,
        etiqueta: etiqueta,
        campoFecha: campoFecha,
        campoUrl: campoArchivo,
        fechaActual: fecha?.toString(),
        urlActual: url,
      ),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            AppFileThumbnail(url: url, tituloVisor: tituloVisor),
            const SizedBox(width: AppSpacing.md),
            SizedBox(
              // 90 → 110 para acomodar etiquetas largas tipo
              // "EXTINTOR EXTERIOR" o "INSPECCIÓN TÉCNICA" en mobile.
              width: 110,
              child: Text(
                etiqueta.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.eyebrow.copyWith(color: c.textMuted),
              ),
            ),
            Expanded(
              child: Text(
                tieneFecha ? AppFormatters.formatearFecha(fecha) : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.mono.copyWith(color: c.text),
              ),
            ),
            VencimientoBadge(fecha: fecha),
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.edit_outlined, size: 14, color: c.textMuted),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// WIDGETS NUEVOS PARA EL DETALLE EDITABLE INLINE
// =============================================================================

/// Selector de empresa propietaria — dropdown con las 2 razones sociales
/// del grupo Vecchi. Visualmente igual a un DatoEditable, abre un dialog
/// de selección al tappear.
class _DatoEditableEmpresa extends StatelessWidget {
  final String valor;
  final ValueChanged<String> onSave;

  const _DatoEditableEmpresa({required this.valor, required this.onSave});

  static const List<String> _empresas = [
    'VECCHI ARIEL Y VECCHI GRACIELA S.R.L: (30-70910015-3)',
    'SUCESION DE VECCHI CARLOS LUIS: (20-08569424-4)',
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'EMPRESA',
        style: AppType.eyebrow.copyWith(color: c.textMuted),
      ),
      subtitle: Text(
        valor.isEmpty ? '—' : valor,
        // Razón social larga ("VECCHI ARIEL Y VECCHI GRACIELA S.R.L: …")
        // se cortaba feo en mobile. 2 líneas + ellipsis para prolijidad.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style:
            AppType.body.copyWith(fontWeight: FontWeight.w600, color: c.text),
      ),
      // Accent verde para alinear con los `DatoEditable*` compartidos que
      // conviven en esta misma sección de Identificación (no migrables —
      // viven en lib/shared/).
      trailing: Icon(Icons.business_center, color: c.success, size: 20),
      onTap: () => _seleccionar(context),
    );
  }

  void _seleccionar(BuildContext context) {
    final c = context.colors;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Seleccionar empresa'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: _empresas.map((e) {
              final esActual = e == valor;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  esActual
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: esActual ? c.success : c.textMuted,
                  size: 18,
                ),
                title: Text(
                  e,
                  style: AppType.label.copyWith(color: c.text),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  if (!esActual) onSave(e);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}

/// Selector de año — dropdown scrolleable de los últimos 30 años hasta
/// hoy. Al tappear, muestra una lista scrolleable con check del actual.
/// El usuario puede seleccionar fuera del rango con "Otro..." si tiene
/// una unidad muy vieja o un año tipográficamente especial.
class _DatoEditableAnio extends StatelessWidget {
  final int? valorActual;
  final ValueChanged<int?> onSave;

  const _DatoEditableAnio({required this.valorActual, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        'AÑO',
        style: AppType.eyebrow.copyWith(color: c.textMuted),
      ),
      subtitle: Text(
        valorActual?.toString() ?? '—',
        style:
            AppType.body.copyWith(fontWeight: FontWeight.w600, color: c.text),
      ),
      // Accent verde para alinear con los `DatoEditable*` compartidos de la
      // misma sección (no migrables — viven en lib/shared/).
      trailing: Icon(Icons.calendar_view_month, color: c.success, size: 20),
      onTap: () => _seleccionar(context),
    );
  }

  void _seleccionar(BuildContext context) {
    final c = context.colors;
    final ahora = DateTime.now().year;
    // Últimos 30 años + 1 (incluye año actual). Más que eso es ruido.
    final anios = [for (var a = ahora; a >= ahora - 30; a--) a];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Seleccionar año'),
        content: SizedBox(
          width: 280,
          height: 320,
          child: ListView.builder(
            itemCount: anios.length,
            itemBuilder: (_, i) {
              final a = anios[i];
              final esActual = a == valorActual;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  esActual
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  color: esActual ? c.success : c.textMuted,
                  size: 18,
                ),
                title: Text(
                  a.toString(),
                  style: AppType.body.copyWith(color: c.text),
                ),
                onTap: () {
                  Navigator.pop(ctx);
                  if (!esActual) onSave(a);
                },
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Resumen del último service: fecha + km al hacerlo + km restantes
/// hasta el próximo. Edición inline con un botón "Editar" que abre un
/// dialog con AMBOS campos a la vez (Santiago: "un solo botón donde
/// clickeas y se editan ambos").
class _ResumenService extends StatelessWidget {
  final String patente;
  final Map<String, dynamic> data;
  const _ResumenService({required this.patente, required this.data});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fechaRaw = data['ULTIMO_SERVICE_FECHA']?.toString();
    final hayFecha = fechaRaw != null && fechaRaw.isNotEmpty && fechaRaw != '-';
    final ultimoKm = (data['ULTIMO_SERVICE_KM'] as num?)?.toDouble();
    final kmActual = (data['KM_ACTUAL'] as num?)?.toDouble();
    // Default 50.000 (constante centralizada en AppMantenimiento). Antes
    // estaba hardcoded en 30.000, lo que daba "vencido hace X km" incluso
    // cuando todavía faltaba para el service según la fórmula real.
    final intervalo = (data['INTERVALO_SERVICE_KM'] as num?)?.toInt() ??
        AppMantenimiento.intervaloServiceKm.toInt();

    // Calcular km restantes hasta el próximo service (si hay datos).
    int? kmRestantes;
    if (ultimoKm != null && kmActual != null) {
      final proximo = ultimoKm + intervalo;
      kmRestantes = (proximo - kmActual).round();
    }

    final colorRestantes = kmRestantes == null
        ? c.textSecondary
        : kmRestantes < 0
            ? c.error
            : kmRestantes < 2000
                ? c.warning
                : c.success;

    final sinDatos = !hayFecha && ultimoKm == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sinDatos)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: c.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sin último service cargado.',
                    style: AppType.label.copyWith(color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        if (hayFecha)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.event_available, size: 16, color: c.textMuted),
                const SizedBox(width: 6),
                Text(
                  'Último service: ${AppFormatters.formatearFecha(fechaRaw)}',
                  style: AppType.label.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        if (ultimoKm != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.speed_outlined, size: 16, color: c.textMuted),
                const SizedBox(width: 6),
                Text(
                  'KM al hacerlo: ${AppFormatters.formatearMiles(ultimoKm)}',
                  style: AppType.label.copyWith(color: c.textSecondary),
                ),
              ],
            ),
          ),
        if (kmRestantes != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  kmRestantes < 0
                      ? Icons.warning_amber_outlined
                      : Icons.timelapse,
                  size: 16,
                  color: colorRestantes,
                ),
                const SizedBox(width: 6),
                Text(
                  kmRestantes < 0
                      ? 'Service VENCIDO hace ${AppFormatters.formatearMiles(kmRestantes.abs())} km'
                      : 'Próximo service en ${AppFormatters.formatearMiles(kmRestantes)} km',
                  style: AppType.label.copyWith(
                      color: colorRestantes, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        // El último service se sincroniza AUTOMÁTICO desde el historial de
        // taller de Volvo Connect (volvo_sync → ULTIMO_SERVICE_KM/FECHA). Ya no
        // se carga a mano: tener dato manual + automático generaba confusión
        // (decisión Santiago 2026-05-22). Solo lectura.
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(
            children: [
              Icon(Icons.cloud_done_outlined, size: 14, color: c.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sinDatos
                      ? 'Se actualiza solo desde Volvo Connect.'
                      : 'Dato automático desde Volvo Connect.',
                  style: AppType.eyebrow.copyWith(
                      color: c.textMuted, fontStyle: FontStyle.italic),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Extensión local para fallback de strings vacíos.
extension _StringExt on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
