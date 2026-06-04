import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/prefs_service.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../constants/posiciones.dart';
import '../models/cubierta_modelo.dart';
import '../models/estado_posicion.dart';
import '../models/montaje.dart';
import '../models/nivel_desgaste.dart';
import '../models/stock_movimiento.dart';
import '../services/montajes_service.dart';
import '../widgets/esquema_unidad_v2_view.dart';

/// Pantalla de detalle de una unidad — modelo NUEVO de gomería (rediseño
/// 2026-05-29), REFACTOR NÚCLEO (jun 2026). Muestra cada posición con su
/// semáforo de desgaste (por km vs vida de la marca) y permite montar/retirar
/// en pocos toques. Sin serializar cubiertas: lo que se monta es un modelo+vida
/// del stock por cantidades.
///
/// SOLO PRESENTACIÓN: el `StreamBuilder` de montajes activos, el `FutureBuilder`
/// de km por posición, `construirEstadoUnidad`, y los flujos `_montar` /
/// `_retirar` (con sus services y diálogos de selección) quedan intactos — sólo
/// se reescribió el árbol de widgets a tokens (`context.colors`), bento
/// (`AppCard`), hero number de posiciones con cubierta, semáforo con `AppDot` /
/// `AppBadge` semánticos y el esquema visual envuelto en una superficie Núcleo.
class GomeriaV2UnidadScreen extends StatefulWidget {
  final String unidadId;
  final TipoUnidadCubierta unidadTipo;

  const GomeriaV2UnidadScreen({
    super.key,
    required this.unidadId,
    required this.unidadTipo,
  });

  @override
  State<GomeriaV2UnidadScreen> createState() => _GomeriaV2UnidadScreenState();
}

class _GomeriaV2UnidadScreenState extends State<GomeriaV2UnidadScreen> {
  final _service = MontajesService();

  /// Color semántico del semáforo de desgaste, en tokens del tema.
  Color _colorNivel(NivelDesgaste n, AppColorsExt c) {
    switch (n) {
      case NivelDesgaste.ok:
        return c.success;
      case NivelDesgaste.alerta:
        return c.warning;
      case NivelDesgaste.critico:
        return c.error;
      case NivelDesgaste.sinDatos:
        return c.textMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: widget.unidadId,
      body: StreamBuilder<List<Montaje>>(
        stream: _service.streamMontajesActivosPorUnidad(widget.unidadId),
        builder: (ctx, snap) {
          if (snap.hasError) {
            return AppErrorState(
              title: 'No se pudieron cargar las cubiertas',
              subtitle: snap.error.toString(),
            );
          }
          if (!snap.hasData) {
            return const AppSkeletonList(count: 6, conAvatar: false);
          }
          final montajes = snap.data!;
          return FutureBuilder<Map<String, double?>>(
            future: _service.kmRecorridoPorPosicion(
              unidadId: widget.unidadId,
              unidadTipo: widget.unidadTipo,
              montajesActivos: montajes,
            ),
            builder: (ctx, kmSnap) {
              final kmPorPos = kmSnap.data ?? const <String, double?>{};
              final estados = construirEstadoUnidad(
                unidadTipo: widget.unidadTipo,
                montajesActivos: montajes,
                kmRecorridoPorPosicion: kmPorPos,
              );
              return _contenido(estados, montajes.length);
            },
          );
        },
      ),
    );
  }

