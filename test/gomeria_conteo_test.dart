import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/gomeria/models/conteo_gomeria.dart';
import 'package:coopertrans_movil/features/gomeria/models/stock_movimiento.dart';
import 'package:coopertrans_movil/features/gomeria/services/conteos_service.dart';

ConteoGomeria _conteo(List<LineaConteo> l) => ConteoGomeria(
      id: 'x',
      creadoEn: null,
      responsableDni: '1',
      responsableNombre: 'Gomero',
      lineas: l,
    );

LineaConteo _l(String m, int nuevas, int recapadas) =>
    LineaConteo(modeloId: m, modeloEtiqueta: m, nuevas: nuevas, recapadas: recapadas);

StockItem _si(String m, int vida, int cant) =>
    StockItem(modeloId: m, modeloEtiqueta: m, vida: vida, cantidad: cant);

void main() {
  group('compararConteoVsStock', () {
    test('coincide → sin diferencias', () {
      final difs = compararConteoVsStock(
        _conteo([_l('A', 5, 3)]),
        [_si('A', 1, 5), _si('A', 2, 3)],
      );
      expect(difs.length, 1);
      expect(difs.first.hayDiferencia, false);
      expect(difs.first.difNuevas, 0);
      expect(difs.first.difRecapadas, 0);
    });

    test('contó de menos → diferencia negativa (falta)', () {
      final d = compararConteoVsStock(
        _conteo([_l('A', 4, 3)]),
        [_si('A', 1, 5), _si('A', 2, 3)],
      ).first;
      expect(d.difNuevas, -1);
      expect(d.hayDiferencia, true);
    });

    test('contó de más → diferencia positiva (sobra)', () {
      final d = compararConteoVsStock(
        _conteo([_l('A', 7, 3)]),
        [_si('A', 1, 5), _si('A', 2, 3)],
      ).first;
      expect(d.difNuevas, 2);
    });

    test('recapadas agrupan todas las vidas ≥ 2', () {
      final d = compararConteoVsStock(
        _conteo([_l('A', 0, 5)]),
        [_si('A', 2, 3), _si('A', 3, 2)], // 3 + 2 = 5 recapadas
      ).first;
      expect(d.teoricoRecapadas, 5);
      expect(d.difRecapadas, 0);
    });

    test('modelo en stock que no se contó → falta todo', () {
      final d = compararConteoVsStock(_conteo([]), [_si('B', 1, 4)]).first;
      expect(d.modeloId, 'B');
      expect(d.reportadoNuevas, 0);
      expect(d.teoricoNuevas, 4);
      expect(d.difNuevas, -4);
    });

    test('modelo contado que el sistema no tiene → sobra', () {
      final d = compararConteoVsStock(_conteo([_l('C', 2, 0)]), []).first;
      expect(d.difNuevas, 2);
      expect(d.teoricoNuevas, 0);
    });
  });

  group('ConteosService (fake_cloud_firestore)', () {
    late FakeFirebaseFirestore db;
    late ConteosService svc;
    setUp(() {
      db = FakeFirebaseFirestore();
      svc = ConteosService(db: db);
    });

    test('crearConteo filtra líneas vacías y guarda el total', () async {
      await svc.crearConteo(
        lineas: [_l('A', 3, 0), _l('B', 0, 0)], // B es vacía
        responsableDni: '9',
        responsableNombre: 'Gomero',
      );
      final snap = await db.collection('GOMERIA_CONTEOS').get();
      expect(snap.size, 1);
      final d = snap.docs.first.data();
      expect((d['lineas'] as List).length, 1); // la vacía no se guardó
      expect(d['total_contado'], 3);
      expect(d['revisado'], false);
    });

    test('streamConteos trae los conteos', () async {
      await svc.crearConteo(
          lineas: [_l('A', 1, 0)], responsableDni: '9', responsableNombre: 'G');
      final lista = await svc.streamConteos().first;
      expect(lista.length, 1);
      expect(lista.first.totalContado, 1);
    });

    test('marcarRevisado deja constancia (no toca stock)', () async {
      final id = await svc.crearConteo(
          lineas: [_l('A', 1, 0)], responsableDni: '9', responsableNombre: 'G');
      await svc.marcarRevisado(id, '1');
      final d = (await db.collection('GOMERIA_CONTEOS').doc(id).get()).data()!;
      expect(d['revisado'], true);
      expect(d['revisado_por_dni'], '1');
    });
  });
}
