import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/models/stock_movimiento.dart';

/// Tests del stock por cantidades (rediseño gomería 2026-05-29). El stock
/// se lleva como log de movimientos con signo; el actual = suma de deltas
/// por SKU (modelo+vida). Foco: la función pura `calcularStock` y los signos.
void main() {
  StockMovimiento mov({
    required TipoMovimientoStock tipo,
    String modeloId = 'mod1',
    String etiqueta = 'Bridgestone R268',
    int vida = 1,
    required int delta,
    DateTime? fecha,
  }) =>
      StockMovimiento(
        id: 'x',
        tipo: tipo,
        modeloId: modeloId,
        modeloEtiqueta: etiqueta,
        vida: vida,
        delta: delta,
        fecha: fecha ?? DateTime(2026, 1, 1),
        responsableDni: '123',
        responsableNombre: null,
        motivo: null,
        refUnidad: null,
        refPosicion: null,
      );

  group('TipoMovimientoStock', () {
    test('signos naturales (entra/sale del depósito)', () {
      expect(TipoMovimientoStock.compra.signo, 1);
      expect(TipoMovimientoStock.deRecapado.signo, 1);
      expect(TipoMovimientoStock.retiroADeposito.signo, 1);
      expect(TipoMovimientoStock.montaje.signo, -1);
      expect(TipoMovimientoStock.aRecapado.signo, -1);
      expect(TipoMovimientoStock.descarte.signo, -1);
      expect(TipoMovimientoStock.ajuste.signo, 0); // signo lo define el delta
    });

    test('fromCodigo case-insensitive + null safe', () {
      expect(TipoMovimientoStock.fromCodigo('compra'), TipoMovimientoStock.compra);
      expect(TipoMovimientoStock.fromCodigo('A_RECAPADO'), TipoMovimientoStock.aRecapado);
      expect(TipoMovimientoStock.fromCodigo(null), null);
      expect(TipoMovimientoStock.fromCodigo('xx'), null);
    });
  });

  group('StockMovimiento — parsing', () {
    test('fromMap / toMap round-trip de campos', () {
      final m = StockMovimiento.fromMap('id1', {
        'tipo': 'MONTAJE',
        'modelo_id': 'mod9',
        'modelo_etiqueta': 'Pirelli FR01',
        'vida': 2,
        'delta': -1,
        'fecha': Timestamp.fromDate(DateTime(2026, 5, 1)),
        'responsable_dni': '999',
        'ref_unidad': 'AB123CD',
        'ref_posicion': 'DIR_IZQ',
      });
      expect(m.tipo, TipoMovimientoStock.montaje);
      expect(m.vida, 2);
      expect(m.delta, -1);
      expect(m.sku, 'mod9|2');
      expect(m.refUnidad, 'AB123CD');
      final out = m.toMap();
      expect(out['tipo'], 'MONTAJE');
      expect(out['delta'], -1);
    });
  });

  group('calcularStock', () {
    test('suma deltas por SKU', () {
      // compra 50, monta 3, vuelve 1 → 48
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, delta: 50),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
        mov(tipo: TipoMovimientoStock.retiroADeposito, delta: 1),
      ]);
      expect(stock.length, 1);
      expect(stock.first.cantidad, 48);
      expect(stock.first.modeloId, 'mod1');
      expect(stock.first.vida, 1);
    });

    test('separa por modelo y por vida', () {
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, modeloId: 'A', vida: 1, delta: 10),
        mov(tipo: TipoMovimientoStock.compra, modeloId: 'A', vida: 2, delta: 5),
        mov(tipo: TipoMovimientoStock.compra, modeloId: 'B', vida: 1, delta: 7),
      ]);
      expect(stock.length, 3);
      final a1 = stock.firstWhere((s) => s.modeloId == 'A' && s.vida == 1);
      final a2 = stock.firstWhere((s) => s.modeloId == 'A' && s.vida == 2);
      expect(a1.cantidad, 10);
      expect(a2.cantidad, 5);
      expect(a2.esRecapada, true);
      expect(a2.etiquetaVida, 'Recapada 1');
    });

    test('SKU que llega a 0 se omite', () {
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, delta: 2),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
      ]);
      expect(stock.where((s) => s.modeloId == 'mod1'), isEmpty);
    });

    test('ajuste negativo (faltante de inventario físico) baja el stock', () {
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, delta: 30),
        mov(tipo: TipoMovimientoStock.ajuste, delta: -2), // conteo: faltan 2
      ]);
      expect(stock.first.cantidad, 28);
    });

    test('cantidad negativa NO se oculta (señala error de registro)', () {
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, delta: 1),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1),
        mov(tipo: TipoMovimientoStock.montaje, delta: -1), // montó más de lo que había
      ]);
      expect(stock.length, 1);
      expect(stock.first.cantidad, -1);
    });

    test('etiqueta queda la del movimiento más reciente', () {
      final stock = calcularStock([
        mov(tipo: TipoMovimientoStock.compra, etiqueta: 'Etiqueta vieja', delta: 5, fecha: DateTime(2026, 1, 1)),
        mov(tipo: TipoMovimientoStock.compra, etiqueta: 'Etiqueta nueva', delta: 5, fecha: DateTime(2026, 6, 1)),
      ]);
      expect(stock.first.modeloEtiqueta, 'Etiqueta nueva');
      expect(stock.first.cantidad, 10);
    });

    test('lista vacía → stock vacío', () {
      expect(calcularStock([]), isEmpty);
    });
  });
}