  Widget _contenido(List<EstadoPosicion> estados, int ocupadas) {
    final c = context.colors;

    // Agrupar por eje para mostrar ordenado.
    final porEje = <int, List<EstadoPosicion>>{};
    for (final e in estados) {
      porEje.putIfAbsent(e.posicion.eje, () => []).add(e);
    }
    final ejes = porEje.keys.toList()..sort();

    // Conteo del semáforo (para los KPIs at-a-glance).
    var ok = 0, alerta = 0, critico = 0;
    for (final e in estados) {
      switch (e.nivel) {
        case NivelDesgaste.ok:
          ok++;
        case NivelDesgaste.alerta:
          alerta++;
        case NivelDesgaste.critico:
          critico++;
        case NivelDesgaste.sinDatos:
          break;
      }
    }

    final header = _Header(
      tipo: widget.unidadTipo,
      ocupadas: ocupadas,
      total: estados.length,
      ok: ok,
      alerta: alerta,
      critico: critico,
    );

    // Esquema visual: el dibujo de la unidad con cada posición tappeable
    // (semáforo + % de vida). Tocar la rueda dispara el mismo montar/retirar
    // que el tile de la lista.
    final esquema = EsquemaUnidadV2View(
      tipo: widget.unidadTipo,
      estados: estados,
      onTapPosicion: (e) =>
          e.montaje == null ? _montar(e) : _retirar(e, e.montaje!),
    );

    final ayuda = _Leyenda();

    // Tiles de posiciones agrupados por eje (lista de la derecha / abajo).
    final secciones = <Widget>[
      for (final eje in ejes) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(0, AppSpacing.md, 0, AppSpacing.sm),
          child: AppEyebrow('Eje $eje'),
        ),
        for (final e in porEje[eje]!) _tilePosicion(e),
      ],
    ];

    return LayoutBuilder(
      builder: (ctx, cns) {
        // Tablet apaisada: el dibujo queda FIJO a la izquierda y las posiciones
        // scrollean (poco) a la derecha → se elimina el scroll largo vertical.
        if (cns.maxWidth >= 900) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                          AppSpacing.lg, AppSpacing.lg, AppSpacing.sm, 0),
                      child: header,
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(AppSpacing.lg,
                            AppSpacing.md, AppSpacing.sm, AppSpacing.lg),
                        child: _EsquemaCard(child: esquema),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, 0,
                          AppSpacing.sm, AppSpacing.lg),
                      child: ayuda,
                    ),
                  ],
                ),
              ),
              Container(width: 1, color: c.border),
              Expanded(
                flex: 4,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
                  children: secciones,
                ),
              ),
            ],
          );
        }
        // Teléfono / tablet en vertical: una sola columna scrolleable.
        return ListView(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.xxl),
          children: [
            header,
            const SizedBox(height: AppSpacing.mdDense),
            _EsquemaCard(child: esquema),
            const SizedBox(height: AppSpacing.md),
            ayuda,
            ...secciones,
          ],
        );
      },
    );
  }

  Widget _tilePosicion(EstadoPosicion e) {
    final c = context.colors;
    final m = e.montaje;
    final pct = e.porcentajeVida;
    final color = _colorNivel(e.nivel, c);
    final vacia = m == null;

    // Marcador izquierdo: hero number del % de vida (tinta del semáforo) o,
    // si está vacía / sin dato, un ícono tenue.
    final marcador = SizedBox(
      width: 40,
      child: vacia || pct == null
          ? Icon(
              vacia ? Icons.add_circle_outline : Icons.tire_repair_outlined,
              size: 20,
              color: vacia ? c.textMuted : color,
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${pct.round()}',
                  style: AppType.h5.copyWith(color: c.text, height: 1),
                ),
                Text('%', style: AppType.monoSm.copyWith(color: c.textMuted)),
              ],
            ),
    );

    return AppCard(
      tier: 1,
      onTap: () => vacia ? _montar(e) : _retirar(e, m),
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.md),
      child: Row(
        children: [
          marcador,
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        e.posicion.etiqueta,
                        style:
                            AppType.body.copyWith(fontWeight: FontWeight.w600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (vacia)
                      AppBadge(
                        text: 'Vacía',
                        color: c.textMuted,
                        size: AppBadgeSize.sm,
                      )
                    else
                      AppBadge(
                        text: e.nivel.etiqueta,
                        color: color,
                        dot: true,
                        size: AppBadgeSize.sm,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  vacia
                      ? 'Tocá para montar'
                      : '${m.modeloEtiqueta} · ${m.etiquetaVida}',
                  style: AppType.bodySm.copyWith(color: c.textSecondary),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Icon(
            vacia ? Icons.add : Icons.chevron_right,
            size: 18,
            color: c.textMuted,
          ),
        ],
      ),
    );
  }

  // ───────────────────────── MONTAR ─────────────────────────

  Future<void> _montar(EstadoPosicion e) async {
    // Stock disponible + modelos compatibles con el tipo de uso de la posición.
    final stock = await _service.stockActual();
    final modelosSnap = await FirebaseFirestore.instance
        .collection(AppCollections.cubiertasModelos)
        .where('activo', isEqualTo: true)
        .get();
    final modelos = {
      for (final d in modelosSnap.docs) d.id: CubiertaModelo.fromDoc(d),
    };
    // Filtrar stock por tipo de uso de la posición.
    final opciones = stock.where((s) {
      final mod = modelos[s.modeloId];
      return mod != null && mod.tipoUso == e.posicion.tipoUsoRequerido;
    }).toList();

    if (!mounted) return;
    if (opciones.isEmpty) {
      AppFeedback.error(context,
          'No hay stock ${e.posicion.tipoUsoRequerido.etiqueta} disponible para montar.');
      return;
    }

    final elegido = await showModalBottomSheet<StockItem>(
      context: context,
      backgroundColor: context.colors.surface2,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      builder: (sheetCtx) {
        final c = sheetCtx.colors;
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            children: [
              _SheetHeader(
                titulo: 'Montar',
                subtitulo: e.posicion.etiqueta,
              ),
              for (final s in opciones)
                _SheetOpcion(
                  icon: Icons.tire_repair_outlined,
                  titulo: s.modeloEtiqueta,
                  subtitulo: s.etiquetaVida,
                  trailing: Text(
                    '${s.cantidad} en depósito',
                    style: AppType.monoSm.copyWith(color: c.textMuted),
                  ),
                  onTap: () => Navigator.pop(sheetCtx, s),
                ),
            ],
          ),
        );
      },
    );
    if (elegido == null || !mounted) return;

    final mod = modelos[elegido.modeloId]!;
    final kmVida =
        elegido.vida <= 1 ? mod.kmVidaEstimadaNueva : mod.kmVidaEstimadaRecapada;
    try {
      await _service.montar(
        unidadId: widget.unidadId,
        unidadTipo: widget.unidadTipo,
        posicion: e.posicion.codigo,
        modeloId: elegido.modeloId,
        modeloEtiqueta: elegido.modeloEtiqueta,
        tipoUso: mod.tipoUso,
        vida: elegido.vida,
        kmVidaEstimada: kmVida,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) AppFeedback.success(context, 'Cubierta montada.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }

  // ───────────────────────── RETIRAR ─────────────────────────

  Future<void> _retirar(EstadoPosicion e, Montaje m) async {
    var motivo = MotivoRetiro.desgaste;
    var destino = DestinoRetiro.deposito;

    final confirmar = await showDialog<bool>(
      context: context,
      builder: (dCtx) {
        final c = dCtx.colors;
        return StatefulBuilder(
          builder: (ctx, setSt) => AlertDialog(
            backgroundColor: c.surface2,
            title: Text('Retirar de ${e.posicion.etiqueta}',
                maxLines: 2, overflow: TextOverflow.ellipsis),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Motivo',
                    style: AppType.label.copyWith(color: c.textSecondary)),
                DropdownButton<MotivoRetiro>(
                  isExpanded: true,
                  value: motivo,
                  items: [
                    for (final mo in MotivoRetiro.values)
                      DropdownMenuItem(value: mo, child: Text(mo.etiqueta)),
                  ],
                  onChanged: (v) => setSt(() => motivo = v ?? motivo),
                ),
                const SizedBox(height: AppSpacing.sm),
                Text('Destino',
                    style: AppType.label.copyWith(color: c.textSecondary)),
                DropdownButton<DestinoRetiro>(
                  isExpanded: true,
                  value: destino,
                  items: [
                    for (final d in DestinoRetiro.values)
                      DropdownMenuItem(value: d, child: Text(d.etiqueta)),
                  ],
                  onChanged: (v) => setSt(() => destino = v ?? destino),
                ),
              ],
            ),
            actions: [
              AppButton.ghost(
                  label: 'Cancelar',
                  onPressed: () => Navigator.pop(ctx, false)),
              AppButton.danger(
                  label: 'Retirar',
                  onPressed: () => Navigator.pop(ctx, true)),
            ],
          ),
        );
      },
    );
    if (confirmar != true || !mounted) return;

    try {
      // Km de cierre REAL desde el servicio (odómetro KM_ACTUAL del tractor /
      // cálculo robusto del enganche), no reconstruido del % mostrado. Así se
      // persiste `km_unidad_al_retirar` y un `km_recorridos` exacto para el
      // reporte costo/km.
      final cierre = await _service.kmCierreRetiro(m);
      if (!mounted) return;
      await _service.retirar(
        montajeId: m.id,
        motivo: motivo,
        destino: destino,
        kmUnidadAlRetirar: cierre.kmUnidadAlRetirar,
        kmRecorridos: cierre.kmRecorridos,
        supervisorDni: PrefsService.dni,
        supervisorNombre: PrefsService.nombre,
      );
      if (mounted) AppFeedback.success(context, 'Cubierta retirada.');
    } catch (err) {
      if (mounted) AppFeedback.error(context, err.toString());
    }
  }
}

