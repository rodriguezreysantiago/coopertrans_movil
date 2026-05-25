import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../shared/constants/app_colors.dart';
import '../../../shared/utils/app_feedback.dart';
import '../../../shared/utils/formatters.dart';
import '../../../shared/utils/phone_formatter.dart';
import '../../../shared/widgets/app_widgets.dart';
import '../services/whatsapp_historico_service.dart';

/// M8 + M10 — Pantalla "Historial WhatsApp": auditar mensajes pasados
/// del bot (ENVIADO / ERROR) con filtros y buscador.
///
/// COLA_WHATSAPP tiene TTL muy corto (horas) porque su rol es "cola de
/// trabajo". Esto rompía el flujo "¿se mandó el aviso del lunes?" — para
/// el martes ya no había rastro. Esta pantalla resuelve ese caso leyendo
/// WHATSAPP_HISTORICO (TTL 30 días, doc 1:1 con COLA_WHATSAPP cuando
/// llega a estado terminal).
///
/// Server-side: rango fecha + 1 filtro (estado XOR destinatario_id XOR
/// origen) — los compound indexes solo cubren un filtro + registrado_en.
/// Client-side: buscador full-text sobre los resultados (rápido porque
/// la página es 50).
class AdminWhatsappHistoricoScreen extends StatefulWidget {
  /// M6 — filtro inicial por origen, para deep-link "Ver último enviado"
  /// desde la card "Reglas de notificación" del dashboard del bot. Si
  /// es null, abre sin filtro.
  final String? initialOrigen;
  const AdminWhatsappHistoricoScreen({super.key, this.initialOrigen});

  @override
  State<AdminWhatsappHistoricoScreen> createState() =>
      _AdminWhatsappHistoricoScreenState();
}

