// =============================================================================
// COMPONENTES VISUALES de "mis vencimientos" — extraídos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
//
// REFACTOR NÚCLEO · jun 2026 — solo el árbol de widgets. Datos, streams,
// services, cálculo de urgencia/días, navegación y acciones (subir/ver
// archivo) quedaron INTACTOS.
// =============================================================================

part of 'user_mis_vencimientos_screen.dart';

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

/// Card de vencimiento del chofer.
/// Muestra el estado (ok/crítico/vencido/en revisión) y permite iniciar
/// un trámite de renovación o ver el archivo actual.
class _CardVencimientoUser extends StatelessWidget {
  final String titulo;
  final dynamic fecha;
  final String campo;
  final String idDoc;
  final String? urlArchivo;
  final VoidCallback onUpload;

  const _CardVencimientoUser({
    required this.titulo,
    required this.fecha,
    required this.campo,
    required this.idDoc,
    required this.urlArchivo,
    required this.onUpload,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.revisiones)
          .where('dni', isEqualTo: idDoc)
          .where('campo', isEqualTo: campo)
          .snapshots(),
      builder: (context, snap) {
        // Filtro defensivo por estado=PENDIENTE. El admin BORRA el doc
        // al aprobar/rechazar (revision_service.dart:399), así que en
        // teoría todos los que existen están pendientes. Pero defensa
        // explícita por si en el futuro se cambia el flow para
        // conservar histórico (estado: APROBADO/RECHAZADO).
        final docs = snap.data?.docs ?? const <QueryDocumentSnapshot>[];
        final pendientes = docs.where((d) {
          final raw = d.data();
          if (raw is! Map<String, dynamic>) return false;
          final estado = (raw['estado'] ?? 'PENDIENTE').toString();
          return estado == 'PENDIENTE';
        }).toList();
        final enRevision = pendientes.isNotEmpty;

        return AppCard(
          tier: 1,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          accent: enRevision ? c.warning : null,
          child: Row(
            children: [
              AppFileThumbnail(
                url: urlArchivo,
                tituloVisor: '$titulo - $idDoc',
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodyLg
                          .copyWith(color: c.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (enRevision)
                      Text(
                        'Validación pendiente…',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.monoSm.copyWith(
                            color: c.warning, fontWeight: FontWeight.w600),
                      )
                    else
                      Row(
                        children: [
                          Text('Vence  ',
                              style:
                                  AppType.bodySm.copyWith(color: c.textMuted)),
                          Flexible(
                            child: Text(
                              AppFormatters.formatearFecha(fecha),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  AppType.monoSm.copyWith(color: c.textMuted),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (!enRevision) ...[
                VencimientoBadge(fecha: fecha),
                const SizedBox(width: AppSpacing.sm),
                _BotonUpload(onTap: onUpload),
              ] else
                Icon(Icons.hourglass_top, color: c.warning, size: 20),
            ],
          ),
        );
      },
    );
  }
}

class _BotonUpload extends StatelessWidget {
  final VoidCallback onTap;
  const _BotonUpload({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.full),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            border: Border.all(color: c.borderStrong),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.upload_file, color: c.textSecondary, size: 18),
        ),
      ),
    );
  }
}

/// Variante READ-ONLY de [_CardVencimientoUser] — usada para los
/// documentos que viven a nivel EMPRESA empleadora (Póliza ART + F.931).
/// El chofer solo ve la fecha y abre el PDF; no puede subir archivo
/// nuevo ni iniciar trámite (esos docs los carga el admin una sola vez
/// desde la pantalla "Empresas y seguros" y se reflejan acá automático).
///
/// Si el chofer no tiene empresa o la empresa no carga el doc todavía,
/// muestra "Pendiente — consultar a la oficina" en gris y deshabilita
/// el tap.
class _CardVencimientoEmpresa extends StatelessWidget {
  final String titulo;
  final String? cuitEmpresa;
  final String campoFecha;
  final String campoUrl;

