// Tests del soporte de MÚLTIPLES adelantos por viaje (Santiago
// 2026-06-10: "muchas veces los viajes son largos y se les da un
// adelanto más"). Cubre las dos piezas de lógica pura del cambio:
//   1. AdelantosService.ordenarAdelantosDeViaje — filtro de eliminados
//      + orden cronológico (la parte testeable de getTodosPorViaje; la
//      consulta Firestore va a smoke manual por la instancia global).
//   2. BorradorViaje.fromMap — compat retro del borrador: array nuevo
//      `adelantos_asociados_ids` con fallback al `adelanto_asociado_id`
//      singular viejo (un borrador en vuelo al deploy sigue hidratando).

import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/logistica/models/adelanto_chofer.dart';
import 'package:coopertrans_movil/features/logistica/services/adelantos_service.dart';
import 'package:coopertrans_movil/features/logistica/services/borradores_viaje_service.dart';

AdelantoChofer ad({
  required String id,
  required DateTime fecha,
  double monto = 1000,
  bool eliminado = false,
}) {
  return AdelantoChofer(
    id: id,
    choferDni: '123',
    fecha: fecha,
    monto: monto,
    eliminado: eliminado,
  );
}

void main() {
  group('ordenarAdelantosDeViaje', () {
    test('excluye soft-deleted por default', () {
      final res = AdelantosService.ordenarAdelantosDeViaje([
        ad(id: 'a', fecha: DateTime(2026, 5, 1)),
        ad(id: 'b', fecha: DateTime(2026, 5, 2), eliminado: true),
        ad(id: 'c', fecha: DateTime(2026, 5, 3)),
      ]);
      expect(res.map((a) => a.id), ['a', 'c']);
    });

    test('incluye eliminados con la flag', () {
      final res = AdelantosService.ordenarAdelantosDeViaje(
        [
          ad(id: 'a', fecha: DateTime(2026, 5, 1)),
          ad(id: 'b', fecha: DateTime(2026, 5, 2), eliminado: true),
        ],
        incluirEliminados: true,
      );
      expect(res.map((a) => a.id), ['a', 'b']);
    });

    test('ordena por fecha ascendente (cronológico)', () {
      final res = AdelantosService.ordenarAdelantosDeViaje([
        ad(id: 'tarde', fecha: DateTime(2026, 5, 20)),
        ad(id: 'temprano', fecha: DateTime(2026, 5, 2)),
        ad(id: 'medio', fecha: DateTime(2026, 5, 10)),
      ]);
      expect(res.map((a) => a.id), ['temprano', 'medio', 'tarde']);
    });

    test('id como desempate determinístico ante misma fecha', () {
      final f = DateTime(2026, 5, 5);
      final res = AdelantosService.ordenarAdelantosDeViaje([
        ad(id: 'z', fecha: f),
        ad(id: 'a', fecha: f),
        ad(id: 'm', fecha: f),
      ]);
      expect(res.map((a) => a.id), ['a', 'm', 'z']);
    });

    test('lista vacía → vacía', () {
      expect(AdelantosService.ordenarAdelantosDeViaje([]), isEmpty);
    });

    test('todos eliminados sin flag → vacía', () {
      final res = AdelantosService.ordenarAdelantosDeViaje([
        ad(id: 'a', fecha: DateTime(2026, 5, 1), eliminado: true),
        ad(id: 'b', fecha: DateTime(2026, 5, 2), eliminado: true),
      ]);
      expect(res, isEmpty);
    });
  });

  group('BorradorViaje.fromMap — adelantos asociados', () {
    Map<String, dynamic> base(Map<String, dynamic> extra) => {
          'chofer_dni': '123',
          'estado': 'PLANEADO',
          'tramos': <dynamic>[],
          ...extra,
        };

    test('lee el array nuevo adelantos_asociados_ids', () {
      final b = BorradorViaje.fromMap(base({
        'adelantos_asociados_ids': ['a1', 'a2', 'a3'],
      }));
      expect(b.adelantosAsociadosIds, ['a1', 'a2', 'a3']);
    });

    test('fallback al campo singular viejo (borrador en vuelo)', () {
      final b = BorradorViaje.fromMap(base({
        'adelanto_asociado_id': 'viejo1',
      }));
      expect(b.adelantosAsociadosIds, ['viejo1']);
    });

    test('el array nuevo tiene precedencia sobre el viejo', () {
      final b = BorradorViaje.fromMap(base({
        'adelantos_asociados_ids': ['nuevo1', 'nuevo2'],
        'adelanto_asociado_id': 'viejo1',
      }));
      expect(b.adelantosAsociadosIds, ['nuevo1', 'nuevo2']);
    });

    test('sin ningún campo → lista vacía', () {
      final b = BorradorViaje.fromMap(base({}));
      expect(b.adelantosAsociadosIds, isEmpty);
    });

    test('filtra ids vacíos del array', () {
      final b = BorradorViaje.fromMap(base({
        'adelantos_asociados_ids': ['a1', '', '  ', 'a2'],
      }));
      // El '  ' (espacios) NO se filtra — solo el string vacío exacto;
      // los ids reales de Firestore nunca son espacios, así que alcanza
      // con descartar el vacío. Documentamos el comportamiento real.
      expect(b.adelantosAsociadosIds, ['a1', '  ', 'a2']);
    });

    test('campo singular vacío → lista vacía (no [""])', () {
      final b = BorradorViaje.fromMap(base({
        'adelanto_asociado_id': '',
      }));
      expect(b.adelantosAsociadosIds, isEmpty);
    });
  });

  group('delta de asociación (semántica del guardado)', () {
    // El form calcula: aAsociar = actual − inicial; aDesasociar =
    // inicial − actual. Lockear la semántica con sets directos (la
    // lógica vive inline en el form, pero el contrato es este).
    ({Set<String> aAsociar, Set<String> aDesasociar}) delta(
      Set<String> inicial,
      Set<String> actual,
    ) =>
        (
          aAsociar: actual.difference(inicial),
          aDesasociar: inicial.difference(actual),
        );

    test('agregar un segundo adelanto a un viaje que ya tenía uno', () {
      final d = delta({'a1'}, {'a1', 'a2'});
      expect(d.aAsociar, {'a2'});
      expect(d.aDesasociar, isEmpty);
    });

    test('quitar uno de dos', () {
      final d = delta({'a1', 'a2'}, {'a1'});
      expect(d.aAsociar, isEmpty);
      expect(d.aDesasociar, {'a2'});
    });

    test('cambiar el chofer limpia todo → desasocia los previos', () {
      final d = delta({'a1', 'a2'}, <String>{});
      expect(d.aAsociar, isEmpty);
      expect(d.aDesasociar, {'a1', 'a2'});
    });

    test('sin cambios → ningún write', () {
      final d = delta({'a1', 'a2'}, {'a1', 'a2'});
      expect(d.aAsociar, isEmpty);
      expect(d.aDesasociar, isEmpty);
    });

    test('swap completo de adelantos', () {
      final d = delta({'a1'}, {'a2'});
      expect(d.aAsociar, {'a2'});
      expect(d.aDesasociar, {'a1'});
    });
  });
}
