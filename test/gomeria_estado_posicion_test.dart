import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/constants/posiciones.dart';
import 'package:coopertrans_movil/features/gomeria/models/montaje.dart';
import 'package:coopertrans_movil/features/gomeria/models/nivel_desgaste.dart';
import 'package:coopertrans_movil/features/gomeria/models/estado_posicion.dart';

/// Tests de `construirEstadoUnidad` (rediseño gomería 2026-05-29): arma el
/// estado de todas las posiciones de una unidad (semáforo) combinando los
/// montajes activos con el km recorrido por posición. PURA.
void main() {
  Montaje montajeEn(
    String posicion, {
    String unidadTipo = 'TRACTOR',
    int? kmVida = 80000,
    double? kmAlMontar = 100000,
  }) =>
      Montaje.fromMap('id_$posicion', {
        'unidad_id': 'AB123CD',
        'unidad_tipo': unidadTipo,
        'posicion': posicion,
        'modelo_id': 'm1',
        'modelo_etiqueta': 'Bridgestone',
        'tipo_uso': 'TRACCION',
        'vida': 1,
        'km_vida_estimada': kmVida,
        'desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
        'hasta': null,
        'km_unidad_al_montar': kmAlMontar,
        'montado_por_dni': '1',
      });

  group('construirEstadoUnidad — tractor', () {
    test('sin montajes: 10 posiciones, todas vacías y sinDatos', () {
      final estados = construirEstadoUnidad(
        unidadTipo: TipoUnidadCubierta.tractor,
        montajesActivos: const [],
      );
      expect(estados.length, 10);
      expect(estados.every((e) => !e.ocupada), true);
      expect(estados.every((e) => e.nivel == NivelDesgaste.sinDatos), true);
    });

    test('posición ocupada calcula % por km del tractor (KM_ACTUAL)', () {
      final estados = construirEstadoUnidad(
        unidadTipo: TipoUnidadCubierta.tractor,
        montajesActivos: [montajeEn('TRAC1_IZQ_EXT')], // montó 100000, vida 80000
        kmActualUnidad: 164000, // 64000 km => 80%
      );
      final ocup =
          estados.firstWhere((e) => e.posicion.codigo == 'TRAC1_IZQ_EXT');
      expect(ocup.ocupada, true);
      expect(ocup.porcentajeVida, 80.0);
      expect(ocup.nivel, NivelDesgaste.alerta);
      expect(estados.where((e) => e.ocupada).length, 1);
    });
  });

  group('construirEstadoUnidad — enganche', () {
    test('usa kmRecorridoPorPosicion (cálculo robusto) → 12 posiciones', () {
      final estados = construirEstadoUnidad(
        unidadTipo: TipoUnidadCubierta.enganche,
        montajesActivos: [
          montajeEn('ENG1_IZQ_EXT',
              unidadTipo: 'ENGANCHE', kmVida: 100000, kmAlMontar: null)
        ],
        kmRecorridoPorPosicion: {'ENG1_IZQ_EXT': 105000}, // 105% => critico
      );
      expect(estados.length, 12);
      final ocup =
          estados.firstWhere((e) => e.posicion.codigo == 'ENG1_IZQ_EXT');
      expect(ocup.porcentajeVida, 105.0);
      expect(ocup.nivel, NivelDesgaste.critico);
    });

    test('enganche sin km recorrido => sinDatos', () {
      final estados = construirEstadoUnidad(
        unidadTipo: TipoUnidadCubierta.enganche,
        montajesActivos: [
          montajeEn('ENG1_IZQ_EXT', unidadTipo: 'ENGANCHE', kmAlMontar: null)
        ],
      );
      final ocup =
          estados.firstWhere((e) => e.posicion.codigo == 'ENG1_IZQ_EXT');
      expect(ocup.porcentajeVida, null);
      expect(ocup.nivel, NivelDesgaste.sinDatos);
    });
  });

  test('el km por posición tiene prioridad sobre kmActualUnidad', () {
    final estados = construirEstadoUnidad(
      unidadTipo: TipoUnidadCubierta.tractor,
      montajesActivos: [montajeEn('TRAC1_IZQ_EXT', kmAlMontar: 100000, kmVida: 80000)],
      kmRecorridoPorPosicion: {'TRAC1_IZQ_EXT': 40000}, // 50%
      kmActualUnidad: 999999, // se ignora porque gana el km por posición
    );
    final ocup =
        estados.firstWhere((e) => e.posicion.codigo == 'TRAC1_IZQ_EXT');
    expect(ocup.porcentajeVida, 50.0);
  });
}
