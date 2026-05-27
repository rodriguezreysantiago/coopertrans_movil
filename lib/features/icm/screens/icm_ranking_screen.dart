import 'package:coopertrans_movil/shared/constants/app_colors.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/choferes_service.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

import 'package:coopertrans_movil/core/theme/app_spacing.dart';
/// Ranking de choferes según el ICM **oficial de Sitrack** (lo que audita
/// YPF). Escala MÁS BAJO = MEJOR. Se ordena MEJOR arriba (#1 = mejor
/// chofer del período, gamification estilo podio). Los "sin actividad"
/// quedan grises al final. Búsqueda client-side por nombre o DNI.
///
/// Reemplaza el ranking CESVI estimado (que daba números optimistas que no
/// coincidían con el tablero de YPF). Período mensual: mes actual / anterior.
class IcmRankingScreen extends StatefulWidget {
  const IcmRankingScreen({super.key});

  @override
  State<IcmRankingScreen> createState() => _IcmRankingScreenState();
}

enum _Periodo { semanaActual, mesActual, mesAnterior }

class _IcmRankingScreenState extends State<IcmRankingScreen> {
  _Periodo _periodo = _Periodo.mesActual;
  Future<IcmOficialPeriodo?>? _future;
  final TextEditingController _busqueda = TextEditingController();
  // El filtro normalizado se cachea para no recomputar lower+trim por cada
  // chofer en cada keystroke.
  String _filtroNorm = '';

  @override
  void initState() {
    super.initState();
    _recargar();
    _busqueda.addListener(() {
      setState(() => _filtroNorm = _normalizar(_busqueda.text));
    });
  }

  @override
  void dispose() {
    _busqueda.dispose();
    super.dispose();
  }

  void _recargar() {
    _future = _cargar(_periodo);
  }

  /// Normaliza un string para búsqueda case-insensitive y tolerante a
  /// acentos: "Pérez" → "perez". Sin paquete extra (App. no usa unorm).
  static String _normalizar(String s) {
    const con = 'áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ';
    const sin = 'aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC';
    var out = s.toLowerCase().trim();
    for (var i = 0; i < con.length; i++) {
      out = out.replaceAll(con[i], sin[i]);
    }
    return out;
  }

  /// (id del doc, colección Firestore, label legible) según el período.
  ({String id, String coleccion, String label}) _ref(_Periodo p) {
    switch (p) {
      case _Periodo.semanaActual:
        final id = IcmOficialService.semanaId();
        return (
          id: id,
          coleccion: IcmOficialService.coleccionSemanal,
          label: IcmOficialService.labelSemana(id),
        );
      case _Periodo.mesActual:
        final id = IcmOficialService.periodoId();
        return (
          id: id,
          coleccion: IcmOficialService.coleccion,
          label: IcmOficialService.labelPeriodo(id),
        );
      case _Periodo.mesAnterior:
        final id = IcmOficialService.periodoId(offsetMeses: -1);
        return (
          id: id,
          coleccion: IcmOficialService.coleccion,
          label: IcmOficialService.labelPeriodo(id),
        );
    }
  }