  const _CardVencimientoEmpresa({
    required this.titulo,
    required this.cuitEmpresa,
    required this.campoFecha,
    required this.campoUrl,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (cuitEmpresa == null || cuitEmpresa!.isEmpty) {
      return _placeholder(
          context, 'No tenés empresa cargada — consultá a la oficina.');
    }
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.empresasEmpleadoras)
          .doc(cuitEmpresa)
          .snapshots(),
      builder: (context, snap) {
        // CRITICO (auditoria 2026-05-18): la rule de EMPRESAS_EMPLEADORAS
        // se cerro a admin/supervisor/seg_higiene. El chofer ya no puede
        // leer este doc — el stream tira permission-denied. Mostramos
        // placeholder en lugar de error tecnico crudo.
        if (snap.hasError) {
          // El chofer SÍ tiene empresa (cuitEmpresa no es null), pero la rule
          // de EMPRESAS_EMPLEADORAS no lo deja leer el doc (tiene datos
          // sensibles como el F.931). No es "sin empresa" — lo aclaramos.
          return _placeholder(context, 'Documentación a cargo de la oficina.');
        }
        final data = snap.data?.data() ?? const <String, dynamic>{};
        final fecha = data[campoFecha];
        final url = data[campoUrl]?.toString();
        final tieneArchivo = url != null && url.isNotEmpty && url != '-';
        final tieneDato = tieneArchivo || fecha != null;

        return AppCard(
          tier: 1,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg, vertical: AppSpacing.md),
          child: Row(
            children: [
              AppFileThumbnail(
                url: url,
                tituloVisor: titulo,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.bodyLg
                          .copyWith(color: c.text, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    if (tieneDato)
                      Row(
                        children: [
                          Text('Vence  ',
                              style:
                                  AppType.bodySm.copyWith(color: c.textMuted)),
                          Flexible(
                            child: Text(
                              AppFormatters.formatearFecha(fecha),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  AppType.monoSm.copyWith(color: c.textMuted),
                            ),
                          ),
                        ],
                      )
                    else
                      Text(
                        'Pendiente — consultar a la oficina',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            AppType.bodySm.copyWith(color: c.textPlaceholder),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              VencimientoBadge(fecha: fecha),
              const SizedBox(width: AppSpacing.sm),
              // Sin botón upload — el chofer no edita estos docs.
              // Lock icon visible para que se entienda que es view-only.
              Icon(Icons.lock_outline, color: c.textMuted, size: 18),
            ],
          ),
        );
      },
    );
  }

  Widget _placeholder(BuildContext context, String subtitulo) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg, vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: c.textMuted, size: 22),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodyLg.copyWith(
                      color: c.textSecondary, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitulo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.bodySm.copyWith(color: c.textPlaceholder),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CardInformativa extends StatelessWidget {
  final String mensaje;
  const _CardInformativa(this.mensaje);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      tier: 1,
      padding: const EdgeInsets.all(AppSpacing.lg),
      margin: EdgeInsets.zero,
      child: Row(
        children: [
          Icon(Icons.info_outline, color: c.textMuted, size: 18),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              mensaje,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppType.bodySm.copyWith(color: c.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// Card del equipo (camión o enganche) con sus vencimientos + acceso al
/// checklist mensual.
class _DetalleEquipo extends StatelessWidget {
  final String patente;
  final String tipo;
  final String nombreChofer;
  final void Function({
    required String etiqueta,
    required String campo,
    required String idDoc,
    required String coleccion,
    required String nombreUsuario,
  }) onTramiteVehiculo;

  const _DetalleEquipo({
    required this.patente,
    required this.tipo,
    required this.nombreChofer,
    required this.onTramiteVehiculo,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.vehiculos)
          .doc(patente)
          .snapshots(),
      builder: (context, vSnap) {
        if (!vSnap.hasData || !vSnap.data!.exists) {
          return _CardInformativa('Unidad $patente no registrada');
        }
        // Cast defensivo (mismo patrón que en el snapshot del empleado).
        final vRaw = vSnap.data!.data();
        if (vRaw is! Map<String, dynamic>) {
          return _CardInformativa('Datos de $patente corruptos');
        }
        final vData = vRaw;

        return AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Encabezado de la unidad: eyebrow con el tipo + patente
              // grande en mono (dato técnico). Patrón Núcleo (Unidad).
              Row(
                children: [
                  AppEyebrow(tipo),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      patente,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.mono.copyWith(
                        color: c.brand,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              const AppHairline(),
              const SizedBox(height: AppSpacing.xs),
              // Vencimientos del vehículo: tractor (4) o enganche (2),
              // según AppVencimientos. La etiqueta para iniciar trámite
              // es la parte del campo después de VENCIMIENTO_ (ej.
              // "RTO", "SEGURO", "EXTINTOR_CABINA"), que usa el sistema
              // de revisiones para mapear de vuelta al ARCHIVO_ correcto.
              for (final spec in AppVencimientos.forTipo(
                  vData['TIPO']?.toString() ?? tipo))
                _CardVencimientoUser(
                  titulo: spec.etiqueta,
                  fecha: vData[spec.campoFecha],
                  campo: spec.campoFecha,
                  urlArchivo: vData[spec.campoArchivo],
                  idDoc: patente,
                  onUpload: () => onTramiteVehiculo(
                    etiqueta: spec.etiqueta.toUpperCase(),
                    campo: spec.campoFecha,
                    idDoc: patente,
                    coleccion: 'VEHICULOS',
                    nombreUsuario: nombreChofer,
                  ),
                ),
              const SizedBox(height: AppSpacing.sm),
              _AccesoChecklist(patente: patente, tipoLabel: tipo),
            ],
          ),
        );
      },
    );
  }
}

/// Card de acceso al checklist mensual del chofer (con estado visible).
class _AccesoChecklist extends StatelessWidget {
  final String patente;
  final String tipoLabel;

  const _AccesoChecklist({required this.patente, required this.tipoLabel});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final now = DateTime.now();
    final tipoChecklist = tipoLabel == 'CAMIÓN' ? 'TRACTOR' : 'BATEA';

    // Necesitamos el DNI del chofer en el query para evitar permission-
    // denied: la rule de CHECKLISTS exige `resource.data.DNI == auth.uid`
    // y Firestore valida la rule per-doc sobre TODOS los docs que matchea
    // el query, no solo los devueltos. Si otro chofer manejó la misma
    // patente este mes (rotación de unidades), el query toca docs
    // ajenos y falla. Filtrar por DNI=self lo previene.
    // Regresión detectada 2026-05-18 — hardening de rules del 2026-05-17.
    final dniUser = FirebaseAuth.instance.currentUser?.uid;
    if (dniUser == null || dniUser.isEmpty) {
      // Defensa: si no hay sesión, no podemos mostrar nada útil.
      return const SizedBox.shrink();
    }

    // SIN `orderBy('FECHA', descending: true)` — la query solo necesita
    // saber "existe al menos 1 doc de este DNI/patente/mes/año", no cuál
    // es el más nuevo. El orderBy combinado con FieldValue.serverTimestamp
    // en iOS dispara un bug conocido: el doc recién guardado tiene FECHA
    // null en cache local hasta que el server confirma, y el orderBy lo
    // EXCLUYE del snapshot local → el chofer guarda el checklist y la
    // tarjeta sigue mostrando "pendiente" durante segundos/minutos
    // (reporte chofer iPhone 2026-06-08). En Android el mismo doc se
    // muestra al toque porque el SDK lo incluye igual. Quitar el orderBy
    // resuelve el caso iOS sin perder funcionalidad — `limit(1)` con
    // múltiples `where` ya basta para decidir completado vs pendiente.
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.checklists)
          .where('DNI', isEqualTo: dniUser)
          .where('DOMINIO', isEqualTo: patente)
          .where('MES', isEqualTo: now.month)
          .where('ANIO', isEqualTo: now.year)
          .limit(1)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          debugPrint('⚠️ Error checklist: ${snap.error}');
        }

        final completado = snap.hasData && snap.data!.docs.isNotEmpty;
        final dia = now.day;

        Color color;
        String mensaje;
        IconData icono;

        // Todos los textos arrancan con "Checklist" — Santiago 2026-05-14:
        // "tendría que decir Checklist Pendiente para que se entienda
        // bien de que se está hablando cuando clickea ahí". Antes algunos
        // estados decían "Control" o solo "Pendiente" y el chofer no
        // sabía a qué refería.
        if (completado) {
          color = c.success;
          // .toLocal() defensivo: Timestamp.toDate() en Dart suele
          // devolver local pero no esta garantizado en todos los runtimes.
          // Sin esto, format en zonas UTC podria mostrar dia anterior.
          // Cast defensivo (Sentry FLUTTER-Y): si el doc llegara con FECHA
          // null o sin el campo, `as Timestamp` tiraba TypeError y rompía
          // TODA la pantalla de vencimientos. Mostramos el checklist igual,
          // sin la fecha, en vez de crashear.
          final fechaRaw = snap.data!.docs.first['FECHA'];
          final fechaDoc =
              fechaRaw is Timestamp ? fechaRaw.toDate().toLocal() : null;
          mensaje = fechaDoc != null
              ? 'Checklist realizado (${AppFormatters.formatearFechaCorta(fechaDoc)})'
              : 'Checklist realizado';
          icono = Icons.check_circle;
        } else if (dia > 15) {
          color = c.error;
          mensaje = 'Checklist VENCIDO: realizar YA';
          icono = Icons.warning_amber_rounded;
        } else if (dia > 10) {
          color = c.warning;
          mensaje = 'Checklist pendiente (vence el día 15)';
          icono = Icons.fact_check_outlined;
        } else {
          color = c.textSecondary;
          mensaje = 'Checklist pendiente';
          icono = Icons.fact_check_outlined;
        }

        return Container(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: color.withValues(alpha: 0.24)),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(AppRadius.md),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserChecklistFormScreen(
                    tipo: tipoChecklist,
                    patente: patente,
                  ),
                ),
              ),
              child: ListTile(
                dense: true,
                leading: Icon(icono, color: color, size: 22),
                title: Text(
                  mensaje,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.label
                      .copyWith(color: color, fontWeight: FontWeight.w600),
                ),
                trailing: Icon(Icons.arrow_forward_ios, color: color, size: 14),
              ),
            ),
          ),
        );
      },
    );
  }
}

