import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/services/excluidos_service.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/icm_oficial_service.dart';

/// Ranking de choferes según el ICM **oficial de Sitrack** (lo que audita
/// YPF). Escala MÁS BAJO = MEJOR. Se ordena PEOR arriba (ICM más alto)
/// para que el admin aborde primero a los de mayor riesgo; los "sin
/// actividad" quedan grises al final. Click en una fila → detalle.
///
/// Reemplaza el ranking CESVI estimado (que daba números optimistas que no
/// coincidían con el tablero de YPF). Período mensual: mes actual / anterior.
class IcmRankingScreen extends StatefulWidget {
  const IcmRankingScreen({super.key});

  @override
  State<IcmRankingScreen> createState() => _IcmRankingScreenState();
}

enum _Periodo { mesActual, mesAnterior }

class _IcmRankingScreenState extends State<IcmRankingScreen> {
  _Periodo _periodo = _Periodo.mesActual;
  Future<IcmOficialPeriodo?>? _future;

  @override
  void initState() {
    super.initState();
    _recargar();
  }

  void _recargar() {
    _future = _cargar(_periodo);
  }

  String _periodoId(_Periodo p) =>
      IcmOficialService.periodoId(offsetMeses: p == _Periodo.mesActual ? 0 : -1);

  Future<IcmOficialPeriodo?> _cargar(_Periodo p) async {
    final db = FirebaseFirestore.instance;
    final excluidos = await ExcluidosService.cargar(db: db);
    return IcmOficialService.cargarPeriodo(
      db,
      _periodoId(p),
      // Sacamos tanqueros + testers del ranking visible (mismo criterio
      // que el resto de la app). Los totales de cabecera quedan tal cual
      // los reporta Sitrack porque ESE es el número auditado.
      excluirDni: (dni) => ExcluidosService.esExcluido(excluidos, dni: dni),
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
                    color: Colors.redAccent,
                  );
                }
                final periodo = snap.data;
                if (periodo == null || periodo.vacio) {
                  return _MensajeCentro(
                    'Aún no hay datos del ICM oficial de '
                    '${IcmOficialService.labelPeriodo(_periodoId(_periodo))}.\n\n'
                    'Se sincroniza una vez al día desde el portal de Sitrack. '
                    'Si recién arranca el mes, esperá a la próxima madrugada.',
                    color: Colors.white54,
                  );
                }
                final filas = periodo.choferesParaRanking;
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                  itemCount: filas.length + 1,
                  itemBuilder: (ctx, i) {
                    if (i == 0) return _HeaderFlota(periodo: periodo);
                    final c = filas[i - 1];
                    return _FilaChofer(posicion: i, chofer: c);
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
  const _HeaderFlota({required this.periodo});

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
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        IcmOficialService.labelPeriodo(periodo.periodo),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${periodo.choferesActivos} choferes con actividad · '
                        '${AppFormatters.formatearMiles(periodo.distanciaTotalKm)} km',
                        textAlign: TextAlign.end,
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _ChipSeveridad(
                    label: 'Alto', n: altos, color: Colors.red.shade600),
                const SizedBox(width: 6),
                _ChipSeveridad(
                    label: 'Medio', n: medios, color: Colors.amber.shade700),
                const SizedBox(width: 6),
                _ChipSeveridad(
                    label: 'Bajo/Sin', n: bajos, color: Colors.green.shade600),
                const Spacer(),
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
  final int posicion;
  final IcmOficialChofer chofer;

  const _FilaChofer({required this.posicion, required this.chofer});

  @override
  Widget build(BuildContext context) {
    final color = colorSeveridadIcm(chofer.severidad);
    final esNavegable = chofer.tieneDni && !chofer.sinActividad;
    final icmStr =
        chofer.sinActividad ? '—' : chofer.icm.toStringAsFixed(1);
    final dniStr = chofer.tieneDni
        ? 'DNI ${AppFormatters.formatearDNI(chofer.dni)}'
        : 'Sin chofer identificado';
    return Card(
      elevation: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withValues(alpha: 0.40), width: 1),
      ),
      child: ListTile(
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        leading: SizedBox(
          width: 58,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '#$posicion',
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