  Future<IcmOficialPeriodo?> _cargar(_Periodo p) async {
    final db = FirebaseFirestore.instance;
    final excluidos = await ExcluidosService.cargar(db: db);
    final dnisChofer = await ChoferesService.cargarDnisChofer(db: db);
    final r = _ref(p);
    return IcmOficialService.cargarPeriodo(
      db,
      r.id,
      coleccionFirestore: r.coleccion,
      // Excluye: (a) tanqueros + testers (ExcluidosService) y (b) DNIs con
      // ROL distinto de CHOFER en EMPLEADOS (Santiago 2026-05-23: PLANTA /
      // ADMIN / etc. no deben aparecer en el ranking ICM). Los totales de
      // cabecera quedan tal cual los reporta Sitrack porque ESE es el
      // número auditado por YPF.
      // Si dnisChofer es null (query falló), NO filtramos por rol —
      // fail-safe: mejor mostrar uno indebido 100ms que vaciar el ranking.
      excluirDni: (dni) =>
          ExcluidosService.esExcluido(excluidos, dni: dni) ||
          (dnisChofer != null && !dnisChofer.contains(dni)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Ranking ICM',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _BarraFiltros(
            periodoActual: _periodo,
            onChanged: (p) => setState(() {
              _periodo = p;
              _recargar();
            }),
          ),
          _Buscador(controller: _busqueda),
          Expanded(
            child: FutureBuilder<IcmOficialPeriodo?>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return _MensajeCentro(
                    'Error cargando el ranking: ${snap.error}',
                    color: AppColors.error,
                  );
                }
                final periodo = snap.data;
                if (periodo == null || periodo.vacio) {
                  return _MensajeCentro(
                    'Aún no hay datos del ICM oficial de '
                    '${_ref(_periodo).label}.\n\n'
                    'Se sincroniza una vez al día desde el portal de Sitrack. '
                    'Si recién arranca el período, esperá a la próxima '
                    'madrugada.',
                    color: Colors.white54,
                  );
                }
                // ORDEN: mejor arriba (#1 = mejor chofer del período).
                // Los sin actividad/DNI quedan al final (no compiten).
                final orden = periodo.choferesParaRanking;
                // Posición numerada: solo cuenta a los rankeables (con
                // actividad y DNI). Los grises de abajo van sin posición
                // para no confundir "está en el puesto N" con "no compite".
                final rankeables = periodo.choferesConActividad.length;
                // Filtro por nombre o DNI (normalizado: case-insensitive +
                // sin acentos). Aplicado después del orden para no romper
                // la posición numerada.
                final filas = _filtroNorm.isEmpty
                    ? orden
                    : orden
                        .where((c) =>
                            _normalizar(c.nombre).contains(_filtroNorm) ||
                            c.dni.contains(_filtroNorm))
                        .toList();
                final label = _ref(_periodo).label;
                if (filas.isEmpty) {
                  return Column(
                    children: [
                      _HeaderFlota(periodo: periodo, label: label),
                      _MensajeCentro(
                        'Sin coincidencias para "${_busqueda.text}".',
                        color: Colors.white54,
                      ),
                    ],
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: filas.length + 1,
                  itemBuilder: (ctx, i) {
                    if (i == 0) {
                      return _HeaderFlota(periodo: periodo, label: label);
                    }
                    final c = filas[i - 1];
                    // Posición = índice en el orden ORIGINAL (no en el
                    // filtrado), para que filtrar no cambie el #N de un
                    // chofer. Los sin actividad/DNI van sin posición.
                    final esRankeable =
                        !c.sinActividad && c.tieneDni;
                    final posicion = esRankeable ? orden.indexOf(c) + 1 : null;
                    return _FilaChofer(
                      posicion: posicion,
                      totalRankeables: rankeables,
                      chofer: c,
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Buscador extends StatelessWidget {
  final TextEditingController controller;
  const _Buscador({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Buscar por nombre o DNI',
          hintStyle:
              const TextStyle(color: Colors.white38, fontSize: 13),
          prefixIcon: const Icon(Icons.search,
              color: Colors.white54, size: 20),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close,
                      color: Colors.white54, size: 18),
                  splashRadius: 18,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.clear,
                ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide:
                const BorderSide(color: Colors.white24, width: 1),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            borderSide:
                const BorderSide(color: Colors.white24, width: 1),
          ),
        ),
      ),
    );
  }
}

class _MensajeCentro extends StatelessWidget {
  final String texto;
  final Color color;
  const _MensajeCentro(this.texto, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          texto,
          textAlign: TextAlign.center,
          style: TextStyle(color: color, fontSize: 14, height: 1.4),
        ),
      ),
    );
  }
}

class _BarraFiltros extends StatelessWidget {
  final _Periodo periodoActual;
  final ValueChanged<_Periodo> onChanged;

  const _BarraFiltros({required this.periodoActual, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Wrap(
        spacing: 8,
        children: [
          ChoiceChip(
            label: const Text('Semana actual'),
            selected: periodoActual == _Periodo.semanaActual,
            onSelected: (_) => onChanged(_Periodo.semanaActual),
          ),
          ChoiceChip(
            label: const Text('Mes actual'),
            selected: periodoActual == _Periodo.mesActual,
            onSelected: (_) => onChanged(_Periodo.mesActual),
          ),
          ChoiceChip(
            label: const Text('Mes anterior'),
            selected: periodoActual == _Periodo.mesAnterior,
            onSelected: (_) => onChanged(_Periodo.mesAnterior),
          ),
        ],
      ),
    );
  }
}