class _AdminWhatsappHistoricoScreenState
    extends State<AdminWhatsappHistoricoScreen> {
  final _service = WhatsAppHistoricoService();

  /// Rango de fechas a consultar. Default: últimos 7 días.
  late DateTime _desde;
  late DateTime _hasta;

  /// Filtro de estado (null = todos). ENVIADO o ERROR.
  String? _filtroEstado;

  /// Filtro por destinatario DNI (input opcional). Empty = sin filtro.
  final TextEditingController _dniCtrl = TextEditingController();

  /// Filtro por origen (input opcional, ej "vigilador_jornada",
  /// "cron_service_diario"). Empty = sin filtro.
  final TextEditingController _origenCtrl = TextEditingController();

  /// Buscador client-side sobre resultados (tel, mensaje, dni, origen).
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Estado del fetch.
  bool _cargando = false;
  String? _error;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _docs = const [];

  @override
  void initState() {
    super.initState();
    final ahora = DateTime.now();
    _hasta = DateTime(ahora.year, ahora.month, ahora.day, 23, 59, 59);
    _desde =
        DateTime(ahora.year, ahora.month, ahora.day - 6, 0, 0, 0); // 7 días
    // M6 — deep-link desde la card "Reglas de notificación".
    if (widget.initialOrigen != null && widget.initialOrigen!.isNotEmpty) {
      _origenCtrl.text = widget.initialOrigen!;
    }
    _ejecutarConsulta();
  }

  @override
  void dispose() {
    _dniCtrl.dispose();
    _origenCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Cuenta filtros server-side activos (combinables con el rango fecha).
  /// Si > 1 mostramos un warning porque Firestore no soporta 2 igualdades
  /// + range sin compound indexes que no tenemos.
  int get _filtrosServerActivos {
    int n = 0;
    if (_filtroEstado != null) n++;
    if (_dniCtrl.text.trim().isNotEmpty) n++;
    if (_origenCtrl.text.trim().isNotEmpty) n++;
    return n;
  }

  Future<void> _ejecutarConsulta() async {
    setState(() {
      _cargando = true;
      _error = null;
    });
    try {
      final snap = await _service.consultar(
        destinatarioId: _dniCtrl.text.trim().isEmpty
            ? null
            : _dniCtrl.text.trim(),
        origen: _origenCtrl.text.trim().isEmpty
            ? null
            : _origenCtrl.text.trim(),
        estado: _filtroEstado,
        desde: _desde,
        hasta: _hasta,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _docs = snap.docs;
        _cargando = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _cargando = false;
      });
    }
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filtrarPorQuery(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> docs) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return docs;
    return docs.where((doc) {
      final m = doc.data();
      bool contiene(dynamic v) =>
          v != null && v.toString().toLowerCase().contains(q);
      return contiene(m['telefono']) ||
          contiene(m['mensaje']) ||
          contiene(m['origen']) ||
          contiene(m['destinatario_id']) ||
          contiene(m['destinatario_coleccion']) ||
          contiene(m['alert_patente']);
    }).toList();
  }

  Future<void> _elegirRango() async {
    final ahora = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: ahora.subtract(
          const Duration(days: WhatsAppHistoricoService.ttlDias)),
      lastDate: ahora,
      initialDateRange: DateTimeRange(start: _desde, end: _hasta),
    );
    if (picked == null) return;
    setState(() {
      _desde =
          DateTime(picked.start.year, picked.start.month, picked.start.day);
      _hasta = DateTime(
          picked.end.year, picked.end.month, picked.end.day, 23, 59, 59);
    });
    await _ejecutarConsulta();
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Historial WhatsApp',
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _filtrosCard(),
            const SizedBox(height: 8),
            _busquedaInput(),
            const SizedBox(height: 8),
            Expanded(child: _lista()),
          ],
        ),
      ),
    );
  }

  Widget _filtrosCard() {
    final formatRango = '${AppFormatters.formatearFechaCorta(_desde)} → '
        '${AppFormatters.formatearFechaCorta(_hasta)}';
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_today,
                  color: AppColors.accentBlue, size: 16),
              const SizedBox(width: 6),
              Expanded(
                child: InkWell(
                  onTap: _elegirRango,
                  child: Text(
                    formatRango,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: _elegirRango,
                child: const Text('Cambiar'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('Estado:',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
              const SizedBox(width: 8),
              _chipEstado(null, 'Todos'),
              const SizedBox(width: 6),
              _chipEstado('ENVIADO', 'Enviados'),
              const SizedBox(width: 6),
              _chipEstado('ERROR', 'Errores'),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _dniCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'DNI destinatario (opcional)',
                    labelStyle: TextStyle(color: Colors.white60, fontSize: 11),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                  onSubmitted: (_) => _ejecutarConsulta(),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _origenCtrl,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Origen (opcional)',
                    labelStyle: TextStyle(color: Colors.white60, fontSize: 11),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                  ),
                  onSubmitted: (_) => _ejecutarConsulta(),
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.search, color: AppColors.accentBlue),
                tooltip: 'Buscar',
                onPressed: _ejecutarConsulta,
              ),
            ],
          ),
          if (_filtrosServerActivos > 1)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Aviso: combinar estado + DNI + origen puede requerir '
                'un índice extra. Si la consulta tarda mucho o falla, '
                'dejá solo un filtro server-side y refiná con la búsqueda.',
                style: TextStyle(color: AppColors.warning, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chipEstado(String? value, String label) {
    final selected = _filtroEstado == value;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      selected: selected,
      onSelected: (sel) {
        setState(() => _filtroEstado = value);
        _ejecutarConsulta();
      },
      selectedColor: AppColors.accentBlue.withAlpha(80),
      backgroundColor: AppColors.surface,
      labelStyle: TextStyle(
        color: selected ? AppColors.accentBlue : Colors.white70,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  Widget _busquedaInput() {
    return TextField(
      controller: _searchCtrl,
      style: const TextStyle(color: Colors.white, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        prefixIcon:
            const Icon(Icons.search, color: Colors.white54, size: 20),
        suffixIcon: _query.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.clear,
                    color: Colors.white54, size: 18),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _query = '');
                },
              ),
        hintText: 'Buscar dentro de los resultados (texto / teléfono / patente)',
        hintStyle:
            const TextStyle(color: Colors.white38, fontSize: 12),
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  Widget _lista() {
    if (_cargando) return const AppLoadingState();
    if (_error != null) {
      return AppErrorState(subtitle: _error!);
    }
    final filtrados = _filtrarPorQuery(_docs);
    if (filtrados.isEmpty) {
      return AppEmptyState(
        icon: Icons.history_toggle_off,
        title: _query.isNotEmpty
            ? 'Sin coincidencias para "$_query"'
            : 'Sin mensajes en el rango',
        subtitle:
            'Aflojar filtros o ampliar el rango de fechas (máximo 30 días).',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 80),
      itemCount: filtrados.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8, left: 4),
            child: Text(
              '${filtrados.length} mensaje(s)'
              '${_query.isNotEmpty || _filtrosServerActivos > 0 ? " coinciden" : ""}',
              style: const TextStyle(
                color: Colors.white60,
                fontSize: 12,
              ),
            ),
          );
        }
        final doc = filtrados[i - 1];
        return _ItemHistorico(
          doc: doc,
          onTap: () => _mostrarDetalle(context, doc),
        );
      },
    );
  }

  void _mostrarDetalle(
    BuildContext context,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sCtx) => _DetalleHistoricoSheet(doc: doc),
    );
  }
}

