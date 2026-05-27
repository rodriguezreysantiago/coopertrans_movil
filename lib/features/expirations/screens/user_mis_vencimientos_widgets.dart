// =============================================================================
// COMPONENTES VISUALES de "mis vencimientos" — extraídos para mantener
// navegable el screen principal. Comparten privacidad via `part of`.
// =============================================================================

part of 'user_mis_vencimientos_screen.dart';

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

class _SectionHeader extends StatelessWidget {
  final String label;
  const _SectionHeader(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 5),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: AppColors.success,
          letterSpacing: 2,
        ),
      ),
    );
  }
}

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
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          highlighted: enRevision,
          borderColor: enRevision ? AppColors.accentOrange.withAlpha(150) : null,
          child: Row(
            children: [
              AppFileThumbnail(
                url: urlArchivo,
                tituloVisor: '$titulo - $idDoc',
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      enRevision
                          ? 'Validación pendiente...'
                          : 'Vence: ${AppFormatters.formatearFecha(fecha)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: enRevision
                            ? AppColors.accentOrange
                            : Colors.white60,
                        fontWeight: enRevision
                            ? FontWeight.bold
                            : FontWeight.normal,
                        letterSpacing: enRevision ? 1 : 0,
                      ),
                    ),
                  ],
                ),
              ),
              if (!enRevision) ...[
                VencimientoBadge(fecha: fecha),
                const SizedBox(width: 8),
                _BotonUpload(onTap: onUpload),
              ] else
                const Icon(Icons.hourglass_top,
                    color: AppColors.accentOrange, size: 20),
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
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(50),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white24),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.upload_file,
              color: Colors.white70, size: 18),
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
    if (cuitEmpresa == null || cuitEmpresa!.isEmpty) {
      return _placeholder('No tenés empresa cargada — consultá a la oficina.');
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
          return _placeholder('Documentación a cargo de la oficina.');
        }
        final data = snap.data?.data() ?? const <String, dynamic>{};
        final fecha = data[campoFecha];
        final url = data[campoUrl]?.toString();
        final tieneArchivo =
            url != null && url.isNotEmpty && url != '-';

        return AppCard(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              AppFileThumbnail(
                url: url,
                tituloVisor: titulo,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      titulo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tieneArchivo || fecha != null
                          ? 'Vence: ${AppFormatters.formatearFecha(fecha)}'
                          : 'Pendiente — consultar a la oficina',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: tieneArchivo || fecha != null
                            ? Colors.white60
                            : Colors.white38,
                      ),
                    ),
                  ],
                ),
              ),
              VencimientoBadge(fecha: fecha),
              const SizedBox(width: 8),
              // Sin botón upload — el chofer no edita estos docs.
              // Lock icon visible para que se entienda que es view-only.
              const Icon(Icons.lock_outline,
                  color: Colors.white24, size: 18),
            ],
          ),
        );
      },
    );
  }

  Widget _placeholder(String subtitulo) {
    return AppCard(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: Colors.white38, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  titulo,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitulo,
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
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
    return AppCard(
      padding: const EdgeInsets.all(18),
      margin: EdgeInsets.zero,
      child: Text(
        mensaje,
        style: const TextStyle(
          color: Colors.white54,
          fontStyle: FontStyle.italic,
          fontSize: 12,
        ),
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
          padding: const EdgeInsets.all(16),
          margin: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 10, left: 5),
                child: Text(
                  '$tipo: $patente',
                  style: const TextStyle(
                    color: AppColors.success,
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
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
              const SizedBox(height: 8),
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

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.checklists)
          .where('DNI', isEqualTo: dniUser)
          .where('DOMINIO', isEqualTo: patente)
          .where('MES', isEqualTo: now.month)
          .where('ANIO', isEqualTo: now.year)
          .orderBy('FECHA', descending: true)
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
          color = AppColors.success;
          // .toLocal() defensivo: Timestamp.toDate() en Dart suele
          // devolver local pero no esta garantizado en todos los runtimes.
          // Sin esto, format en zonas UTC podria mostrar dia anterior.
          final fechaDoc =
              (snap.data!.docs.first['FECHA'] as Timestamp).toDate().toLocal();
          mensaje =
              'Checklist realizado (${AppFormatters.formatearFechaCorta(fechaDoc)})';
          icono = Icons.check_circle;
        } else if (dia > 15) {
          color = AppColors.accentRed;
          mensaje = 'Checklist VENCIDO: realizar YA';
          icono = Icons.warning_amber_rounded;
        } else if (dia > 10) {
          color = AppColors.accentOrange;
          mensaje = 'Checklist pendiente (vence el día 15)';
          icono = Icons.fact_check_outlined;
        } else {
          color = Colors.white60;
          mensaje = 'Checklist pendiente';
          icono = Icons.fact_check_outlined;
        }

        return Container(
          decoration: BoxDecoration(
            color: color.withAlpha(20),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withAlpha(60)),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
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
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                trailing:
                    Icon(Icons.arrow_forward_ios, color: color, size: 14),
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
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: _procesando ? null : _capturar,
        style: TextButton.styleFrom(
          backgroundColor: AppColors.success.withAlpha(20),
          foregroundColor: AppColors.success,
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: AppColors.success.withAlpha(80)),
          ),
        ),
        icon: _procesando
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.success,
                ),
              )
            : const Icon(Icons.document_scanner_outlined, size: 18),
        label: Text(
          _procesando
              ? 'Analizando comprobante...'
              : 'Detectar fecha desde foto',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// _BannerProximoAVencer — resumen al tope de la pantalla
// ============================================================================

/// Banner en la cabecera de MIS VENCIMIENTOS que avisa cuál es el
/// vencimiento más urgente del chofer (de sus papeles personales y
/// los de su equipo). Sin ruido si todos los papeles están OK.
///
/// Pedido Santiago 2026-05-14: el chofer hoy escanea las cards una
/// por una. Un banner arriba con el papel más urgente cambia la
/// utilidad de la pantalla.
class _BannerProximoAVencer extends StatefulWidget {
  final Map<String, dynamic> empleadoData;
  final String patenteVehiculo;
  final String patenteEnganche;

  const _BannerProximoAVencer({
    required this.empleadoData,
    required this.patenteVehiculo,
    required this.patenteEnganche,
  });

  @override
  State<_BannerProximoAVencer> createState() => _BannerProximoAVencerState();
}

class _BannerProximoAVencerState extends State<_BannerProximoAVencer> {
  Stream<List<Map<String, dynamic>>> _equiposStream() async* {
    final patentes = [
      if (widget.patenteVehiculo.isNotEmpty &&
          widget.patenteVehiculo != '-')
        widget.patenteVehiculo,
      if (widget.patenteEnganche.isNotEmpty &&
          widget.patenteEnganche != '-')
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
        if (data != null) docs.add(data);
      } catch (_) {
        // Best effort: si falla un equipo, seguimos con el resto.
      }
    }
    yield docs;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _equiposStream(),
      initialData: const [],
      builder: (ctx, snap) {
        final equipos = snap.data ?? const <Map<String, dynamic>>[];
        final candidatos = _recolectarCandidatos(widget.empleadoData, equipos);
        if (candidatos.isEmpty) return const SizedBox.shrink();

        candidatos.sort((a, b) {
          final aD = a.dias ?? 99999;
          final bD = b.dias ?? 99999;
          return aD.compareTo(bD);
        });
        final top = candidatos.first;
        final estado = top.estado;

        // Si todo está OK (días > 30) o sin fecha, no mostramos banner.
        if (estado == VencimientoEstado.ok ||
            estado == VencimientoEstado.sinFecha) {
          return const SizedBox.shrink();
        }

        final color = estado.color;
        final extras = candidatos
                .where((c) =>
                    c.estado != VencimientoEstado.ok &&
                    c.estado != VencimientoEstado.sinFecha)
                .length -
            1;
        final dias = top.dias;
        final mensaje = switch (estado) {
          VencimientoEstado.vencido =>
            '${top.titulo} VENCIDO${dias != null ? " hace ${(-dias)} día(s)" : ""}',
          VencimientoEstado.invalida =>
            '${top.titulo} tiene una fecha inválida — revisalo con la oficina.',
          VencimientoEstado.critico => '${top.titulo} vence en $dias día(s)',
          VencimientoEstado.proximo => '${top.titulo} vence en $dias día(s)',
          _ => top.titulo,
        };

        return Container(
          margin: const EdgeInsets.fromLTRB(0, 0, 0, 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Row(
            children: [
              Icon(
                estado == VencimientoEstado.vencido
                    ? Icons.error_outline
                    : Icons.warning_amber_outlined,
                color: color,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      mensaje,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    if (extras > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Y $extras papel(es) más por vencer pronto.',
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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

// ============================================================================
// _VencimientoOfflineFallback — UI degradada cuando red está lenta
// ============================================================================

class _VencimientoOfflineFallback extends StatelessWidget {
  final String? motivo;
  const _VencimientoOfflineFallback({this.motivo});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            color: AppColors.accentAmber.withValues(alpha: 0.7),
            size: 64,
          ),
          const SizedBox(height: 16),
          Text(
            motivo == null ? 'Conexión lenta' : 'Sin datos',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            motivo ??
                'Estamos teniendo problemas para traer tus vencimientos. '
                    'Probá de nuevo en unos segundos o conectate a una mejor red.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }
}