/// Cabecera con el ICM de la flota (oficial) + cómo leerlo + distribución.
class _HeaderFlota extends StatelessWidget {
  final IcmOficialPeriodo periodo;
  final String label;
  const _HeaderFlota({required this.periodo, required this.label});

  @override
  Widget build(BuildContext context) {
    final conteo = periodo.conteoPorSeveridad;
    final altos = conteo[SeveridadIcm.alto] ?? 0;
    final medios = conteo[SeveridadIcm.medio] ?? 0;
    final bajos = (conteo[SeveridadIcm.bajo] ?? 0) +
        (conteo[SeveridadIcm.sinInfracciones] ?? 0);
    return AppCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      periodo.icmGeneral.toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 30,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    const Text(
                      'ICM flota (oficial Sitrack)',
                      style: TextStyle(color: Colors.white60, fontSize: 11),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        label,
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${periodo.choferesConActividad.length} choferes '
                        'rankeables · '
                        '${AppFormatters.formatearMiles(periodo.distanciaTotalKm)} km',
                        textAlign: TextAlign.end,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _ChipSeveridad(
                    label: 'Alto', n: altos, color: Colors.red.shade600),
                _ChipSeveridad(
                    label: 'Medio', n: medios, color: Colors.amber.shade700),
                _ChipSeveridad(
                    label: 'Bajo/Sin', n: bajos, color: Colors.green.shade600),
                const Text(
                  'más bajo = mejor',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChipSeveridad extends StatelessWidget {
  final String label;
  final int n;
  final Color color;
  const _ChipSeveridad(
      {required this.label, required this.n, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$label $n',
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _FilaChofer extends StatelessWidget {
  /// Posición en el ranking (`null` = sin actividad/DNI, no compite).
  final int? posicion;

  /// Cantidad total de choferes rankeables del período (para mostrar
  /// "#3 de 28" — da contexto del podio).
  final int totalRankeables;

  final IcmOficialChofer chofer;

  const _FilaChofer({
    required this.posicion,
    required this.totalRankeables,
    required this.chofer,
  });

  @override
  Widget build(BuildContext context) {
    final color = colorSeveridadIcm(chofer.severidad);
    final icmStr =
        chofer.sinActividad ? '—' : chofer.icm.toStringAsFixed(1);
    final dniStr = chofer.tieneDni
        ? 'DNI ${AppFormatters.formatearDNI(chofer.dni)}'
        : 'Sin chofer identificado';
    final posStr = posicion == null
        ? '—'
        : '#$posicion${totalRankeables > 0 ? '/$totalRankeables' : ''}';
    // Drill-down disponible solo si hay DNI real (Sitrack a veces tiene
    // unidades sin chofer asignado, esos no entran al detalle).
    final esNavegable = chofer.tieneDni && !chofer.sinActividad;
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        side: BorderSide(color: color.withValues(alpha: 0.40), width: 1),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: SizedBox(
          width: 64,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                posStr,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  icmStr,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),
        title: Text(
          chofer.nombre.isEmpty ? '(sin nombre)' : chofer.nombre,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
              color: Colors.white, fontWeight: FontWeight.w600),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$dniStr · ${AppFormatters.formatearMiles(chofer.distanciaKm)} km',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
              const SizedBox(height: 2),
              Text(
                chofer.sinActividad
                    ? 'Sin actividad en el período'
                    : '${chofer.severidadLabel} · ${chofer.totalInfracciones} '
                        'infracciones (${chofer.infAltas}A · '
                        '${chofer.infMedias}M · ${chofer.infLeves}L)',
                style: TextStyle(color: color, fontSize: 11),
              ),
            ],
          ),
        ),
        trailing: esNavegable
            ? const Icon(Icons.chevron_right, color: Colors.white38)
            : null,
        onTap: esNavegable
            ? () => Navigator.pushNamed(
                  context,
                  AppRoutes.adminIcmDetalleChofer,
                  arguments: chofer.dni,
                )
            : null,
      ),
    );
  }
}
