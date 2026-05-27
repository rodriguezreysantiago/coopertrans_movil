// =============================================================================
// COMPONENTES VISUALES de la lista de vehículos — extraídos para mantener
// navegable el screen principal. Comparten privacidad y los imports via
// `part of`. Si necesitás reusar alguno desde otra pantalla, hacelo público
// y movelo a `lib/features/vehicles/widgets/`.
// =============================================================================

part of 'admin_vehiculos_lista_screen.dart';

// =============================================================================
// LISTA POR TIPO (un AppListPage por tab)
// =============================================================================

class _ListaPorTipo extends StatelessWidget {
  final String tipo;
  final bool mostrarInactivos;
  final bool mostrarExcluidos;
  final ExcluidosSet? excluidos;
  const _ListaPorTipo({
    required this.tipo,
    required this.mostrarInactivos,
    required this.mostrarExcluidos,
    required this.excluidos,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<VehiculoProvider>(
      builder: (ctx, provider, _) => AppListPage(
        stream: provider.getVehiculosPorTipo(tipo),
        searchHint: 'Buscar patente, marca, modelo o VIN...',
        emptyTitle: 'Sin ${_pluralPretty(tipo)} cargados',
        emptySubtitle: 'Tocá el botón + para agregar uno',
        emptyIcon: Icons.local_shipping_outlined,
        filter: (doc, q) {
          final data = doc.data() as Map<String, dynamic>;
          if (!mostrarInactivos && !AppActivo.esActivo(data)) {
            return false;
          }
          // Excluidos: tanques combustibles + tractores asignados a
          // tanqueros. La patente es el `doc.id`.
          if (!mostrarExcluidos &&
              ExcluidosService.esExcluido(excluidos, patente: doc.id)) {
            return false;
          }
          final hay = '${doc.id} ${data['MARCA'] ?? ''} '
                  '${data['MODELO'] ?? ''} ${data['VIN'] ?? ''}'
              .toUpperCase();
          return hay.contains(q);
        },
        itemBuilder: (ctx, doc) => _VehiculoCard(doc: doc),
      ),
    );
  }

  String _pluralPretty(String tipo) {
    return AppTiposVehiculo.pluralMinusculas[tipo] ?? tipo.toLowerCase();
  }
}

// =============================================================================
// TARJETA DE VEHÍCULO (vista colapsada)
// =============================================================================

class _VehiculoCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _VehiculoCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final patente = doc.id;
    final marca = (data['MARCA'] ?? 'S/D').toString();
    final modelo = (data['MODELO'] ?? 'S/D').toString();
    final estado = (data['ESTADO'] ?? 'LIBRE').toString().toUpperCase();
    final km = data['KM_ACTUAL'];
    // Avatar de la unidad: si tiene foto cargada, la mostramos circular.
    // Si no, fallback a un ícono según el tipo (tractor / enganche).
    final urlFoto = data['ARCHIVO_FOTO']?.toString();
    final tieneFoto =
        urlFoto != null && urlFoto.isNotEmpty && urlFoto != '-';
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
          onTap: () => _abrirDetalle(context, patente, data),
          highlighted: state.success || state.error != null,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Avatar de la unidad — mismo patrón que _EmpleadoCard.
              // Foto si la cargó el admin; si no, ícono temático (camión
              // para tractor, enganche para acoplados).
              CircleAvatar(
                radius: 24,
                backgroundColor: Colors.white12,
                backgroundImage: tieneFoto ? NetworkImage(urlFoto) : null,
                child: !tieneFoto
                    ? Icon(
                        esTractor ? Icons.local_shipping : Icons.rv_hookup,
                        color: Colors.white54,
                        size: 22,
                      )
                    : null,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Header: patente + badge estado + indicadores
                    Row(
                      children: [
                        Text(
                          patente.toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(width: 10),
                        _EstadoBadge(estado: estado),
                        const Spacer(),
                        if (state.loading)
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        if (state.success)
                          const Icon(Icons.check_circle,
                              color: AppColors.success, size: 16),
                        if (state.error != null)
                          const Icon(Icons.error_outline,
                              color: AppColors.error, size: 16),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // Subtítulo: marca/modelo + km
                    Row(
                      children: [
                        Icon(Icons.local_shipping,
                            size: 12, color: Colors.white.withAlpha(120)),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '$marca $modelo',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Icon(Icons.speed,
                            size: 12, color: Colors.white.withAlpha(120)),
                        const SizedBox(width: 4),
                        Text(
                          '${AppFormatters.formatearKilometraje(km)} km',
                          style: const TextStyle(
                            color: AppColors.success,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    // Telemetría compacta (combustible + autonomía). Solo
                    // se muestra si la unidad reporta esos datos vía
                    // Volvo. Para unidades sin telemetría, esta fila no
                    // aparece y el card queda como antes.
                    _TelemetriaCompacta(data: data),
                    const SizedBox(height: 10),
                    // Vista rápida de vencimientos (badges compactos).
                    // Wrap para que en pantallas chicas los extintores
                    // bajen a una segunda línea sin truncarse.
                    Wrap(
                      spacing: 14,
                      runSpacing: 6,
                      children: [
                        _MiniVencimiento(
                            label: 'RTO', fecha: data['VENCIMIENTO_RTO']),
                        _MiniVencimiento(
                            label: 'Seguro',
                            fecha: data['VENCIMIENTO_SEGURO']),
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
  void _abrirDetalle(BuildContext context, String patente,
          Map<String, dynamic> data) =>
      abrirDetalleVehiculo(context, patente, data);
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
void abrirDetalleVehiculo(BuildContext context, String patente,
    Map<String, dynamic> data) {
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
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, color: Colors.white70, size: 20),
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
              style: TextStyle(fontSize: 11),
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
                style: TextStyle(fontSize: 11),
              ),
            ),
          ),
          const PopupMenuItem(
            value: 'diag',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.bug_report_outlined,
                  color: AppColors.warning),
              title: Text('Diagnóstico Volvo'),
              subtitle: Text(
                'Inspeccionar última respuesta del API',
                style: TextStyle(fontSize: 11),
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
      final metros =
          await VolvoApiService().traerKilometrajeCualquierVia(vin);
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
        AppFeedback.warningOn(
            messenger, 'Unidad en reposo o no encontrada.');
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
    final marca = (data['MARCA'] ?? '').toString();
    final modelo = (data['MODELO'] ?? '').toString();
    final anioInt =
        (data['ANIO'] ?? data['AÑO'] as Object?) as int? ??
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
    final sugerenciasMarca = esTractor
        ? const <String>['VOLVO']
        : const <String>[];

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
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (anioInt > 0)
                    Text(
                      'Año $anioInt',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 12),
                    ),
                ],
              ),
            ),
            _EstadoBadge(estado: estado),
          ],
        ),
        const SizedBox(height: 16),

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
          const _SectionTitle(icon: Icons.build_circle_outlined, label: 'Service'),
          _ResumenService(patente: patente, data: data),
        ],

        const SizedBox(height: 18),
        const _SectionTitle(
            icon: Icons.fingerprint, label: 'Identificación'),
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
        for (final spec
            in AppVencimientos.forTipo(data['TIPO']?.toString()))
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
                style:
                    const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: 8),
              if ((data['SINCRO_TIPO'] ?? '') != '')
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.accentCyan.withAlpha(20),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    (data['SINCRO_TIPO'] ?? '').toString(),
                    style: const TextStyle(
                      color: AppColors.accentCyan,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
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
    final activo = AppActivo.esActivo(data);
    if (activo) {
      return Center(
        child: TextButton.icon(
          onPressed: () => VehiculoActions.confirmarYDarDeBaja(
            context,
            patente: patente,
          ),
          icon: const Icon(Icons.do_not_disturb_on_outlined,
              color: AppColors.error),
          label: const Text(
            'Dar de baja',
            style: TextStyle(
              color: AppColors.error,
              fontWeight: FontWeight.bold,
            ),
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
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.warning.withAlpha(20),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.warning.withAlpha(80)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.archive_outlined,
                  color: AppColors.warning, size: 18),
              SizedBox(width: 8),
              Text(
                'UNIDAD DADA DE BAJA',
                style: TextStyle(
                  color: AppColors.warning,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Fecha: $bajaEnFmt',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          if (motivo.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              'Motivo: $motivo',
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
          const SizedBox(height: 12),
          Center(
            child: TextButton.icon(
              onPressed: () => VehiculoActions.confirmarYReactivar(
                context,
                patente: patente,
              ),
              icon: const Icon(Icons.unarchive_outlined,
                  color: AppColors.success),
              label: const Text(
                'Reactivar',
                style: TextStyle(
                  color: AppColors.success,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EstadoBadge extends StatelessWidget {
  final String estado;
  const _EstadoBadge({required this.estado});

  Color get _color {
    switch (estado.toUpperCase()) {
      case 'LIBRE':
        return AppColors.success;
      case 'OCUPADO':
      case 'ASIGNADO':
        return AppColors.info;
      case 'TALLER':
      case 'MANTENIMIENTO':
        return AppColors.warning;
      case 'BAJA':
      case 'INACTIVO':
        return AppColors.error;
      default:
        return Colors.white54;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color.withAlpha(30),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: _color.withAlpha(80)),
      ),
      child: Text(
        estado,
        style: TextStyle(
          color: _color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
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
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.event_note, size: 12, color: Colors.white38),
        const SizedBox(width: 4),
        Text(label,
            style:
                const TextStyle(color: Colors.white54, fontSize: 11)),
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, color: AppColors.success, size: 16),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.success,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
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
              color: AppColors.accentCyan,
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
        color: color.withAlpha(20),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withAlpha(60)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icono, color: color, size: 12),
          const SizedBox(width: 4),
          Text(
            texto,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
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
    final km = _toDouble(data['KM_ACTUAL']);
    final fuel = _toDouble(data['NIVEL_COMBUSTIBLE']);
    final adblue = _toDouble(data['NIVEL_ADBLUE']);
    final auton = _toDouble(data['AUTONOMIA_KM']);
    final hayTelemetria = fuel != null || adblue != null || auton != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
      decoration: BoxDecoration(
        color: AppColors.success.withAlpha(15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.success.withAlpha(40)),
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
                      color: AppColors.success,
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
                        color: AppColors.accentCyan,
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
          // Fallback: igual que antes para unidades sin combustible/autonomía.
          : Row(
              children: [
                const Icon(Icons.speed, color: AppColors.success),
                const SizedBox(width: 10),
                const Text('Kilometraje',
                    style: TextStyle(color: Colors.white60, fontSize: 12)),
                const Spacer(),
                Text(
                  '${AppFormatters.formatearKilometraje(km)} km',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
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
    return Column(
      children: [
        Icon(icono, color: color, size: 22),
        const SizedBox(height: 6),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: valor,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              TextSpan(
                text: ' $unidad',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 2),
        Text(
          etiqueta,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
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
    final pct = porcentaje.clamp(0.0, 100.0);
    final color = _colorCombustible(pct);

    return Column(
      children: [
        Icon(icono, color: color, size: 22),
        const SizedBox(height: 6),
        Text(
          '${pct.toStringAsFixed(0)}%',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 60,
          height: 4,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct / 100,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          etiqueta,
          style: const TextStyle(
            color: Colors.white38,
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
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
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            AppFileThumbnail(url: url, tituloVisor: tituloVisor),
            const SizedBox(width: 12),
            SizedBox(
              // 90 → 110 para acomodar etiquetas largas tipo
              // "EXTINTOR EXTERIOR" o "INSPECCIÓN TÉCNICA" en mobile.
              width: 110,
              child: Text(
                etiqueta,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Expanded(
              child: Text(
                tieneFecha ? AppFormatters.formatearFecha(fecha) : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
            ),
            VencimientoBadge(fecha: fecha),
            const SizedBox(width: 4),
            const Icon(Icons.edit_outlined,
                size: 14, color: Colors.white38),
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        'EMPRESA',
        style: TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        valor.isEmpty ? '—' : valor,
        // Razón social larga ("VECCHI ARIEL Y VECCHI GRACIELA S.R.L: …")
        // se cortaba feo en mobile. 2 líneas + ellipsis para prolijidad.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: const Icon(Icons.business_center,
          color: AppColors.success, size: 20),
      onTap: () => _seleccionar(context),
    );
  }

  void _seleccionar(BuildContext context) {
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
                  color: esActual ? AppColors.success : Colors.white38,
                  size: 18,
                ),
                title: Text(
                  e,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
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
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text(
        'AÑO',
        style: TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        valorActual?.toString() ?? '—',
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing: const Icon(Icons.calendar_view_month,
          color: AppColors.success, size: 20),
      onTap: () => _seleccionar(context),
    );
  }

  void _seleccionar(BuildContext context) {
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
                  color: esActual ? AppColors.success : Colors.white38,
                  size: 18,
                ),
                title: Text(
                  a.toString(),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
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
        ? Colors.white60
        : kmRestantes < 0
            ? AppColors.error
            : kmRestantes < 2000
                ? AppColors.warning
                : AppColors.success;

    final sinDatos = !hayFecha && ultimoKm == null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (sinDatos)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 16, color: Colors.white38),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Sin último service cargado.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
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
                const Icon(Icons.event_available,
                    size: 16, color: Colors.white54),
                const SizedBox(width: 6),
                Text(
                  'Último service: ${AppFormatters.formatearFecha(fechaRaw)}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        if (ultimoKm != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.speed_outlined,
                    size: 16, color: Colors.white54),
                const SizedBox(width: 6),
                Text(
                  'KM al hacerlo: ${AppFormatters.formatearMiles(ultimoKm)}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
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
                  style: TextStyle(
                    color: colorRestantes,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
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
              const Icon(Icons.cloud_done_outlined,
                  size: 14, color: Colors.white38),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  sinDatos
                      ? 'Se actualiza solo desde Volvo Connect.'
                      : 'Dato automático desde Volvo Connect.',
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
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
