// lib/features/logistica/screens/logistica_tarifas_screen.dart
//
// REFACTOR NÚCLEO · jun 2026 — lista de tarifas en lenguaje bento.
//
// SOLO PRESENTACIÓN. Se preserva intacto:
//   - los dos streams (`LogisticaService.streamUbicaciones` para resolver
//     coords + `LogisticaService.streamTarifas(activa:)`),
//   - el filtro token-based (`_aplicarFiltro`), el toggle `_verActivas`
//     (Activas ↔ Inactivas),
//   - la distancia geodésica/OSRM por card (`_DistanciaTexto`),
//   - la eliminación con su diálogo + `LogisticaService.eliminarTarifa`
//     (que chequea viajes en curso y devuelve StateError accionable),
//   - la navegación al form (alta / edición por `tarifaId`),
//   - los atajos de teclado (`KeyboardShortcutsScope`).
//
// Layout Núcleo: hero (eyebrow TARIFAS + conteo), buscador Núcleo (AppInput),
// chip toggle Activas/Inactivas, y cards re-skineadas a tokens: tipo +
// flete (badges), ruta origen → destino, y los 3 montos (real / chofer /
// bruto) en mono dentro de un strip con hairlines. Plata en c.text + mono;
// color semántico solo en dots/badges.
//
// Reglas duras: tokens (context.colors), faltante → "—", sin overflow.

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../../../shared/widgets/keyboard_shortcuts.dart';
import '../models/tarifa_logistica.dart';
import '../models/ubicacion_logistica.dart';
import '../services/logistica_geo_utils.dart';
import '../services/logistica_service.dart';

/// Lista de tarifas con buscador. Cada tarifa = una "ruta con precio"
/// que el módulo de viajes selecciona como base.
class LogisticaTarifasScreen extends StatefulWidget {
  const LogisticaTarifasScreen({super.key});

  @override
  State<LogisticaTarifasScreen> createState() => _LogisticaTarifasScreenState();
}

class _LogisticaTarifasScreenState extends State<LogisticaTarifasScreen> {
  String _filtro = '';
  bool _verActivas = true;
  final FocusNode _buscarFocus = FocusNode();
  late final TextEditingController _buscarCtrl;

  @override
  void initState() {
    super.initState();
    _buscarCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _buscarCtrl.dispose();
    _buscarFocus.dispose();
    super.dispose();
  }

