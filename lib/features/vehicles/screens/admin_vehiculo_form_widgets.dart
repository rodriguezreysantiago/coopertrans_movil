// =============================================================================
// COMPONENTES VISUALES del form de edición de vehículos.
//
// Este archivo es `part of` el screen principal: las clases siguen siendo
// privadas (prefijo _) y comparten imports/state con
// `admin_vehiculo_form_screen.dart`. La razón de la división es bajar la
// complejidad del archivo principal (era 1093 líneas mezclando state
// management + 8 widgets de presentación) y poder navegar más rápido al
// editar uno u otro.
//
// Convención: si necesitás reusar alguno de estos widgets desde otra
// pantalla, lo hacés público (sin underscore) y lo movés a
// `lib/shared/widgets/` o `lib/features/vehicles/widgets/`. Mientras
// sigan siendo de uso exclusivo del form, viven acá.
// =============================================================================

part of 'admin_vehiculo_form_screen.dart';

/// Bloque visual con la foto identificatoria de la unidad y un botón
/// "Cambiar foto" debajo. Si no hay foto cargada, muestra un avatar
/// vacío con ícono de camión que invita a tocar.
class _FotoUnidad extends StatelessWidget {
  final String? url;
  final bool subiendo;
  final VoidCallback onTap;

  const _FotoUnidad({
    required this.url,
    required this.subiendo,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tieneFoto = url != null && url!.isNotEmpty;

    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: subiendo ? null : onTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircleAvatar(
                  radius: 50,
                  backgroundColor: AppColors.surface3,
                  backgroundImage:
                      tieneFoto ? NetworkImage(url!) : null,
                  child: !tieneFoto
                      ? const Icon(Icons.local_shipping,
                          size: 44, color: AppColors.textHint)
                      : null,
                ),
                if (subiendo)
                  Container(
                    width: 100,
                    height: 100,
                    decoration: BoxDecoration(
                      color: Colors.black.withAlpha(140),
                      shape: BoxShape.circle,
                    ),
                    child: const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.success,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton.ghost(
            label: tieneFoto ? 'Cambiar foto' : 'Agregar foto',
            icon: tieneFoto ? Icons.edit : Icons.add_a_photo,
            onPressed: subiendo ? null : onTap,
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String label;
  const _SectionTitle(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md, left: 5),
      child: Text(
        label.toUpperCase(),
        style: AppType.eyebrow
            .copyWith(color: AppColors.success, letterSpacing: 1.5),
      ),
    );
  }
}

class _FInput extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final IconData icon;
  final bool isNumber;
  final TextInputAction textInputAction;

  const _FInput({
    required this.controller,
    required this.label,
    required this.icon,
    this.isNumber = false,
    this.textInputAction = TextInputAction.next,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: TextFormField(
        controller: controller,
        keyboardType:
            isNumber ? TextInputType.number : TextInputType.text,
        textCapitalization: TextCapitalization.characters,
        textInputAction: textInputAction,
        // Solo dígitos en KM. Sin esto, el admin podía pegar "100.000"
        // o "100 km" desde el clipboard y romper la sincronización Volvo.
        inputFormatters: isNumber ? [DigitOnlyFormatter()] : null,
        style:
            AppType.body.copyWith(color: AppColors.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(
            icon,
            color: Theme.of(context).colorScheme.primary,
            size: 20,
          ),
        ),
        validator: (value) {
          if (value == null || value.trim().isEmpty) {
            return 'Campo requerido';
          }
          return null;
        },
      ),
    );
  }
}

class _BloqueVolvo extends StatelessWidget {
  final TextEditingController vinController;
  final bool isSyncing;
  final VoidCallback onSync;
  final VoidCallback onDiagnostico;

  const _BloqueVolvo({
    required this.vinController,
    required this.isSyncing,
    required this.onSync,
    required this.onDiagnostico,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.info.withAlpha(20),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.info.withAlpha(50)),
      ),
      child: Column(
        children: [
          _FInput(
            controller: vinController,
            label: 'Código VIN (Volvo)',
            icon: Icons.fingerprint,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: AppSpacing.sm),
          if (isSyncing)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: CircularProgressIndicator(color: AppColors.info),
            )
          else
            AppButton.secondary(
              label: 'Forzar sincro Volvo',
              icon: Icons.sync,
              onPressed: onSync,
              expand: true,
            ),
          const SizedBox(height: AppSpacing.sm),
          // Botón de diagnóstico — abre una pantalla con el JSON crudo
          // del response de Volvo y un análisis automático de qué campos
          // están viniendo. Útil cuando algún dato no aparece en la UI.
          AppButton.ghost(
            label: 'Diagnóstico',
            icon: Icons.bug_report,
            onPressed: onDiagnostico,
            expand: true,
          ),
        ],
      ),
    );
  }
}

