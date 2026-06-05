import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:coopertrans_movil/features/gomeria/constants/posiciones.dart';
import 'package:coopertrans_movil/features/gomeria/models/montaje.dart';
import 'package:coopertrans_movil/features/gomeria/services/montajes_service.dart';

/// Tests del flujo core del `MontajesService` (rediseño gomería 2026-05-29)
/// con `fake_cloud_firestore` (in-memory). Cubre: compra de stock, montaje
/// (con sus validaciones STRICT y el lock de posición sin runTransaction) y
/// retiro (con o sin devolución al stock).
void main() {
  late FakeFirebaseFirestore fake;
  late MontajesService service;

  setUp(() {
    fake = FakeFirebaseFirestore();
    service = MontajesService(firestore: fake);
  });

  Future<void> comprar5() => service.comprar(
        modeloId: 'm1',
        modeloEtiqueta: 'Bridgestone R268 — Tracción',
        cantidad: 5,
        supervisorDni: '1',
      );

  Future<String> montarTrac(String posicion) => service.montar(
        unidadId: 'AB123CD',
        unidadTipo: TipoUnidadCubierta.tractor,
        posicion: posicion,
        modeloId: 'm1',
        modeloEtiqueta: 'Bridgestone R268 — Tracción',
        tipoUso: TipoUsoCubierta.traccion,
        vida: 1,
        kmVidaEstimada: 80000,
        kmUnidadAlMontar: 100000,
        supervisorDni: '1',
      );

  group('comprar + stock', () {
    test('una compra suma al stock', () async {
      await comprar5();
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 5);
      final stock = await service.stockActual();
      expect(stock.length, 1);
      expect(stock.single.cantidad, 5);
    });

    test('cantidad <= 0 lanza MontajeException', () async {
      expect(
        () => service.comprar(
            modeloId: 'm1', modeloEtiqueta: 'x', cantidad: 0, supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });
  });

  group('montar', () {
    test('flujo feliz: descuenta stock, ocupa posición, crea montaje activo',
        () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT');
      expect(id, isNotEmpty);
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 4);
      final activos =
          await service.streamMontajesActivosPorUnidad('AB123CD').first;
      expect(activos.length, 1);
      expect(activos.single.posicion, 'TRAC1_IZQ_EXT');
      expect(activos.single.esActivo, true);
    });

    test('rechaza montar en una posición ya ocupada', () async {
      await comprar5();
      await montarTrac('TRAC1_IZQ_EXT');
      expect(() => montarTrac('TRAC1_IZQ_EXT'),
          throwsA(isA<MontajeException>()));
      // y el stock no se tocó de más (sigue en 4).
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 4);
    });

    test('rechaza tipo de uso incompatible (tracción en posición dirección)',
        () async {
      await comprar5();
      expect(
        () => service.montar(
          unidadId: 'AB123CD',
          unidadTipo: TipoUnidadCubierta.tractor,
          posicion: 'DIR_IZQ', // requiere DIRECCION
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          tipoUso: TipoUsoCubierta.traccion,
          supervisorDni: '1',
        ),
        throwsA(isA<MontajeException>()),
      );
    });

    test('rechaza si no hay stock del SKU', () async {
      // sin comprar
      expect(() => montarTrac('TRAC1_IZQ_EXT'),
          throwsA(isA<MontajeException>()));
    });

    test('rechaza posición de otro tipo de unidad', () async {
      await comprar5();
      expect(
        () => service.montar(
          unidadId: 'AB123CD',
          unidadTipo: TipoUnidadCubierta.tractor,
          posicion: 'ENG1_IZQ_EXT', // posición de enganche
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          tipoUso: TipoUsoCubierta.traccion,
          supervisorDni: '1',
        ),
        throwsA(isA<MontajeException>()),
      );
    });
  });

  group('retirar', () {
    test('a DEPÓSITO: cierra montaje, libera posición y devuelve stock',
        () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT'); // stock 4
      await service.retirar(
        montajeId: id,
        motivo: MotivoRetiro.desgaste,
        destino: DestinoRetiro.deposito,
        kmUnidadAlRetirar: 180000,
        kmRecorridos: 80000,
        supervisorDni: '1',
      );
      // stock vuelve a 5.
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 5);
      // posición libre: no hay montajes activos.
      final activos =
          await service.streamMontajesActivosPorUnidad('AB123CD').first;
      expect(activos, isEmpty);
      // y puedo volver a montar en esa posición sin error.
      final id2 = await montarTrac('TRAC1_IZQ_EXT');
      expect(id2, isNotEmpty);
    });

    test('a DESCARTE: cierra montaje pero NO devuelve stock', () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT'); // stock 4
      await service.retirar(
        montajeId: id,
        motivo: MotivoRetiro.pinchazo,
        destino: DestinoRetiro.descarte,
        supervisorDni: '1',
      );
      // el descarte no vuelve al depósito → sigue en 4.
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 4);
    });

    test('retirar un montaje ya retirado lanza', () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT');
      await service.retirar(
          montajeId: id,
          motivo: MotivoRetiro.desgaste,
          destino: DestinoRetiro.deposito,
          supervisorDni: '1');
      expect(
        () => service.retirar(
            montajeId: id,
            motivo: MotivoRetiro.desgaste,
            destino: DestinoRetiro.deposito,
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });

    test('retirar un montaje inexistente lanza', () async {
      expect(
        () => service.retirar(
            montajeId: 'nope',
            motivo: MotivoRetiro.desgaste,
            destino: DestinoRetiro.deposito,
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });
  });

  group('rotar', () {
    // Stock de arrastre vida 2 (recapada) para los tests de la regla de vida.
    Future<void> stockRecapArrastre() async {
      await service.comprar(
          modeloId: 'arr',
          modeloEtiqueta: 'X arrastre',
          cantidad: 3,
          supervisorDni: '1');
      await service.mandarARecapar(
          modeloId: 'arr',
          modeloEtiqueta: 'X arrastre',
          vida: 1,
          cantidad: 3,
          supervisorDni: '1');
      await service.recibirDeRecapado(
          modeloId: 'arr',
          modeloEtiqueta: 'X arrastre',
          vidaPrevia: 1,
          recibidas: 3,
          supervisorDni: '1');
    }

    Future<String> montarEng(String posicion, {int vida = 1}) => service.montar(
          unidadId: 'ENG999',
          unidadTipo: TipoUnidadCubierta.enganche,
          posicion: posicion,
          modeloId: 'arr',
          modeloEtiqueta: 'X arrastre',
          tipoUso: TipoUsoCubierta.arrastre,
          vida: vida,
          kmVidaEstimada: 60000,
          supervisorDni: '1',
        );

    test('a posición LIBRE: mueve la cubierta y NO toca el stock', () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT'); // stock 4
      await service.rotar(
          montajeId: id, posicionDestino: 'TRAC1_DER_EXT', supervisorDni: '1');
      final activos =
          await service.streamMontajesActivosPorUnidad('AB123CD').first;
      expect(activos.length, 1);
      expect(activos.single.posicion, 'TRAC1_DER_EXT');
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 4);
    });

    test('el km VIAJA: km_unidad_al_montar y desde se conservan', () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT'); // kmAlMontar 100000
      final antes =
          (await service.streamMontajesActivosPorUnidad('AB123CD').first).single;
      await service.rotar(
          montajeId: id, posicionDestino: 'TRAC1_DER_EXT', supervisorDni: '1');
      final despues =
          (await service.streamMontajesActivosPorUnidad('AB123CD').first).single;
      expect(despues.kmUnidadAlMontar, antes.kmUnidadAlMontar);
      expect(despues.desde, antes.desde);
    });

    test('a posición OCUPADA: SWAP de las dos cubiertas', () async {
      await comprar5();
      final idA = await montarTrac('TRAC1_IZQ_EXT');
      final idB = await montarTrac('TRAC1_DER_EXT');
      await service.rotar(
          montajeId: idA, posicionDestino: 'TRAC1_DER_EXT', supervisorDni: '1');
      final activos =
          await service.streamMontajesActivosPorUnidad('AB123CD').first;
      final porId = {for (final m in activos) m.id: m};
      expect(porId[idA]!.posicion, 'TRAC1_DER_EXT');
      expect(porId[idB]!.posicion, 'TRAC1_IZQ_EXT');
      expect(activos.length, 2);
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 3);
    });

    test('rechaza rotar a un tipo de uso incompatible', () async {
      await comprar5();
      final id = await montarTrac('TRAC1_IZQ_EXT');
      expect(
        () => service.rotar(
            montajeId: id, posicionDestino: 'DIR_IZQ', supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });

    test('rechaza rotar una RECAPADA a una posición que solo admite nuevas',
        () async {
      await stockRecapArrastre();
      // ENG1 permite recapada; ENG2 no.
      final id = await montarEng('ENG1_IZQ_EXT', vida: 2);
      expect(
        () => service.rotar(
            montajeId: id,
            posicionDestino: 'ENG2_IZQ_EXT',
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });

    test('SWAP inválido: la cubierta del destino no entra en el origen',
        () async {
      await stockRecapArrastre(); // vida 2: 3
      await service.comprar(
          modeloId: 'arr',
          modeloEtiqueta: 'X arrastre',
          cantidad: 3,
          supervisorDni: '1'); // vida 1: 3
      // ENG2 (solo nuevas) con una NUEVA; ENG1 (permite) con una RECAPADA.
      final idNueva = await montarEng('ENG2_IZQ_EXT', vida: 1);
      await montarEng('ENG1_IZQ_EXT', vida: 2);
      // Rotar la nueva a ENG1 mandaría la recapada a ENG2 → rechazado.
      expect(
        () => service.rotar(
            montajeId: idNueva,
            posicionDestino: 'ENG1_IZQ_EXT',
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });

    test('rotar un montaje inexistente lanza', () async {
      expect(
        () => service.rotar(
            montajeId: 'nope',
            posicionDestino: 'TRAC1_DER_EXT',
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });
  });

  group('operaciones de stock de depósito', () {
    test('ajustarInventario: faltante baja el stock y devuelve delta negativo',
        () async {
      await comprar5(); // teórico 5
      final delta = await service.ajustarInventario(
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          vida: 1,
          cantidadFisica: 3,
          supervisorDni: '1');
      expect(delta, -2);
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 3);
    });

    test('ajustarInventario: sin diferencia no cambia nada', () async {
      await comprar5();
      final delta = await service.ajustarInventario(
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          vida: 1,
          cantidadFisica: 5,
          supervisorDni: '1');
      expect(delta, 0);
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 5);
    });

    test('descartarDeDeposito baja el stock', () async {
      await comprar5();
      await service.descartarDeDeposito(
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          vida: 1,
          cantidad: 2,
          supervisorDni: '1');
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 3);
    });

    test('descartarDeDeposito sin stock suficiente lanza', () async {
      await comprar5();
      expect(
        () => service.descartarDeDeposito(
            modeloId: 'm1',
            modeloEtiqueta: 'x',
            vida: 1,
            cantidad: 99,
            supervisorDni: '1'),
        throwsA(isA<MontajeException>()),
      );
    });

    test('ciclo recapado: manda vida 1, recibe como vida 2', () async {
      await comprar5(); // vida 1: 5
      await service.mandarARecapar(
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          vida: 1,
          cantidad: 3,
          supervisorDni: '1');
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 2); // 5−3
      // vuelven 2 (1 la descartó el proveedor) como vida 2.
      await service.recibirDeRecapado(
          modeloId: 'm1',
          modeloEtiqueta: 'x',
          vidaPrevia: 1,
          recibidas: 2,
          supervisorDni: '1');
      expect(await service.stockDisponible(modeloId: 'm1', vida: 2), 2);
      expect(await service.stockDisponible(modeloId: 'm1', vida: 1), 2);
    });
  });

  group('km en vivo por posición', () {
    Montaje montajeManual({
      required String unidadId,
      required String unidadTipo,
      required String posicion,
      double? kmAlMontar,
      DateTime? desde,
    }) =>
        Montaje.fromMap('mng_$posicion', {
          'unidad_id': unidadId,
          'unidad_tipo': unidadTipo,
          'posicion': posicion,
          'modelo_id': 'm1',
          'modelo_etiqueta': 'x',
          'tipo_uso': 'TRACCION',
          'vida': 1,
          'km_vida_estimada': 80000,
          'desde': Timestamp.fromDate(desde ?? DateTime(2026, 1, 1)),
          'hasta': null,
          'km_unidad_al_montar': kmAlMontar,
          'montado_por_dni': '1',
        });

    String telId(String t, DateTime f) =>
        '${t}_${f.year}-${f.month.toString().padLeft(2, '0')}-${f.day.toString().padLeft(2, '0')}';

    test('tractor: KM_ACTUAL − km_al_montar', () async {
      await fake
          .collection('VEHICULOS')
          .doc('AB123CD')
          .set({'KM_ACTUAL': 180000});
      final km = await service.kmRecorridoPorPosicion(
        unidadId: 'AB123CD',
        unidadTipo: TipoUnidadCubierta.tractor,
        montajesActivos: [
          montajeManual(
              unidadId: 'AB123CD',
              unidadTipo: 'TRACTOR',
              posicion: 'TRAC1_IZQ_EXT',
              kmAlMontar: 100000),
        ],
      );
      expect(km['TRAC1_IZQ_EXT'], 80000.0);
    });

    test('tractor sin KM_ACTUAL => null', () async {
      final km = await service.kmRecorridoPorPosicion(
        unidadId: 'SIN_KM',
        unidadTipo: TipoUnidadCubierta.tractor,
        montajesActivos: [
          montajeManual(
              unidadId: 'SIN_KM',
              unidadTipo: 'TRACTOR',
              posicion: 'TRAC1_IZQ_EXT',
              kmAlMontar: 100000),
        ],
      );
      expect(km['TRAC1_IZQ_EXT'], null);
    });

    test('enganche: cruza la dupla con telemetría del tractor', () async {
      final ahora = DateTime.now();
      final hace10 = ahora.subtract(const Duration(days: 10));
      await fake.collection('ASIGNACIONES_ENGANCHE').add({
        'enganche_id': 'ENGU',
        'tractor_id': 'TR1',
        'desde': Timestamp.fromDate(hace10),
        'hasta': null,
      });
      await fake
          .collection('TELEMETRIA_HISTORICO')
          .doc(telId('TR1', hace10))
          .set({'km': 100000});
      await fake
          .collection('TELEMETRIA_HISTORICO')
          .doc(telId('TR1', ahora))
          .set({'km': 105000});
      final km = await service.kmRecorridoPorPosicion(
        unidadId: 'ENGU',
        unidadTipo: TipoUnidadCubierta.enganche,
        montajesActivos: [
          montajeManual(
              unidadId: 'ENGU',
              unidadTipo: 'ENGANCHE',
              posicion: 'ENG1_IZQ_EXT',
              desde: hace10),
        ],
      );
      expect(km['ENG1_IZQ_EXT'], 5000.0); // 105000 − 100000
    });

    test('enganche sin telemetría del tractor => null', () async {
      final hace10 = DateTime.now().subtract(const Duration(days: 10));
      await fake.collection('ASIGNACIONES_ENGANCHE').add({
        'enganche_id': 'ENGU',
        'tractor_id': 'TR1',
        'desde': Timestamp.fromDate(hace10),
        'hasta': null,
      });
      final km = await service.kmRecorridoPorPosicion(
        unidadId: 'ENGU',
        unidadTipo: TipoUnidadCubierta.enganche,
        montajesActivos: [
          montajeManual(
              unidadId: 'ENGU',
              unidadTipo: 'ENGANCHE',
              posicion: 'ENG1_IZQ_EXT',
              desde: hace10),
        ],
      );
      expect(km['ENG1_IZQ_EXT'], null);
    });
  });
}