// El _FechaInputFormatter local se reemplazó por FechaInputFormatter
// en lib/shared/utils/fecha_input_formatter.dart (compartido).

/// Botón "Detectar fecha desde foto" — abre la cámara, corre OCR sobre
/// la imagen y, si detecta una fecha válida, llama a [onFechaDetectada]
/// para que el dialog padre la pre-cargue en el TextFormField.
///
/// Best-effort: si el OCR no encuentra nada, se muestra un snackbar
/// informativo y el chofer puede tipear la fecha manualmente.
///
/// Solo se monta cuando `OcrService.soportado` (Android/iOS).
class _BotonDetectarFecha extends StatefulWidget {
  final void Function(DateTime) onFechaDetectada;
  const _BotonDetectarFecha({required this.onFechaDetectada});

  @override
  State<_BotonDetectarFecha> createState() => _BotonDetectarFechaState();
}

class _BotonDetectarFechaState extends State<_BotonDetectarFecha> {
  bool _procesando = false;

  Future<void> _capturar() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _procesando = true);

    try {
      final picker = ImagePicker();
      final foto = await picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 70,
      );
      if (foto == null) {
        if (mounted) setState(() => _procesando = false);
        return;
      }

      final fecha = await OcrService.detectarFecha(foto.path);
      if (!mounted) return;
      setState(() => _procesando = false);

      if (fecha == null) {
        AppFeedback.warningOn(messenger,
            'No se pudo detectar una fecha en la foto. Ingresala manualmente.');
        return;
      }
      widget.onFechaDetectada(fecha);
      AppFeedback.successOn(messenger,
          'Fecha detectada: ${fecha.day}/${fecha.month}/${fecha.year}');
    } catch (e, s) {
      if (mounted) {
        setState(() => _procesando = false);
        AppFeedback.errorTecnicoOn(
          messenger,
          usuario: 'No pude leer la fecha de la foto. Tipeala a mano abajo.',
          tecnico: e,
          stack: s,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppButton.secondary(
      label: _procesando
          ? 'Analizando comprobante...'
          : 'Detectar fecha desde foto',
      icon: Icons.document_scanner_outlined,
      onPressed: _procesando ? null : _capturar,
      isLoading: _procesando,
      expand: true,
    );
  }
}

// ============================================================================
// _HeroEstadoGeneral — hero al tope de la pantalla (estilo Núcleo · VencList)
// ============================================================================

/// Hero en la cabecera de MIS VENCIMIENTOS: muestra el estado general del
/// chofer (conteos vencido/próximo/al día sobre sus papeles personales +
/// los de su equipo) y destaca el papel más urgente debajo.
///
/// Pedido Santiago 2026-05-14: el chofer hoy escanea las cards una por
/// una. Un hero arriba con el resumen + el papel más urgente cambia la
/// utilidad de la pantalla.
class _HeroEstadoGeneral extends StatefulWidget {
  final Map<String, dynamic> empleadoData;
  final String patenteVehiculo;
  final String patenteEnganche;

  const _HeroEstadoGeneral({
    required this.empleadoData,
    required this.patenteVehiculo,
    required this.patenteEnganche,
  });

  @override
  State<_HeroEstadoGeneral> createState() => _HeroEstadoGeneralState();
}

class _HeroEstadoGeneralState extends State<_HeroEstadoGeneral> {
  Stream<List<Map<String, dynamic>>> _equiposStream() async* {
    final patentes = [
      if (widget.patenteVehiculo.isNotEmpty && widget.patenteVehiculo != '-')
        widget.patenteVehiculo,
      if (widget.patenteEnganche.isNotEmpty && widget.patenteEnganche != '-')
        widget.patenteEnganche,
    ];
    if (patentes.isEmpty) {
      yield <Map<String, dynamic>>[];
      return;
    }
    final docs = <Map<String, dynamic>>[];
    for (final p in patentes) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(AppCollections.vehiculos)
            .doc(p)
            .get();
        final data = snap.data();
        // Propagamos la patente (doc id) como campo PATENTE: los docs de
        // VEHICULOS NO guardan ese campo, así que el hero "Estado general"
        // armaba el título con la patente vacía ("RTO de  vence en…").
        if (data != null) docs.add({...data, 'PATENTE': snap.id});
      } catch (_) {
        // Best effort: si falla un equipo, seguimos con el resto.
      }
    }
    yield docs;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _equiposStream(),
      initialData: const [],
      builder: (ctx, snap) {
        final equipos = snap.data ?? const <Map<String, dynamic>>[];
        final candidatos = _recolectarCandidatos(widget.empleadoData, equipos);
        if (candidatos.isEmpty) return const SizedBox.shrink();

        // Conteo por estado para el hero "Estado general" (prototipo Núcleo,
        // VencList). Usamos if/else (no switch) para no depender de la
        // exhaustividad del enum si más adelante se agrega un estado.
        var vencidos = 0, proximos = 0, alDia = 0, sinFecha = 0;
        for (final cand in candidatos) {
          final e = cand.estado;
          if (e == VencimientoEstado.vencido ||
              e == VencimientoEstado.invalida) {
            vencidos++;
          } else if (e == VencimientoEstado.critico ||
              e == VencimientoEstado.proximo) {
            proximos++;
          } else if (e == VencimientoEstado.ok) {
            alDia++;
          } else if (e == VencimientoEstado.sinFecha) {
            sinFecha++;
          }
        }

        // El más urgente (para el aviso debajo del hero).
        candidatos
            .sort((a, b) => (a.dias ?? 99999).compareTo(b.dias ?? 99999));
        final top = candidatos.first;
        final dias = top.dias;
        final hayUrgente = top.estado == VencimientoEstado.vencido ||
            top.estado == VencimientoEstado.invalida ||
            top.estado == VencimientoEstado.critico ||
            top.estado == VencimientoEstado.proximo;
        final mensaje = switch (top.estado) {
          VencimientoEstado.vencido =>
            '${top.titulo} venció${dias != null ? " hace ${-dias} día(s)" : ""}',
          VencimientoEstado.invalida =>
            '${top.titulo}: fecha inválida, revisalo con la oficina',
          VencimientoEstado.critico ||
          VencimientoEstado.proximo =>
            '${top.titulo} vence en $dias día(s)',
          _ => top.titulo,
        };

        // Glow ambient solo cuando todo está OK (gesto firma); si hay algo
        // por vencer, el acento de color ya carga la atención.
        final glow = vencidos == 0 && proximos == 0;

        return AppCard(
          glow: glow,
          accent: vencidos > 0
              ? c.error
              : (proximos > 0 ? c.warning : null),
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AppEyebrow('Estado general'),
              const SizedBox(height: AppSpacing.lg),
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _EstadoStat(
                        valor: vencidos,
                        label: vencidos == 1 ? 'vencido' : 'vencidos',
                        color: c.error,
                      ),
                    ),
                    Container(width: 1, color: c.border),
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.only(left: AppSpacing.lg),
                        child: _EstadoStat(
                          valor: proximos,
                          label: proximos == 1 ? 'próximo' : 'próximos',
                          color: c.warning,
                        ),
                      ),
                    ),
                    Container(width: 1, color: c.border),
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsets.only(left: AppSpacing.lg),
                        child: _EstadoStat(
                          valor: alDia,
                          label: 'al día',
                          color: c.success,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (sinFecha > 0) ...[
                const SizedBox(height: AppSpacing.md),
                Text('$sinFecha sin fecha cargada todavía',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppType.monoSm.copyWith(color: c.textMuted)),
              ],
              if (hayUrgente) ...[
                const SizedBox(height: AppSpacing.lg),
                const AppHairline(),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  children: [
                    Icon(
                      top.estado == VencimientoEstado.vencido ||
                              top.estado == VencimientoEstado.invalida
                          ? Icons.error_outline
                          : Icons.warning_amber_outlined,
                      color: top.estado.color,
                      size: 20,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        mensaje,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppType.body.copyWith(
                          color: top.estado.color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  List<_CandidatoVencimiento> _recolectarCandidatos(
    Map<String, dynamic> empleado,
    List<Map<String, dynamic>> equipos,
  ) {
    final out = <_CandidatoVencimiento>[];
    AppDocsEmpleado.etiquetas.forEach((etiqueta, campoBase) {
      final fecha = empleado['VENCIMIENTO_$campoBase']?.toString();
      out.add(_buildCandidato('Tu $etiqueta', fecha));
    });
    for (final equipo in equipos) {
      final tipo = (equipo['TIPO'] ?? '').toString();
      final patente = (equipo['PATENTE'] ?? '').toString();
      // AppVencimientos.forTipo devuelve la lista de VencimientoSpec
      // según TIPO (TRACTOR/CHASIS o ENGANCHE) — el .campoFecha ya
      // viene con prefijo "VENCIMIENTO_", lo leemos directo.
      final specs = AppVencimientos.forTipo(tipo);
      for (final spec in specs) {
        final fecha = equipo[spec.campoFecha]?.toString();
        out.add(_buildCandidato('${spec.etiqueta} de $patente', fecha));
      }
    }
    return out;
  }

  _CandidatoVencimiento _buildCandidato(String titulo, String? fecha) {
    final tieneFecha = fecha != null && fecha.isNotEmpty;
    final dias =
        tieneFecha ? AppFormatters.calcularDiasRestantes(fecha) : null;
    final estado = calcularEstadoVencimiento(dias, tieneFecha: tieneFecha);
    return _CandidatoVencimiento(
      titulo: titulo,
      dias: dias,
      estado: estado,
    );
  }
}

class _CandidatoVencimiento {
  final String titulo;
  final int? dias;
  final VencimientoEstado estado;
  const _CandidatoVencimiento({
    required this.titulo,
    required this.dias,
    required this.estado,
  });
}

/// Contador del hero "Estado general" — número grande en blanco (regla
/// Núcleo: el hero number es neutro, nunca semántico) + un punto de color
/// y label uppercase que cargan la semántica del estado.
class _EstadoStat extends StatelessWidget {
  final int valor;
  final String label;
  final Color color;
  const _EstadoStat({
    required this.valor,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$valor',
          style: AppType.h3.copyWith(
            color: valor > 0 ? c.text : c.textMuted,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            AppDot(color, size: 6),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppType.eyebrow.copyWith(color: c.textMuted),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ============================================================================
// _VencimientoOfflineFallback — UI degradada cuando red está lenta
// ============================================================================

class _VencimientoOfflineFallback extends StatelessWidget {
  final String? motivo;
  const _VencimientoOfflineFallback({this.motivo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: c.warning.withValues(alpha: 0.7),
            size: 64,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            motivo == null ? 'Conexión lenta' : 'Sin datos',
            textAlign: TextAlign.center,
            style: AppType.h5.copyWith(color: c.text),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            motivo ??
                'Estamos teniendo problemas para traer tus vencimientos. '
                    'Probá de nuevo en unos segundos o conectate a una mejor red.',
            textAlign: TextAlign.center,
            style: AppType.bodySm.copyWith(color: c.textSecondary),
          ),
        ],
      ),
    );
  }
}