// =============================================================================
// HEADER — eyebrow tipo de unidad + ocupación + KPIs del semáforo.
// =============================================================================

class _Header extends StatelessWidget {
  final TipoUnidadCubierta tipo;
  final int ocupadas;
  final int total;
  final int ok;
  final int alerta;
  final int critico;

  const _Header({
    required this.tipo,
    required this.ocupadas,
    required this.total,
    required this.ok,
    required this.alerta,
    required this.critico,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final esTractor = tipo == TipoUnidadCubierta.tractor;
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                esTractor
                    ? Icons.local_shipping_outlined
                    : Icons.rv_hookup_outlined,
                size: 16,
                color: c.textMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
              AppEyebrow(esTractor ? 'Tractor' : 'Enganche'),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$ocupadas',
                style: AppType.h2.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'de $total posiciones con cubierta',
                  style: AppType.monoSm,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          AppKpiStrip(
            stats: [
              AppStat(label: 'OK', value: '$ok', accent: c.success),
              AppStat(label: 'Cerca', value: '$alerta', accent: c.warning),
              AppStat(label: 'Pasadas', value: '$critico', accent: c.error),
            ],
          ),
        ],
      ),
    );
  }
}

/// Superficie bento que contiene el esquema visual de la unidad.
class _EsquemaCard extends StatelessWidget {
  final Widget child;
  const _EsquemaCard({required this.child});