  void _abrirNueva() {
    Navigator.pushNamed(context, AppRoutes.adminLogisticaTarifaForm);
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Tarifas',
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.brand,
        foregroundColor: AppColors.surface0,
        onPressed: _abrirNueva,
        icon: const Icon(Icons.add),
        label: const Text('NUEVA TARIFA'),
      ),
      body: KeyboardShortcutsScope(
        onNuevo: _abrirNueva,
        buscarFocusNode: _buscarFocus,
        // Stream externo: catálogo de ubicaciones. El interno (tarifas) lo
        // combina por id para mostrar distancia geodésica en la card cuando
        // ambas ubicaciones tienen coords. Ubicaciones cambian poco.
        child: StreamBuilder<List<UbicacionLogistica>>(
          stream: LogisticaService.streamUbicaciones(),
          builder: (ctx, ubicSnap) {
            final ubicacionesPorId = {
              for (final u in (ubicSnap.data ?? const <UbicacionLogistica>[]))
                u.id: u,
            };
            return StreamBuilder<List<TarifaLogistica>>(
              stream: LogisticaService.streamTarifas(
                activa: _verActivas,
              ),
              builder: (ctx, snap) {
                final cargando =
                    snap.connectionState == ConnectionState.waiting;
                final all = snap.data ?? const <TarifaLogistica>[];
                final filtradas = _aplicarFiltro(all, _filtro);
                return Column(
                  children: [
                    _Header(total: all.length),
                    _BarraFiltros(
                      controller: _buscarCtrl,
                      buscarFocus: _buscarFocus,
                      tieneTexto: _filtro.isNotEmpty,
                      verActivas: _verActivas,
                      onCambioFiltro: (v) => setState(() => _filtro = v.trim()),
                      onLimpiar: () {
                        _buscarCtrl.clear();
                        setState(() => _filtro = '');
                      },
                      onToggleActivas: () =>
                          setState(() => _verActivas = !_verActivas),
                    ),
                    Expanded(
                      child: _Cuerpo(
                        cargando: cargando,
                        error: snap.hasError ? snap.error : null,
                        haDatos: all.isNotEmpty,
                        verActivas: _verActivas,
                        filtradas: filtradas,
                        ubicacionesPorId: ubicacionesPorId,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Filtro token-based: exige que TODOS los tokens estén presentes en
  /// algún campo de la tarifa. Permite buscar "profertil olavarria" y
  /// matchear una tarifa con origen Profertil y destino Olavarría.
  List<TarifaLogistica> _aplicarFiltro(
    List<TarifaLogistica> tarifas,
    String filtro,
  ) {
    final q = filtro.trim().toLowerCase();
    if (q.isEmpty) return tarifas;
    final tokens = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty);
    return tarifas.where((t) {
      final hay = [
        t.empresaOrigenNombre,
        t.empresaDestinoNombre,
        t.ubicacionOrigenEtiqueta,
        t.ubicacionDestinoEtiqueta,
        t.dadorNombre ?? '',
        t.producto ?? '',
      ].join(' ').toLowerCase();
      for (final token in tokens) {
        if (!hay.contains(token)) return false;
      }
      return true;
    }).toList();
  }
}

// =============================================================================
// HEADER — eyebrow + hero (conteo) + botón Nueva tarifa
// =============================================================================

class _Header extends StatelessWidget {
  final int total;
  const _Header({required this.total});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Sin botón "Nueva tarifa" en el header (2026-06-11): la acción la da el
    // FAB de abajo + Ctrl+N, igual que la lista de Viajes (evita el doble
    // botón). Header = eyebrow + conteo.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.md, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppEyebrow('Tarifas'),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                total == 0 ? '—' : '$total',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  total == 1 ? 'ruta' : 'rutas',
                  style: AppType.monoSm.copyWith(color: c.textMuted),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// BARRA DE FILTROS — buscador Núcleo + chip "Activas"
// =============================================================================

class _BarraFiltros extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode buscarFocus;
  final bool tieneTexto;
  final bool verActivas;
  final ValueChanged<String> onCambioFiltro;
  final VoidCallback onLimpiar;
  final VoidCallback onToggleActivas;

  const _BarraFiltros({
    required this.controller,
    required this.buscarFocus,
    required this.tieneTexto,
    required this.verActivas,
    required this.onCambioFiltro,
    required this.onLimpiar,
    required this.onToggleActivas,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, AppSpacing.md),
      child: Column(
        children: [
          AppInput(
            controller: controller,
            focusNode: buscarFocus,
            hint: 'Buscar por empresa, ubicación, dador o producto…',
            icon: Icons.search,
            onChanged: onCambioFiltro,
            trailingAction: tieneTexto ? 'Limpiar' : null,
            onTrailingTap: tieneTexto ? onLimpiar : null,
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              _ChipActivas(
                verActivas: verActivas,
                onTap: onToggleActivas,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Toggle de estado Activas ↔ Inactivas. Default "Activas" (verde): muestra
/// las activas. Al tocarlo pasa a "Inactivas" (naranja) y muestra SOLO las
/// dadas de baja. Siempre se ve como chip activo/clickeable — cambia color,
/// ícono y label, no hay estado "apagado".
class _ChipActivas extends StatelessWidget {
  final bool verActivas;
  final VoidCallback onTap;
  const _ChipActivas({required this.verActivas, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = verActivas ? c.success : c.warning;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.full),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: fg.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: fg.withValues(alpha: 0.5)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              verActivas ? Icons.check_circle_outline : Icons.block,
              size: 14,
              color: fg,
            ),
            const SizedBox(width: 6),
            Text(
              verActivas ? 'Activas' : 'Inactivas',
              style: AppType.label.copyWith(
                color: fg,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// CUERPO — loading / error / vacío / lista de cards
// =============================================================================

class _Cuerpo extends StatelessWidget {
  final bool cargando;
  final Object? error;
  final bool haDatos;
  final bool verActivas;
  final List<TarifaLogistica> filtradas;
  final Map<String, UbicacionLogistica> ubicacionesPorId;

  const _Cuerpo({
    required this.cargando,
    required this.error,
    required this.haDatos,
    required this.verActivas,
    required this.filtradas,
    required this.ubicacionesPorId,
  });

  @override
  Widget build(BuildContext context) {
    if (cargando) {
      return const AppSkeletonList(count: 6, conAvatar: false);
    }
    if (error != null) {
      return AppErrorState(
        title: 'Error cargando la lista',
        subtitle: '$error',
      );
    }
    if (filtradas.isEmpty) {
      // haDatos = hay tarifas en el estado elegido. Con datos pero filtradas
      // vacío = el buscador no matcheó. Sin datos = depende del modo.
      final String title;
      final String subtitle;
      if (haDatos) {
        title = 'Sin coincidencias';
        subtitle = 'Probá con otro texto o limpiá el filtro.';
      } else if (!verActivas) {
        title = 'No hay tarifas inactivas';
        subtitle = 'Las tarifas que des de baja aparecen acá.';
      } else {
        title = 'Sin tarifas cargadas';
        subtitle = 'Tocá NUEVA TARIFA para armar la primera.';
      }
      return AppEmptyState(
        icon: Icons.price_change_outlined,
        title: title,
        subtitle: subtitle,
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.xs, AppSpacing.lg, 90),
      itemCount: filtradas.length,
      itemBuilder: (_, i) => _CardTarifa(
        tarifa: filtradas[i],
        ubicacionesPorId: ubicacionesPorId,
      ),
    );
  }
}

// =============================================================================
// CARD DE TARIFA
// =============================================================================

class _CardTarifa extends StatelessWidget {
  final TarifaLogistica tarifa;
  final Map<String, UbicacionLogistica> ubicacionesPorId;
  const _CardTarifa({
    required this.tarifa,
    this.ubicacionesPorId = const {},
  });

  /// Par de coords origen-destino si las dos ubicaciones tienen lat/lng
  /// cargadas; null si falta alguna.
  ({LatLng origen, LatLng destino})? get _ods {
    final o = ubicacionesPorId[tarifa.ubicacionOrigenId];
    final d = ubicacionesPorId[tarifa.ubicacionDestinoId];
    if (o?.lat == null || o?.lng == null) return null;
    if (d?.lat == null || d?.lng == null) return null;
    return (
      origen: LatLng(o!.lat!, o.lng!),
      destino: LatLng(d!.lat!, d.lng!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esTerceros = tarifa.tipoCarga == TipoCargaLogistica.terceros;
    final accent =
        tarifa.activa ? (esTerceros ? c.warning : c.brand) : c.textMuted;

    return AppCard(
      tier: 1,
      accent: accent,
      onTap: () => Navigator.pushNamed(
        context,
        AppRoutes.adminLogisticaTarifaForm,
        arguments: {'tarifaId': tarifa.id},
      ),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Línea 1: tipo + flete + (inactiva) + eliminar.
          Row(
            children: [
              Icon(
                esTerceros
                    ? Icons.handshake_outlined
                    : Icons.local_shipping_outlined,
                color: accent,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppBadge(
                text: tarifa.tipoCarga.etiqueta,
                color: esTerceros ? c.warning : c.brand,
                size: AppBadgeSize.sm,
              ),
              const SizedBox(width: 6),
              AppBadge(
                text: tarifa.flete.etiqueta,
                color: c.textSecondary,
                size: AppBadgeSize.sm,
              ),
              const Spacer(),
              if (!tarifa.activa) ...[
                AppBadge(
                  text: 'Inactiva',
                  color: c.textMuted,
                  size: AppBadgeSize.sm,
                ),
                const SizedBox(width: 4),
              ],
              // Eliminar. El service chequea viajes en curso (PLANEADO /
              // EN_CURSO) que usan la tarifa antes de borrar; si hay alguno,
              // muestra mensaje accionable.
              IconButton(
                icon: Icon(Icons.delete_outline, color: c.error, size: 18),
                tooltip: 'Eliminar tarifa',
                onPressed: () => _confirmarEliminar(context),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
            ],
          ),
          if (tarifa.producto != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, color: c.warning, size: 14),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    tarifa.producto!,
                    style: AppType.bodySm.copyWith(
                      color: c.warning,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          // Línea 2: origen → destino.
          _RutaOrigenDestino(tarifa: tarifa, ods: _ods),
          const SizedBox(height: AppSpacing.md),
          // Línea 3: montos (real / chofer / bruto) en mono.
          _TarifasMontos(tarifa: tarifa),
          if (tarifa.dadorNombre != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(Icons.business_outlined, color: c.textMuted, size: 14),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    'Dador: ${tarifa.dadorNombre}'
                    '${tarifa.montoFijoDador != null ? " · \$ ${AppFormatters.formatearMonto(tarifa.montoFijoDador!)}/viaje" : tarifa.porcentajeComisionDador != null ? " · ${tarifa.porcentajeComisionDador!.toStringAsFixed(1)}%" : ""}',
                    style: AppType.monoSm.copyWith(color: c.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmarEliminar(BuildContext context) async {
    final c = context.colors;
    final messenger = ScaffoldMessenger.of(context);
    final ruta =
        '${tarifa.empresaOrigenNombre} → ${tarifa.empresaDestinoNombre}';
    final confirma = await showDialog<bool>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: dCtx.colors.surface2,
        title: const Text('¿Eliminar tarifa?'),
        content: Text(
          '$ruta\n\n'
          'Esta acción no se puede deshacer. Si la tarifa está usada '
          'por algún viaje en curso (PLANEADO o EN CURSO), no se va '
          'a poder borrar. Los viajes históricos no se rompen.',
          style: AppType.body.copyWith(color: c.textSecondary),
        ),
        actions: [
          AppButton.ghost(
            label: 'Cancelar',
            onPressed: () => Navigator.of(dCtx).pop(false),
          ),
          AppButton.danger(
            label: 'Eliminar',
            onPressed: () => Navigator.of(dCtx).pop(true),
          ),
        ],
      ),
    );
    if (confirma != true) return;
    try {
      await LogisticaService.eliminarTarifa(tarifa.id);
      AppFeedback.successOn(messenger, 'Tarifa eliminada.');
    } on StateError catch (e) {
      AppFeedback.errorOn(messenger, e.message);
    } catch (e, s) {
      AppFeedback.errorTecnicoOn(
        messenger,
        usuario: 'No se pudo eliminar la tarifa. Probá de nuevo.',
        tecnico: e,
        stack: s,
      );
    }
  }
}

// =============================================================================
// RUTA ORIGEN → DESTINO
// =============================================================================

class _RutaOrigenDestino extends StatelessWidget {
  final TarifaLogistica tarifa;
  final ({LatLng origen, LatLng destino})? ods;
  const _RutaOrigenDestino({required this.tarifa, this.ods});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Punto(
            etiqueta: 'ORIGEN',
            empresa: tarifa.empresaOrigenNombre,
            // Versión limpia (sin "(localidad)" final) — la localidad anexa
            // es redundante con el nombre que ya viene en la etiqueta cruda.
            ubicacion: tarifa.ubicacionOrigenLimpia,
            color: c.info,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.arrow_forward, color: c.textMuted, size: 16),
              // Km del recorrido. El valor cargado a mano en la tarifa es el
              // autoritativo; si no hay, caemos a la distancia estimada por
              // coordenadas (geodésica/OSRM) cuando ambas ubicaciones tienen
              // lat/lng.
              if (tarifa.km != null) ...[
                const SizedBox(height: 2),
                _KmManualTexto(km: tarifa.km!),
              ] else if (ods != null) ...[
                const SizedBox(height: 2),
                _DistanciaTexto(origen: ods!.origen, destino: ods!.destino),
              ],
            ],
          ),
        ),
        Expanded(
          child: _Punto(
            etiqueta: 'DESTINO',
            empresa: tarifa.empresaDestinoNombre,
            ubicacion: tarifa.ubicacionDestinoLimpia,
            color: c.brandSoft,
          ),
        ),
      ],
    );
  }
}

class _Punto extends StatelessWidget {
  final String etiqueta;
  final String empresa;
  final String ubicacion;
  final Color color;
  const _Punto({
    required this.etiqueta,
    required this.empresa,
    required this.ubicacion,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // La UBICACIÓN va arriba en bold (lo más importante operativamente —
    // define dónde se carga/descarga). La empresa abajo, atenuada.
    final ubic = ubicacion.trim();
    final emp = empresa.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppEyebrow(etiqueta, color: color),
        const SizedBox(height: 2),
        Text(
          ubic.isEmpty ? '—' : ubic,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppType.bodySm.copyWith(
            color: ubic.isEmpty ? c.textMuted : c.text,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          emp.isEmpty ? '—' : emp,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: AppType.monoSm.copyWith(color: c.textMuted),
        ),
      ],
    );
  }
}

// =============================================================================
// MONTOS (real / chofer / bruto) — strip mono con hairlines verticales
// =============================================================================

class _TarifasMontos extends StatelessWidget {
  final TarifaLogistica tarifa;
  const _TarifasMontos({required this.tarifa});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Precio VIGENTE HOY (no el campo plano): con una vigencia futura ya
    // entrada en vigor, el plano puede quedar desfasado hasta el próximo
    // write. `vigenteEn(now)` siempre muestra el precio correcto.
    final v = tarifa.vigenteEn(DateTime.now());
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: c.border),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _MontoBloque(
                etiqueta: 'TARIFA REAL',
                monto: v.tarifaReal,
                sufijo: tarifa.unidadTarifa.sufijoMonto,
                color: c.success,
              ),
            ),
            AppHairline(vertical: true, color: c.border),
            Expanded(
              // Si el chofer cobra un MONTO FIJO (no por unidad), mostrarlo como
              // "CHOFER FIJO $X" en vez de "CHOFER $0 /TN" — que confunde porque
              // parece que el chofer no cobra (reportado 2026-06-04).
              child: (v.montoFijoChofer ?? 0) > 0
                  ? _MontoBloque(
                      etiqueta: 'CHOFER FIJO',
                      monto: v.montoFijoChofer ?? 0,
                      sufijo: '',
                      color: c.info,
                    )
                  : _MontoBloque(
                      etiqueta: 'CHOFER',
                      monto: v.tarifaChofer,
                      sufijo: tarifa.unidadTarifa.sufijoMonto,
                      color: c.info,
                    ),
            ),
            AppHairline(vertical: true, color: c.border),
            Expanded(
              child: _MontoBloque(
                etiqueta: 'BRUTO',
                monto: v.tarifaReal - v.tarifaChofer,
                sufijo: tarifa.unidadTarifa.sufijoMonto,
                color: c.brand,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MontoBloque extends StatelessWidget {
  final String etiqueta;
  final double monto;
  final String sufijo;
  final Color color;
  const _MontoBloque({
    required this.etiqueta,
    required this.monto,
    required this.sufijo,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Dot semántico de color + etiqueta neutra.
          AppEyebrow(etiqueta, color: color),
          const SizedBox(height: 4),
          // FittedBox: en mobile 3 columnas Expanded daban ~110 dp por
          // bloque. "$ 1.234.567,89" no entra a tamaño fijo — scaleDown.
          // Plata en c.text + mono (regla: hero numbers en text, no color).
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              '\$ ${AppFormatters.formatearMonto(monto)}',
              maxLines: 1,
              style: AppType.mono.copyWith(
                color: c.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 1),
          Text(
            sufijo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppType.monoSm.copyWith(fontSize: 9),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// DISTANCIA — geodésica inmediata, refresca a ruta real OSRM cuando llega
// =============================================================================

/// Texto de distancia entre dos puntos. Mientras espera la ruta real de
/// OSRM, muestra la distancia geodésica como fallback inmediato. Cuando
/// vuelve la ruta, refresca con km reales + tiempo estimado. Si OSRM falla
/// (sin red, par fuera del grafo), se queda con la geodésica.
class _DistanciaTexto extends StatelessWidget {
  final LatLng origen;
  final LatLng destino;
  const _DistanciaTexto({required this.origen, required this.destino});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final geodesicaKm = LogisticaGeoUtils.distanciaKm(origen, destino);
    return FutureBuilder<GeoRuta?>(
      future: LogisticaGeoUtils.obtenerRuta(origen, destino),
      builder: (ctx, snap) {
        final ruta = snap.data;
        if (ruta != null) {
          return Column(
            children: [
              Text(
                '${ruta.distanciaKm.toStringAsFixed(0)} km',
                style: AppType.monoSm.copyWith(
                  color: c.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                ruta.duracionFormateada,
                style: AppType.monoSm.copyWith(color: c.textMuted, fontSize: 9),
              ),
            ],
          );
        }
        return Text(
          '${geodesicaKm.toStringAsFixed(0)} km',
          style: AppType.monoSm.copyWith(
            color: c.textMuted,
            fontWeight: FontWeight.w600,
          ),
        );
      },
    );
  }
}

// =============================================================================
// KM MANUAL — distancia del recorrido cargada a mano en la tarifa
// =============================================================================

/// Km del recorrido cargados a mano en la tarifa (autoritativos). Se muestran
/// en lugar de la distancia estimada por coordenadas cuando el operador los
/// cargó. Entero con separador de miles AR (ej. "1.450 km").
class _KmManualTexto extends StatelessWidget {
  final int km;
  const _KmManualTexto({required this.km});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      '${AppFormatters.formatearMiles(km)} km',
      style: AppType.monoSm.copyWith(
        color: c.textSecondary,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}
