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
}