  @override
  Widget build(BuildContext context) {
    return AppCard(
      tier: 2,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: child,
    );
  }
}

/// Leyenda del semáforo de desgaste + cómo interactuar — en tokens.
class _Leyenda extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget item(Color color, String txt) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppDot(color, size: 6),
            const SizedBox(width: 5),
            Text(txt, style: AppType.monoSm.copyWith(color: c.textMuted)),
          ],
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Tocá una rueda del dibujo (o un ítem de la lista) para montar o '
          'retirar.',
          style: AppType.bodySm.copyWith(color: c.textMuted),
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.md,
          runSpacing: 6,
          children: [
            item(c.success, 'OK'),
            item(c.warning, 'Cerca del límite'),
            item(c.error, 'Pasada'),
            item(c.textMuted, 'Sin datos'),
          ],
        ),
      ],
    );
  }
}

// =============================================================================
// PRIMITIVAS de bottom sheet (Núcleo) — header + opción tappeable.
// =============================================================================

class _SheetHeader extends StatelessWidget {
  final String titulo;
  final String? subtitulo;
  const _SheetHeader({required this.titulo, this.subtitulo});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg, AppSpacing.lg, AppSpacing.lg, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppEyebrow(titulo),
          if (subtitulo != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitulo!,
              style: AppType.h5,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          AppHairline(color: c.border),
        ],
      ),
    );
  }
}

class _SheetOpcion extends StatelessWidget {
  final IconData icon;
  final String titulo;
  final String? subtitulo;
  final Widget? trailing;
  final VoidCallback onTap;

  const _SheetOpcion({
    required this.icon,
    required this.titulo,
    this.subtitulo,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 20, color: c.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    titulo,
                    style: AppType.body.copyWith(
                        color: c.text, fontWeight: FontWeight.w500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (subtitulo != null)
                    Text(
                      subtitulo!,
                      style: AppType.monoSm.copyWith(color: c.textMuted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AppSpacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}
