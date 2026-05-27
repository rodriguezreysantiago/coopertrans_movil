// =============================================================================
// COMPONENTES VISUALES de la lista de personal — extraídos para mantener
// navegable el screen principal. Comparten privacidad y los imports via
// `part of`.
// =============================================================================

part of 'admin_personal_lista_screen.dart';

// =============================================================================
// CARD DE LA LISTA (vista colapsada)
// =============================================================================

class _EmpleadoCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;
  const _EmpleadoCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final dni = doc.id;
    final nombre = (data['NOMBRE'] ?? 'Sin nombre').toString();
    final apodo = (data['APODO'] ?? '').toString().trim();
    // Normalizamos para que datos viejos con ROL='USER' caigan a CHOFER.
    final rol = AppRoles.normalizar(data['ROL']?.toString());
    final area = (data['AREA'] ?? AppAreas.manejo).toString();
    final tractor = (data['VEHICULO'] ?? '-').toString();
    final enganche = (data['ENGANCHE'] ?? '-').toString();
    // Solo mostramos vehículo/enganche para empleados del área de
    // MANEJO. Si el admin cambió el área (ej. a TALLER), la card
    // refleja eso aunque el ROL siga siendo CHOFER. Eso permite
    // descubrir inconsistencias visualmente — un CHOFER+TALLER es
    // raro y conviene que el admin corrija el rol también.
    final mostrarFlota = area == AppAreas.manejo;
    final urlPerfil = data['ARCHIVO_PERFIL']?.toString();

    return AppCard(
      onTap: () => _DetalleChofer.abrir(context, dni),
      child: Row(
        children: [
          FotoPerfilAvatar(url: urlPerfil, radius: 24),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: RichText(
                        overflow: TextOverflow.ellipsis,
                        text: TextSpan(
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 14,
                          ),
                          children: [
                            TextSpan(text: nombre),
                            if (apodo.isNotEmpty)
                              TextSpan(
                                text: '  ($apodo)',
                                style: const TextStyle(
                                  color: AppColors.success,
                                  fontWeight: FontWeight.w500,
                                  fontSize: 12,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    // Mostramos badge solo cuando el rol no es CHOFER.
                    // CHOFER es el caso esperado por default — agregar
                    // un chip "CHOFER" sería ruido visual.
                    if (rol != AppRoles.chofer) _RolBadge(rol: rol),
                  ],
                ),
                const SizedBox(height: 4),
                if (mostrarFlota)
                  Row(
                    children: [
                      const Icon(Icons.local_shipping,
                          size: 11, color: Colors.white38),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          tractor,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Icon(Icons.link, size: 11, color: Colors.white38),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          enganche,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    children: [
                      const Icon(Icons.factory_outlined,
                          size: 11, color: Colors.white38),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          AppAreas.etiquetas[area] ?? area,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 11),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: Colors.white24),
        ],
      ),
    );
  }
}

/// Badge que indica el rol del empleado en la lista.
/// Color por rol — rojo para ADMIN (atención), naranja para SUPERVISOR
/// (mando medio), gris claro para PLANTA (no es excepcional). CHOFER no
/// muestra badge: es el caso esperado por default.
class _RolBadge extends StatelessWidget {
  final String rol;
  const _RolBadge({required this.rol});

  Color _color() {
    switch (rol) {
      case AppRoles.admin:
        return AppColors.accentRed;
      case AppRoles.supervisor:
        return AppColors.warning;
      case AppRoles.planta:
        return AppColors.accentLightBlue;
    }
    return Colors.white60;
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        (AppRoles.etiquetas[rol] ?? rol).toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

// =============================================================================
// DETALLE DEL CHOFER (bottom sheet)
// =============================================================================

/// Wrapper público para abrir la ficha del chofer desde otros features
/// (ej. el CommandPalette / búsqueda Ctrl+K).
///
/// `_DetalleChofer.abrir` es privado por convención del archivo; este
/// alias top-level expone el mismo flujo sin filtrar el detalle interno.
Future<void> abrirDetalleChofer(BuildContext context, String dni) =>
    _DetalleChofer.abrir(context, dni);

class _DetalleChofer extends StatelessWidget {
  final String dni;
  final ScrollController scrollController;
  const _DetalleChofer({required this.dni, required this.scrollController});

  /// Helper para abrir el detalle desde cualquier parte.
  static Future<void> abrir(BuildContext context, String dni) {
    return AppDetailSheet.show(
      context: context,
      title: 'Ficha del chofer',
      icon: Icons.badge,
      builder: (sheetCtx, scrollCtl) =>
          _DetalleChofer(dni: dni, scrollController: scrollCtl),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection(AppCollections.empleados)
          .doc(dni)
          .snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return AppErrorState(
            title: 'No se pudo cargar el empleado',
            subtitle: snap.error.toString(),
          );
        }
        if (!snap.hasData) return const AppLoadingState();
        if (!snap.data!.exists) {
          return const AppErrorState(
            title: 'Empleado no encontrado',
            subtitle: 'Puede haber sido eliminado.',
          );
        }
        final data = snap.data!.data() as Map<String, dynamic>;
        return _buildBody(context, data);
      },
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> data) {
    // Mostramos la sección de asignación de unidades solo si el
    // empleado pertenece al área de MANEJO. Si lo movieron a TALLER,
    // GOMERIA, etc, no tiene sentido mostrar tractor/enganche.
    final area = (data['AREA'] ?? AppAreas.manejo).toString();
    final esDeManejo = area == AppAreas.manejo;

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.all(20),
      children: [
        _HeaderDetalle(dni: dni, data: data),
        const SizedBox(height: 20),
        const Divider(color: Colors.white10),

        const _SectionTitle(icon: Icons.badge, label: 'Documentación personal'),
        // El DNI ES el doc id en EMPLEADOS. La edición visualmente es
        // igual al resto de los campos (lápiz, dialog para tipear el
        // valor nuevo) pero al guardar dispara `renombrarDni` — que
        // pide confirmación + llama a la Cloud Function que recrea el
        // legajo y cascadea las referencias en ASIGNACIONES_VEHICULO,
        // VOLVO_ALERTAS y COLA_WHATSAPP.
        _DatoEditableTexto(
          etiqueta: 'DNI',
          valor: dni,
          inputFormatters: [DigitOnlyFormatter(maxLength: 8)],
          keyboardType: TextInputType.number,
          aplicarMayusculas: false,
          onSave: (v) =>
              EmpleadoActions.renombrarDni(context, dni, dniNuevoSugerido: v),
        ),
        _DatoEditableTexto(
          etiqueta: 'CUIL',
          valor: AppFormatters.formatearCUIL(data['CUIL'] ?? '-'),
          inputFormatters: [DigitOnlyFormatter(maxLength: 11)],
          keyboardType: TextInputType.number,
          aplicarMayusculas: false,
          // El AppFormatters muestra "20-12345678-9" pero guardamos crudo.
          onSave: (v) => EmpleadoActions.dato(
              context, dni, 'CUIL', v.replaceAll('-', '')),
        ),
        _DatoEditableTexto(
          etiqueta: 'MAIL',
          valor: (data['MAIL'] ?? '-').toString(),
          keyboardType: TextInputType.emailAddress,
          // El mail va lowercase, no en MAYÚSCULAS como los demás campos.
          aplicarMayusculas: false,
          onSave: (v) =>
              EmpleadoActions.dato(context, dni, 'MAIL', v.toLowerCase()),
        ),
        _DatoEditableTexto(
          etiqueta: 'APODO',
          // Mostramos lo cargado, o '-' si está vacío (visualmente
          // indica al admin que falta cargar). Si el admin guarda
          // string vacío, persistimos null para distinguir "vacío
          // intencional" de "todavía no editado".
          valor: ((data['APODO'] ?? '').toString().isEmpty
              ? '-'
              : data['APODO'].toString()),
          // El apodo respeta como lo escribe el admin: "Carlos" en
          // lugar de "CARLOS" (más natural al saludar).
          aplicarMayusculas: false,
          onSave: (v) => EmpleadoActions.dato(
              context, dni, 'APODO', v.trim().isEmpty ? null : v.trim()),
        ),
        // El dropdown de ROL solo es editable para usuarios con la
        // capability `cambiarRolEmpleado` (hoy solo ADMIN). SUPERVISOR
        // ve el rol como solo-lectura (sin abrir el selector al tap).
        // Y la opcion 'Admin' se filtra del listado si el usuario no
        // tiene `asignarRolAdmin` -- previene que un futuro SUPERVISOR
        // promueva a alguien a admin (la rule server-side rechazaria
        // igual, pero la UI deberia ocultar lo que no se puede hacer).
        _DatoEditableEnum(
          etiqueta: 'ROL',
          valorActual: AppRoles.normalizar(data['ROL']?.toString()),
          // 6 roles del sistema (ver AppRoles.todos). Antes faltaban
          // GOMERIA y SEG_HIGIENE — si editabas a un empleado con esos
          // roles, al guardar cualquier otra opción se perdía el rol
          // original sin warning (el dropdown solo mostraba 4 opciones).
          opciones: {
            AppRoles.chofer: 'Chofer (con vehículo)',
            AppRoles.planta: 'Planta (sin vehículo)',
            AppRoles.gomeria: 'Gomería (solo cubiertas)',
            AppRoles.segHigiene: 'Seg. e Higiene (ICM + Volvo)',
            AppRoles.supervisor: 'Supervisor (gestión)',
            if (Capabilities.can(
                PrefsService.rol, Capability.asignarRolAdmin))
              AppRoles.admin: 'Admin (control total)',
          },
          icono: Icons.badge_outlined,
          editable: Capabilities.can(
              PrefsService.rol, Capability.cambiarRolEmpleado),
          // Cambio de ROL pasa por la Cloud Function `actualizarRolEmpleado`
          // que valida (solo ADMIN), actualiza el doc Y refresca el
          // custom claim del usuario afectado.
          onSave: (v) =>
              EmpleadoActions.actualizarRol(context, dni, nuevoRol: v),
        ),
        _DatoEditableEnum(
          etiqueta: 'ÁREA',
          valorActual: (data['AREA'] ?? AppAreas.manejo).toString(),
          opciones: AppAreas.etiquetas,
          icono: Icons.factory_outlined,
          // El área no afecta permisos pero igual va por la callable
          // para que el claim del usuario quede sincronizado (la app
          // del afectado lo lee del JWT, no de Firestore).
          onSave: (v) =>
              EmpleadoActions.actualizarRol(context, dni, nuevaArea: v),
        ),
        _DatoEditableTexto(
          etiqueta: 'TELÉFONO',
          // Mostramos sin el prefijo 549. El admin reconoce los números
          // por código de área (291, 11, etc), no por código de país.
          // Al guardar, paraGuardar() agrega 549 automáticamente.
          valor: PhoneFormatter.paraMostrar(data['TELEFONO']?.toString()),
          // Teléfono: solo dígitos. El admin puede tipear con/sin 549,
          // con/sin guiones, etc. — `paraGuardar` normaliza al persistir.
          inputFormatters: [DigitOnlyFormatter()],
          keyboardType: TextInputType.phone,
          aplicarMayusculas: false,
          // `telefono()` normaliza + avisa si el número es inválido en vez
          // de pisar el dato bueno con "" (bug Errazu 2026-05-20).
          onSave: (v) => EmpleadoActions.telefono(context, dni, v),
        ),
        _DatoEditableEmpresa(
          valor: (data['EMPRESA'] ?? '-').toString(),
          onSave: (v) => EmpleadoActions.dato(context, dni, 'EMPRESA', v),
        ),

        const Divider(color: Colors.white10),
        const _SectionTitle(
            icon: Icons.folder_shared, label: 'Vencimientos críticos'),
        _FilaVencimiento(
          dni: dni,
          etiqueta: 'LICENCIA DE CONDUCIR',
          campoFecha: 'VENCIMIENTO_LICENCIA_DE_CONDUCIR',
          campoUrl: 'ARCHIVO_LICENCIA_DE_CONDUCIR',
          data: data,
        ),
        _FilaVencimiento(
          dni: dni,
          etiqueta: 'PREOCUPACIONAL',
          campoFecha: 'VENCIMIENTO_PREOCUPACIONAL',
          campoUrl: 'ARCHIVO_PREOCUPACIONAL',
          data: data,
        ),
        _FilaVencimiento(
          dni: dni,
          etiqueta: 'MANEJO DEFENSIVO',
          campoFecha: 'VENCIMIENTO_CURSO_DE_MANEJO_DEFENSIVO',
          campoUrl: 'ARCHIVO_CURSO_DE_MANEJO_DEFENSIVO',
          data: data,
        ),

        // Sección "Seguros y aportes" eliminada (2026-05-08): los 4
        // docs que vivían acá (Póliza ART, F. 931, Seguro de Vida y
        // pago de cuota sindical) pasaron a nivel empresa empleadora.
        // Se editan desde "Vencimientos → EMPRESAS Y SEGUROS" del panel
        // admin y se reflejan en todos los empleados de esa razón
        // social automáticamente.

        if (esDeManejo) ...[
          const Divider(color: Colors.white10),
          const _SectionTitle(
              icon: Icons.local_shipping, label: 'Asignación de unidades'),
          _AsignacionUnidad(
            dni: dni,
            campo: 'VEHICULO',
            label: 'Tractor',
            actual: (data['VEHICULO'] ?? '').toString(),
          ),
          _AsignacionUnidad(
            dni: dni,
            campo: 'ENGANCHE',
            label: 'Enganche',
            actual: (data['ENGANCHE'] ?? '').toString(),
          ),
          // iButton: código de la tarjeta Sitrack que identifica al
          // chofer cuando sube al tractor. Se usa para cross-check con
          // SITRACK_POSICIONES (driverDocumentNumber) — si Sitrack reporta
          // un DNI distinto al asignado, salta drift.
          _DatoEditableTexto(
            etiqueta: 'IBUTTON SITRACK',
            valor: ((data['IBUTTON'] ?? '').toString().isEmpty
                ? '-'
                : data['IBUTTON'].toString()),
            // Sin formatter de mayúsculas en el widget — lo hacemos en
            // onSave para que el admin pueda pegar el código de Sitrack
            // tal cual viene (a veces lowercase) y se normaliza al guardar.
            aplicarMayusculas: true,
            onSave: (v) => EmpleadoActions.dato(
              context,
              dni,
              'IBUTTON',
              v.trim().isEmpty ? null : v.trim().toUpperCase(),
            ),
          ),
          const SizedBox(height: 12),
          // Botón "Ver actividad": abre tablero con km manejados,
          // tractores usados y eventos Volvo del chofer en los
          // últimos 7/30/90 días.
          _BotonVerActividad(
            dni: dni,
            nombreCompleto: (data['NOMBRE'] ?? '').toString(),
          ),
        ],

        const SizedBox(height: 30),
        // Acción de soft-delete al final de la ficha (siempre visible
        // para que el admin pueda dar de baja / reactivar fácilmente).
        _BotonBajaReactivarEmpleado(dni: dni, data: data),
        const SizedBox(height: 30),
      ],
    );
  }
}

/// Botón final del sheet: muestra "Dar de baja" si el empleado está
/// activo, o un panel "Reactivar" + nota de baja si está inactivo.
class _BotonBajaReactivarEmpleado extends StatelessWidget {
  final String dni;
  final Map<String, dynamic> data;
  const _BotonBajaReactivarEmpleado({required this.dni, required this.data});

  @override
  Widget build(BuildContext context) {
    final activo = AppActivo.esActivo(data);
    final nombre = (data['NOMBRE'] ?? dni).toString();
    if (activo) {
      return Column(
        children: [
          Center(
            child: TextButton.icon(
              onPressed: () => EmpleadoActions.confirmarYResetearContrasena(
                context,
                dni: dni,
                nombreVisible: nombre,
              ),
              icon: const Icon(Icons.lock_reset,
                  color: AppColors.accentAmber),
              label: const Text(
                'Resetear contraseña',
                style: TextStyle(
                  color: AppColors.accentAmber,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          Center(
            child: TextButton.icon(
              onPressed: () => EmpleadoActions.confirmarYDarDeBaja(
                context,
                dni: dni,
                nombreVisible: nombre,
              ),
              icon: const Icon(Icons.person_off_outlined,
                  color: AppColors.accentRed),
              label: const Text(
                'Dar de baja',
                style: TextStyle(
                  color: AppColors.accentRed,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Inactivo: mostrar nota + botón reactivar.
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
                'EMPLEADO DADO DE BAJA',
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
              onPressed: () => EmpleadoActions.confirmarYReactivar(
                context,
                dni: dni,
                nombreVisible: nombre,
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

/// Botón "Ver actividad" — abre el tablero personal del chofer
/// (km manejados, tractores usados, eventos Volvo en los últimos
/// 7/30/90 días). Solo aparece para empleados de manejo.
class _BotonVerActividad extends StatelessWidget {
  final String dni;
  final String nombreCompleto;

  const _BotonVerActividad({required this.dni, required this.nombreCompleto});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChoferActividadScreen(
            dni: dni,
            nombreCompleto: nombreCompleto,
          ),
        ),
      ),
      icon: const Icon(Icons.insights, size: 18),
      label: const Text('Ver actividad'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accentBlue,
        side: BorderSide(color: AppColors.accentBlue.withAlpha(120)),
        minimumSize: const Size(double.infinity, 44),
      ),
    );
  }
}

// =============================================================================
// HEADER DEL DETALLE (foto + nombre)
// =============================================================================

class _HeaderDetalle extends StatelessWidget {
  final String dni;
  final Map<String, dynamic> data;
  const _HeaderDetalle({required this.dni, required this.data});

  @override
  Widget build(BuildContext context) {
    final urlPerfil = data['ARCHIVO_PERFIL']?.toString();

    return Column(
      children: [
        Stack(
          children: [
            FotoPerfilAvatar(
              url: urlPerfil,
              radius: 50,
              iconColor: Colors.white24,
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: GestureDetector(
                onTap: () => EmpleadoActions.fotoPerfil(context, dni, urlPerfil),
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: const BoxDecoration(
                    color: AppColors.success,
                    shape: BoxShape.circle,
                  ),
                  child:
                      const Icon(Icons.edit, size: 18, color: Colors.black),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          (data['NOMBRE'] ?? 'Sin nombre').toString(),
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// COMPONENTES INTERNOS
// =============================================================================

class _SectionTitle extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionTitle({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 10),
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

class _DatoEditableTexto extends StatelessWidget {
  final String etiqueta;
  final String valor;
  final Function(String) onSave;
  /// Formatters opcionales (ej. `DigitOnlyFormatter` para TELÉFONO).
  final List<TextInputFormatter>? inputFormatters;
  /// Tipo de teclado (default text). Útil para teléfono / mail.
  final TextInputType? keyboardType;
  /// Si es false, el dialog NO aplica `.toUpperCase()` al guardar — útil
  /// para campos como mail (lowercase) o teléfono (solo dígitos).
  final bool aplicarMayusculas;

  const _DatoEditableTexto({
    required this.etiqueta,
    required this.valor,
    required this.onSave,
    this.inputFormatters,
    this.keyboardType,
    this.aplicarMayusculas = true,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        valor,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      trailing:
          const Icon(Icons.edit_note, size: 22, color: AppColors.success),
      onTap: () => _mostrarDialogo(context),
    );
  }

  void _mostrarDialogo(BuildContext context) {
    // Pre-cargamos el valor actual y lo dejamos seleccionado completo. Así
    // el admin puede:
    //   - Borrar todo con un solo Delete/Backspace.
    //   - Sobreescribir directamente tipeando (reemplaza la selección).
    // Antes el cursor quedaba al final del texto y el admin tenía que
    // borrar caracter por caracter, lo que llevaba a confusión.
    final controller = TextEditingController(text: valor)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: valor.length,
      );

    String transform(String raw) {
      final t = raw.trim();
      return aplicarMayusculas ? t.toUpperCase() : t;
    }

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Editar $etiqueta'),
        content: TextField(
          controller: controller,
          autofocus: true,
          // Solo aplicamos textCapitalization cuando el caller espera
          // mayúsculas — evita pisar el formatter numérico del TELÉFONO
          // o el mail en lowercase.
          textCapitalization: aplicarMayusculas
              ? TextCapitalization.characters
              : TextCapitalization.none,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Escriba aquí...',
            // Botón X para vaciar el campo de un toque.
            suffixIcon: IconButton(
              icon: const Icon(Icons.clear, color: Colors.white54),
              tooltip: 'Vaciar campo',
              onPressed: () => controller.clear(),
            ),
          ),
          // Permite enviar con Enter sin tener que ir al botón.
          // Importante: cerramos el dialog ANTES de llamar a onSave.
          // Si onSave abre otro dialog (caso renombrarDni), un pop
          // posterior se llevaría puesto a ese segundo dialog en
          // lugar de éste — fix del 2026-05-07.
          onSubmitted: (_) {
            final v = transform(controller.text);
            Navigator.pop(dCtx);
            onSave(v);
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('CANCELAR'),
          ),
          ElevatedButton(
            onPressed: () {
              final v = transform(controller.text);
              Navigator.pop(dCtx);
              onSave(v);
            },
            child: const Text('GUARDAR'),
          ),
        ],
      ),
    );
  }
}

class _DatoEditableEmpresa extends StatelessWidget {
  final String valor;
  final Function(String) onSave;

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
        valor,
        // Razón social larga ("VECCHI ARIEL Y VECCHI GRACIELA S.R.L: …")
        // se cortaba feo en mobile sin guard. 2 líneas + ellipsis para
        // que se vea prolijo y no rompa layout del ListTile.
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      trailing: const Icon(Icons.business_center,
          size: 20, color: AppColors.success),
      onTap: () => _mostrarSelector(context),
    );
  }

  void _mostrarSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: const Text('Seleccionar empresa'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _empresas
              .map(
                (e) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(e,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.white)),
                  onTap: () {
                    onSave(e);
                    Navigator.pop(dCtx);
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

/// Editor genérico de campos enum (rol, área, etc) — un ListTile que
/// muestra el valor actual y al tocar abre un dialog con las opciones.
/// Sigue el mismo patrón visual que `_DatoEditableEmpresa`.
class _DatoEditableEnum extends StatelessWidget {
  final String etiqueta;
  final String valorActual;
  /// Mapa `value → label visible` con todas las opciones válidas.
  final Map<String, String> opciones;
  final IconData icono;
  final ValueChanged<String> onSave;

  /// Si `false`, el tile se ve igual pero no abre el selector al tap
  /// y el icono trailing se atenua. Util para mostrar el dato como
  /// solo-lectura cuando el usuario no tiene la capability para
  /// editarlo (ej. SUPERVISOR mirando el ROL de un empleado).
  final bool editable;

  const _DatoEditableEnum({
    required this.etiqueta,
    required this.valorActual,
    required this.opciones,
    required this.icono,
    required this.onSave,
    this.editable = true,
  });

  @override
  Widget build(BuildContext context) {
    final label = opciones[valorActual] ?? valorActual;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        etiqueta,
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      subtitle: Text(
        label,
        style: const TextStyle(fontSize: 12, color: Colors.white),
      ),
      trailing: Icon(
        icono,
        size: 20,
        // Atenuamos el icono cuando no es editable para que se note
        // visualmente que el dato es solo-lectura.
        color: editable ? AppColors.success : Colors.white24,
      ),
      onTap: editable ? () => _mostrarSelector(context) : null,
    );
  }

  void _mostrarSelector(BuildContext context) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        title: Text('Seleccionar ${etiqueta.toLowerCase()}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: opciones.entries.map((e) {
            final esActual = e.key == valorActual;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                esActual ? Icons.radio_button_checked : Icons.radio_button_off,
                color: esActual ? AppColors.success : Colors.white38,
                size: 18,
              ),
              title: Text(
                e.value,
                style: const TextStyle(fontSize: 13, color: Colors.white),
              ),
              onTap: () {
                Navigator.pop(dCtx);
                if (!esActual) onSave(e.key);
              },
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _FilaVencimiento extends StatelessWidget {
  final String dni;
  final String etiqueta;
  final String campoFecha;
  final String campoUrl;
  final Map<String, dynamic> data;

  const _FilaVencimiento({
    required this.dni,
    required this.etiqueta,
    required this.campoFecha,
    required this.campoUrl,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final fecha = data[campoFecha];
    final url = data[campoUrl]?.toString();
    final tieneFecha = fecha != null && fecha.toString().isNotEmpty;

    return InkWell(
      onTap: () => EmpleadoActions.documento(
        context,
        dni: dni,
        etiqueta: etiqueta,
        campoFecha: campoFecha,
        campoUrl: campoUrl,
        fechaActual: fecha?.toString(),
        urlActual: url,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            AppFileThumbnail(
              url: url,
              tituloVisor: '$etiqueta - $dni',
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    etiqueta,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white54, fontSize: 11),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tieneFecha
                        ? AppFormatters.formatearFecha(fecha)
                        : 'Sin fecha',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            VencimientoBadge(fecha: fecha),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right,
                color: Colors.white24, size: 18),
          ],
        ),
      ),
    );
  }
}

class _AsignacionUnidad extends StatelessWidget {
  final String dni;
  final String campo;
  final String label;
  final String actual;

  const _AsignacionUnidad({
    required this.dni,
    required this.campo,
    required this.label,
    required this.actual,
  });

  @override
  Widget build(BuildContext context) {
    final tieneAsignacion =
        actual.isNotEmpty && actual != '-' && actual != 'SIN ASIGNAR';

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        campo == 'VEHICULO' ? Icons.local_shipping : Icons.link,
        color: tieneAsignacion ? AppColors.success : Colors.white24,
      ),
      title: Text(
        '$label: ${tieneAsignacion ? actual : "—"}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
      ),
      trailing:
          const Icon(Icons.sync_alt, size: 20, color: AppColors.success),
      onTap: () => EmpleadoActions.unidad(context, dni, campo, actual),
    );
  }
}
