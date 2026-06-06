import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/administracion/models/reporte_discrepancia.dart';
import 'package:coopertrans_movil/features/administracion/services/reportes_discrepancia_service.dart';

void main() {
  late FakeFirebaseFirestore fake;
  late ReportesDiscrepanciaService svc;

  setUp(() {
    fake = FakeFirebaseFirestore();
    svc = ReportesDiscrepanciaService(firestore: fake);
  });

  Future<String> sembrar({String estado = 'pendiente', DateTime? creado}) async {
    final ref = await fake.collection('REPORTES_DISCREPANCIA').add({
      'chofer_dni': '1',
      'chofer_nombre': 'PEREZ',
      'tema': 'jornada',
      'detalle': 'salio 6:45 y no figura',
      'estado': estado,
      'creado_en': Timestamp.fromDate(creado ?? DateTime(2026, 6, 6, 10)),
    });
    return ref.id;
  }

  group('ReportesDiscrepanciaService', () {
    test('stream trae los reportes, más nuevos primero', () async {
      await sembrar(creado: DateTime(2026, 6, 5));
      await sembrar(creado: DateTime(2026, 6, 6));
      final lista = await svc.stream().first;
      expect(lista.length, 2);
      expect(lista.first.creadoEn!.day, 6); // desc
    });

    test('marcarRevisado setea estado/veredicto/revisor/nota', () async {
      final id = await sembrar();
      await svc.marcarRevisado(
          id: id,
          veredicto: 'cierto',
          nota: 'era un bug',
          revisorDni: '99',
          revisorNombre: 'ADMIN');
      final d = await fake.collection('REPORTES_DISCREPANCIA').doc(id).get();
      expect(d.data()!['estado'], 'revisado');
      expect(d.data()!['veredicto'], 'cierto');
      expect(d.data()!['nota_revision'], 'era un bug');
      expect(d.data()!['revisado_por_nombre'], 'ADMIN');
    });

    test('marcarRevisado sin nota no escribe nota_revision', () async {
      final id = await sembrar();
      await svc.marcarRevisado(id: id, veredicto: 'no_cierto', revisorDni: '99');
      final d = await fake.collection('REPORTES_DISCREPANCIA').doc(id).get();
      expect(d.data()!.containsKey('nota_revision'), false);
      expect(d.data()!['veredicto'], 'no_cierto');
    });

    test('reabrir vuelve a pendiente y limpia el veredicto', () async {
      final id = await sembrar();
      await svc.marcarRevisado(id: id, veredicto: 'cierto', revisorDni: '99');
      await svc.reabrir(id);
      final d = await fake.collection('REPORTES_DISCREPANCIA').doc(id).get();
      expect(d.data()!['estado'], 'pendiente');
      expect(d.data()!.containsKey('veredicto'), false);
    });
  });

  group('ReporteDiscrepancia (modelo)', () {
    test('pendiente + temaLegible conocido', () {
      final r = ReporteDiscrepancia.fromMap(
          'x', {'tema': 'jornada', 'estado': 'pendiente', 'detalle': 'a'});
      expect(r.pendiente, true);
      expect(r.temaLegible, 'Jornada / horas');
    });

    test('revisado cierto + tema desconocido cae a "Otro"', () {
      final r = ReporteDiscrepancia.fromMap(
          'y', {'tema': 'raro', 'estado': 'revisado', 'veredicto': 'cierto'});
      expect(r.pendiente, false);
      expect(r.esCierto, true);
      expect(r.temaLegible, 'Otro');
    });
  });
}