class _ItemHistorico extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onTap;
  const _ItemHistorico({required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final m = doc.data();
    final estado = (m['estado'] ?? '').toString();
    final esError = estado == 'ERROR';
    final color = esError ? AppColors.error : AppColors.accentGreen;
    final telefono = (m['telefono'] ?? '').toString();
    final mensaje = (m['mensaje'] ?? '').toString();
    final origen = (m['origen'] ?? '').toString();
    final registradoEn = m['registrado_en'];
    final entregadoEn = m['entregado_en']; // M11
    final leidoEn = m['leido_en']; // M11
    final hora = registradoEn is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(registradoEn.toDate())
        : '';
    final preview = mensaje.length > 100
        ? '${mensaje.substring(0, 100)}…'
        : mensaje;
    return Card(
      color: AppColors.surface,
      margin: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withAlpha(40),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: color.withAlpha(120)),
                    ),
                    child: Text(
                      estado,
                      style: TextStyle(
                        color: color,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // M11 — checkmarks de ack (gris/azul). Solo si NO es
                  // error y el mensaje fue al menos enviado.
                  if (!esError)
                    _AckIcon(
                      entregadoEn: entregadoEn is Timestamp
                          ? entregadoEn.toDate()
                          : null,
                      leidoEn:
                          leidoEn is Timestamp ? leidoEn.toDate() : null,
                    ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      PhoneFormatter.paraMostrar(telefono),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    hora,
                    style: const TextStyle(
                        color: Colors.white60, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                preview,
                style:
                    const TextStyle(color: Colors.white70, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (origen.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  origen,
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _DetalleHistoricoSheet extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _DetalleHistoricoSheet({required this.doc});

  @override
  Widget build(BuildContext context) {
    final m = doc.data();
    final estado = (m['estado'] ?? '').toString();
    final esError = estado == 'ERROR';
    final color = esError ? AppColors.error : AppColors.accentGreen;
    final telefono = (m['telefono'] ?? '').toString();
    final mensaje = (m['mensaje'] ?? '').toString();
    final origen = (m['origen'] ?? '').toString();
    final destinatarioId = (m['destinatario_id'] ?? '').toString();
    final destinatarioColec = (m['destinatario_coleccion'] ?? '').toString();
    final alertPatente = (m['alert_patente'] ?? '').toString();
    final waId = (m['wa_message_id'] ?? '').toString();
    final error = (m['error'] ?? '').toString();
    final registrado = m['registrado_en'];
    final entregado = m['entregado_en']; // M11
    final leido = m['leido_en']; // M11
    final fechaTxt = registrado is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(registrado.toDate())
        : '';
    final entregadoTxt = entregado is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(entregado.toDate())
        : '';
    final leidoTxt = leido is Timestamp
        ? AppFormatters.formatearFechaHoraSinSegundos(leido.toDate())
        : '';

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(
                    esError ? Icons.error_outline : Icons.check_circle_outline,
                    color: color,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    estado,
                    style: TextStyle(
                      color: color,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white60),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _fila('Teléfono', PhoneFormatter.paraMostrar(telefono)),
              _fila('Enviado', fechaTxt),
              if (entregadoTxt.isNotEmpty)
                _fila('Entregado ✓✓', entregadoTxt),
              if (leidoTxt.isNotEmpty)
                _fila('Leído ✓✓ (azul)', leidoTxt),
              if (origen.isNotEmpty) _fila('Origen', origen),
              if (destinatarioId.isNotEmpty)
                _fila('Destinatario', destinatarioId),
              if (destinatarioColec.isNotEmpty)
                _fila('Colección', destinatarioColec),
              if (alertPatente.isNotEmpty) _fila('Patente', alertPatente),
              if (waId.isNotEmpty) _fila('WhatsApp ID', waId),
              const SizedBox(height: 12),
              const Text(
                'Mensaje',
                style: TextStyle(
                  color: Colors.white60,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: Colors.white12),
                ),
                child: SelectableText(
                  mensaje,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 13),
                ),
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Error',
                  style: TextStyle(
                    color: AppColors.error,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.error.withAlpha(30),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: AppColors.error.withAlpha(80)),
                  ),
                  child: SelectableText(
                    error,
                    style: const TextStyle(
                        color: AppColors.error, fontSize: 12),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Center(
                child: TextButton.icon(
                  onPressed: () {
                    final messenger = ScaffoldMessenger.of(context);
                    AppFeedback.successOn(
                      messenger,
                      'Doc ID copiado: ${doc.id}',
                    );
                  },
                  icon: const Icon(Icons.copy, size: 14),
                  label: Text(
                    doc.id,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _fila(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}


/// M11 — Mini-widget con los ✓/✓✓/✓✓-azul al estilo WhatsApp.
/// gris/blanco = solo enviado; gris/blanco con doble = entregado;
/// azul con doble = leído. Solo se renderiza si hay al menos un
/// timestamp; sino devuelve un SizedBox chico para mantener alineado.
class _AckIcon extends StatelessWidget {
  final DateTime? entregadoEn;
  final DateTime? leidoEn;
  const _AckIcon({this.entregadoEn, this.leidoEn});

  @override
  Widget build(BuildContext context) {
    if (entregadoEn == null && leidoEn == null) {
      return const Icon(Icons.check, size: 14, color: Colors.white38);
    }
    final color = leidoEn != null ? AppColors.accentBlue : Colors.white60;
    return Icon(Icons.done_all, size: 14, color: color);
  }
}
