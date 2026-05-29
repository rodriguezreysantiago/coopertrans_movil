import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/constants/posiciones.dart';
import 'package:coopertrans_movil/features/gomeria/models/montaje.dart';

/// Tests del modelo `Montaje` — el corazón del rediseño de gomería
/// (2026-05-29): cubierta montada en una posición SIN serializar la
/// cubierta individual; estado estimado por km recorridos vs vida del modelo.
///
/// Foco: parsing defensivo, el % de vida consumida con las 3 fuentes de km
/// (tractor por odómetro / enganche por cálculo robusto / cerrado), y los
/// enums de retiro.
void main() {
  Map<String, dynamic> baseMap({
    String unidadTipo = 'TRACTOR',
    String posicion = 'DIR_IZQ',
    int vida = 1,
    int? kmVidaEstimada = 80000,
    double? kmUnidadAlMontar = 100000,
    double? kmUnidadAlRetirar,
    double? kmRecorridos,
    Object? hasta,
  }) =>
      {
        'unidad_id': 'AB123CD',
        'unidad_tipo': unidadTipo,
        'posicion': posicion,
        'modelo_id': 'mod1',
        'modelo_etiqueta': 'Bridgestone R268 295/80R22.5 — Tracción',
        'tipo_uso': 'TRACCION',
        'vida': vida,
        'km_vida_estimada': kmVidaEstimada,
        'desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
        'hasta': hasta,
        'km_unidad_al_montar': kmUnidadAlMontar,
        'km_unidad_al_retirar': kmUnidadAlRetirar,
        'km_recorridos': kmRecorridos,
        'montado_por_dni': '123',
      };

  group('Montaje — parsing', () {
    test('fromMap parsea campos base', () {
      final m = Montaje.fromMap('id1', baseMap());
      expect(m.id, 'id1');
      expect(m.unidadId, 'AB123CD');
      expect(m.unidadTipo, TipoUnidadCubierta.tractor);
      expect(m.posicion, 'DIR_IZQ');
      expect(m.modeloId, 'mod1');
      expect(m.vida, 1);
      expect(m.kmVidaEstimada, 80000);
      expect(m.esActivo, true);
    });

    test('unidad_tipo inválido lanza StateError (no enmascara corrupción)', () {
      expect(
        () => Montaje.fromMap('idX', baseMap(unidadTipo: 'CAMIONETA')),
        throwsStateError,
      );
    });

    test('parsing defensivo: data null da defaults sin crashear', () {
      // unidad_tipo ausente => switch cae en null => StateError esperado.
      expect(() => Montaje.fromMap('idY', null), throwsStateError);
    });

    test('hasta presente => montaje cerrado', () {
      final m = Montaje.fromMap(
          'id2', baseMap(hasta: Timestamp.fromDate(DateTime(2026, 3, 1))));
      expect(m.esActivo, false);
      expect(m.diasDuracion(), DateTime(2026, 3, 1).difference(DateTime(2026, 1, 1)).inDays);
    });

    test('posicionTipada resuelve desde el código', () {
      final m = Montaje.fromMap('id3', baseMap(posicion: 'TRAC1_IZQ_EXT'));
      expect(m.posicionTipada?.codigo, 'TRAC1_IZQ_EXT');
      expect(m.posicionTipada?.tipoUnidad, TipoUnidadCubierta.tractor);
    });
  });

  group('Montaje — vida y recapado', () {
    test('vida 1 => Nueva, no recapada', () {
      final m = Montaje.fromMap('id', baseMap(vida: 1));
      expect(m.esRecapada, false);
      expect(m.etiquetaVida, 'Nueva');
    });

    test('vida 2 => Recapada 1', () {
      final m = Montaje.fromMap('id', baseMap(vida: 2));
      expect(m.esRecapada, true);
      expect(m.etiquetaVida, 'Recapada 1');
    });

    test('vida 3 => Recapada 2', () {
      final m = Montaje.fromMap('id', baseMap(vida: 3));
      expect(m.etiquetaVida, 'Recapada 2');
    });
  });

  group('Montaje — % vida consumida (3 fuentes de km)', () {
    test('TRACTOR en vivo: kmActualUnidad - kmUnidadAlMontar', () {
      // montó a 100000, vida esperada 80000. Unidad ahora en 140000 => 40000 km => 50%.
      final m = Montaje.fromMap('id', baseMap(kmUnidadAlMontar: 100000, kmVidaEstimada: 80000));
      expect(m.porcentajeVidaConsumida(kmActualUnidad: 140000), 50.0);
    });

    test('ENGANCHE en vivo: usa kmRecorridosCalculado (cálculo robusto)', () {
      // enganche no tiene odómetro: el caller pasa el km robusto = 60000 / 80000 => 75%.
      final m = Montaje.fromMap('id', baseMap(unidadTipo: 'ENGANCHE', posicion: 'ENG1_IZQ_EXT'));
      expect(m.porcentajeVidaConsumida(kmRecorridosCalculado: 60000), 75.0);
    });

    test('cerrado: usa kmRecorridos persistido por encima de todo', () {
      final m = Montaje.fromMap('id', baseMap(kmRecorridos: 80000, hasta: Timestamp.fromDate(DateTime(2026, 6, 1))));
      expect(m.porcentajeVidaConsumida(kmActualUnidad: 999999), 100.0);
    });

    test('puede exceder 100% (cubierta pasada de vida)', () {
      final m = Montaje.fromMap('id', baseMap(kmUnidadAlMontar: 100000, kmVidaEstimada: 80000));
      expect(m.porcentajeVidaConsumida(kmActualUnidad: 200000), 125.0);
    });

    test('km recorrido negativo (odómetro raro) => 0, no negativo', () {
      final m = Montaje.fromMap('id', baseMap(kmUnidadAlMontar: 100000));
      expect(m.porcentajeVidaConsumida(kmActualUnidad: 90000), 0);
    });

    test('sin km de vida estimada => null (no se puede estimar)', () {
      final m = Montaje.fromMap('id', baseMap(kmVidaEstimada: null));
      expect(m.porcentajeVidaConsumida(kmActualUnidad: 140000), null);
    });

    test('sin ninguna fuente de km => null', () {
      final m = Montaje.fromMap('id', baseMap(kmUnidadAlMontar: null));
      expect(m.porcentajeVidaConsumida(), null);
    });
  });

  group('Montaje — toMapNuevo', () {
    test('serializa montaje nuevo con campos de retiro en null', () {
      final m = Montaje.fromMap('id', baseMap());
      final out = m.toMapNuevo();
      expect(out['unidad_id'], 'AB123CD');
      expect(out['unidad_tipo'], 'TRACTOR');
      expect(out['vida'], 1);
      expect(out['hasta'], null);
      expect(out['km_recorridos'], null);
      expect(out['motivo_retiro'], null);
      expect(out['destino'], null);
    });
  });

  group('Enums de retiro', () {
    test('MotivoRetiro.fromCodigo case-insensitive + null safe', () {
      expect(MotivoRetiro.fromCodigo('desgaste'), MotivoRetiro.desgaste);
      expect(MotivoRetiro.fromCodigo('PINCHAZO'), MotivoRetiro.pinchazo);
      expect(MotivoRetiro.fromCodigo(null), null);
      expect(MotivoRetiro.fromCodigo('xxx'), null);
    });

    test('DestinoRetiro.fromCodigo', () {
      expect(DestinoRetiro.fromCodigo('DEPOSITO'), DestinoRetiro.deposito);
      expect(DestinoRetiro.fromCodigo('recapado'), DestinoRetiro.recapado);
      expect(DestinoRetiro.fromCodigo('descarte'), DestinoRetiro.descarte);
      expect(DestinoRetiro.fromCodigo(null), null);
    });
  });
}