class _EmpresaTile extends StatelessWidget {
  final String empresa;
  final VoidCallback onTap;

  const _EmpresaTile({required this.empresa, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      onTap: onTap,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          const Icon(Icons.business, color: AppColors.success),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Empresa titular',
                  style:
                      AppType.eyebrow.copyWith(color: AppColors.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  empresa,
                  // Razón social larga ("VECCHI ARIEL Y …") rompía
                  // la card en mobile. 2 líneas + ellipsis para prolijidad.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppType.heading.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
          const Icon(Icons.edit, color: AppColors.textHint, size: 18),
        ],
      ),
    );
  }
}

class _DateTile extends StatelessWidget {
  final String label;
  final String? fecha;
  final String? url;
  final VoidCallback onTapDate;
  final VoidCallback onTapFile;
  final String tituloVisor;

  const _DateTile({
    required this.label,
    required this.fecha,
    required this.url,
    required this.onTapDate,
    required this.onTapFile,
    required this.tituloVisor,
  });

  @override
  Widget build(BuildContext context) {
    final tieneArchivo = url != null && url!.isNotEmpty && url != '-';

    // No usamos ListTile.onTap porque colisiona con los taps internos de
    // los iconos. En lugar de eso, hacemos clickeable solo la zona del
    // título/fecha (que abre el date picker) y dejamos los iconos del
    // trailing como botones explícitos: Ver + Reemplazar/Subir.
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: 5, vertical: AppSpacing.sm),
      child: Row(
        children: [
          AppFileThumbnail(
            url: url,
            tituloVisor: tituloVisor,
            size: 40,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: InkWell(
              onTap: onTapDate,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    vertical: AppSpacing.xs, horizontal: AppSpacing.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          AppType.label.copyWith(color: AppColors.textTertiary),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      AppFormatters.formatearFecha(fecha ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppType.heading.copyWith(fontSize: 15),
                    ),
                  ],
                ),
              ),
            ),
          ),
          VencimientoBadge(fecha: fecha),
          const SizedBox(width: AppSpacing.xs),
          // visualDensity.compact: cada IconButton pasa de 48 dp a ~36 dp.
          // Con 2 botones + thumb 40 + badge ~70 + Expanded label, el ancho
          // disponible para la fecha en mobile se ajusta y deja de chocar.
          if (tieneArchivo)
            IconButton(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.visibility,
                  color: AppColors.success, size: 22),
              tooltip: 'Ver archivo',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) =>
                      PreviewScreen(url: url!, titulo: tituloVisor),
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.all(6),
            constraints: const BoxConstraints(),
            icon: Icon(
              tieneArchivo ? Icons.file_upload_outlined : Icons.upload_file,
              color: tieneArchivo ? AppColors.info : AppColors.textTertiary,
              size: 22,
            ),
            tooltip:
                tieneArchivo ? 'Reemplazar archivo' : 'Subir archivo',
            onPressed: onTapFile,
          ),
        ],
      ),
    );
  }
}

class _BotonGuardar extends StatelessWidget {
  final bool guardando;
  final VoidCallback onPressed;

  const _BotonGuardar({
    required this.guardando,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AppButton(
      label: guardando ? 'Guardando...' : 'Guardar cambios',
      icon: Icons.save,
      onPressed: guardando ? null : onPressed,
      isLoading: guardando,
      expand: true,
      size: AppButtonSize.lg,
    );
  }
}

/// Tile compacto para elegir una fecha. Versión simplificada de
/// `_DateTile` (que asocia archivo al vencimiento). Lo usamos para el
/// "último service" donde no hay comprobante asociado — solo fecha.
class _FechaTileSimple extends StatelessWidget {
  final String label;
  final String? fecha;
  final IconData icono;
  final VoidCallback onTap;

  const _FechaTileSimple({
    required this.label,
    required this.fecha,
    required this.icono,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tiene = fecha != null && fecha!.isNotEmpty;
    return AppCard(
      onTap: onTap,
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          Icon(icono, color: AppColors.success),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style:
                      AppType.eyebrow.copyWith(color: AppColors.textTertiary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  tiene
                      ? AppFormatters.formatearFecha(fecha!)
                      : 'Sin cargar',
                  style: AppType.heading.copyWith(
                    color: tiene ? AppColors.textPrimary : AppColors.textHint,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.edit_calendar,
              color: AppColors.textHint, size: 18),
        ],
      ),
    );
  }
}
