// Tests para `planificarAprobacion` — la lógica pura de
// `RevisionService.finalizarRevision` que decide qué actualizar cuando
// el admin aprueba una solicitud.
//
// Si esto se rompe sin tests:
// - Aprobar un VENCIMIENTO podría dejar de actualizar la URL del
//   archivo o el timestamp `ultima_auditoria` (data inconsistente).
// - Aprobar un cambio de tractor podría no llamar al servicio de
//   asignaciones (rompiendo el log histórico chofer↔vehículo).
// - Aprobar un cambio de enganche podría no liberar la unidad anterior
//   (queda como OCUPADO para siempre).
//
// El refactor de 2026-05-03 extrajo esta función pura del service para
// poder testearla sin mockear FirebaseFirestore + Storage + Auth.
// El batch + storage delete + delete de la solicitud quedaron en
// `finalizarRevision` y no se cubren acá (delegación al SDK).

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/revisions/services/revision_service.dart';

void main() {
  group('planificarAprobacion — datos incompletos', () {
    test('coleccion_destino vacío → StateError', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': '',
          'dni': '35244439',
          'campo': 'VENCIMIENTO_LICENCIA',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('dni vacío → StateError', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': 'EMPLEADOS',
          'dni': '',
          'campo': 'VENCIMIENTO_LICENCIA',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('campo vacío → StateError', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': 'EMPLEADOS',
          'dni': '35244439',
          'campo': '',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('campos faltantes (no presentes en map) → StateError', () {
      expect(
        () => planificarAprobacion({}),
        throwsA(isA<StateError>()),
      );
    });

    test('campos con whitespace puro → StateError (trim antes de validar)', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': '   ',
          'dni': '35244439',
          'campo': 'VENCIMIENTO_LICENCIA',
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('planificarAprobacion — VENCIMIENTO_*', () {
    test('VENCIMIENTO_LICENCIA actualiza fecha + ARCHIVO_LICENCIA + timestamp', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'VENCIMIENTO_LICENCIA',
        'fecha_vencimiento': '2027-05-30',
        'url_archivo': 'https://storage.example/lic_35244439.pdf',
      });
      expect(plan.colDestino, 'EMPLEADOS');
      expect(plan.idDoc, '35244439');
      expect(plan.campoAct, 'VENCIMIENTO_LICENCIA');
      expect(plan.camposDestino['VENCIMIENTO_LICENCIA'], '2027-05-30');
      expect(plan.camposDestino['ARCHIVO_LICENCIA'],
          'https://storage.example/lic_35244439.pdf');
      // ultima_auditoria es FieldValue.serverTimestamp() — no podemos
      // comparar valor exacto, pero debe estar presente.
      expect(plan.camposDestino.containsKey('ultima_auditoria'), isTrue);
      expect(plan.vehiculosUpdates, isEmpty);
      expect(plan.asignacionRequest, isNull);
    });

    test('VENCIMIENTO_PREOCUPACIONAL → ARCHIVO_PREOCUPACIONAL', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'VENCIMIENTO_PREOCUPACIONAL',
        'fecha_vencimiento': '2026-12-31',
        'url_archivo': 'https://storage.example/preo.pdf',
      });
      expect(plan.camposDestino['VENCIMIENTO_PREOCUPACIONAL'], '2026-12-31');
      expect(plan.camposDestino['ARCHIVO_PREOCUPACIONAL'],
          'https://storage.example/preo.pdf');
    });

    test('VENCIMIENTO_RTO sobre VEHICULOS también funciona', () {
      // Vencimientos de chasis viven en VEHICULOS, mismo patrón.
      final plan = planificarAprobacion({
        'coleccion_destino': 'VEHICULOS',
        'dni': 'AI162YT',
        'campo': 'VENCIMIENTO_RTO',
        'fecha_vencimiento': '2027-01-15',
        'url_archivo': 'https://storage.example/rto.pdf',
      });
      expect(plan.colDestino, 'VEHICULOS');
      expect(plan.idDoc, 'AI162YT');
      expect(plan.camposDestino['VENCIMIENTO_RTO'], '2027-01-15');
      expect(plan.camposDestino['ARCHIVO_RTO'],
          'https://storage.example/rto.pdf');
    });
  });

  group('planificarAprobacion — SOLICITUD_VEHICULO', () {
    test('delega a AsignacionVehiculoService (no toca camposDestino)', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_VEHICULO',
        'patente': 'AI162YT',
      });
      expect(plan.camposDestino, isEmpty,
          reason: 'cambio de vehículo NO toca el doc destino directo');
      expect(plan.vehiculosUpdates, isEmpty);
      expect(plan.asignacionRequest, isNotNull);
      expect(plan.asignacionRequest!.choferDni, '35244439');
      expect(plan.asignacionRequest!.nuevaPatente, 'AI162YT');
      expect(plan.asignacionRequest!.motivo, 'Aprobado desde REVISIONES');
    });

    test('SOLICITUD_VEHICULO sin patente → asignacionRequest con string vacío', () {
      // Caso de "liberar" la unidad: aprobar la solicitud con patente
      // vacía (el AsignacionVehiculoService maneja "" como release).
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_VEHICULO',
        'patente': '',
      });
      expect(plan.asignacionRequest, isNotNull);
      expect(plan.asignacionRequest!.nuevaPatente, '');
    });
  });

  group('planificarAprobacion — SOLICITUD_ENGANCHE', () {
    test('cambio: setea ENGANCHE + actualiza ESTADO de nueva y vieja', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': 'BAT123',
        'unidad_actual': 'BAT099',
      });
      expect(plan.camposDestino, {'ENGANCHE': 'BAT123'});
      expect(plan.vehiculosUpdates.length, 2);
      expect(
        plan.vehiculosUpdates,
        containsAll([
          (patente: 'BAT123', estado: 'OCUPADO'),
          (patente: 'BAT099', estado: 'LIBRE'),
        ]),
      );
      expect(plan.asignacionRequest, isNull);
    });

    test('chofer SIN unidad anterior → solo OCUPA la nueva', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': 'BAT123',
        'unidad_actual': '-',
      });
      expect(plan.camposDestino, {'ENGANCHE': 'BAT123'});
      expect(plan.vehiculosUpdates, [
        (patente: 'BAT123', estado: 'OCUPADO'),
      ]);
    });

    test('"SIN ASIGNAR" como unidad_actual: tratado como sin anterior', () {
      // Variante histórica del placeholder que debería ser "-" pero a
      // veces aparece literal en data vieja.
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': 'BAT123',
        'unidad_actual': 'SIN ASIGNAR',
      });
      expect(plan.vehiculosUpdates, [
        (patente: 'BAT123', estado: 'OCUPADO'),
      ]);
    });

    test('"sin asignar" minúscula también: case-insensitive', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': 'BAT123',
        'unidad_actual': 'sin asignar',
      });
      expect(plan.vehiculosUpdates, [
        (patente: 'BAT123', estado: 'OCUPADO'),
      ]);
    });

    test('liberar enganche (patente "-") → no marca OCUPADO, sí LIBERA viejo', () {
      // Caso: chofer renuncia al enganche, no toma uno nuevo.
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': '-',
        'unidad_actual': 'BAT099',
      });
      expect(plan.camposDestino, {'ENGANCHE': '-'});
      expect(plan.vehiculosUpdates, [
        (patente: 'BAT099', estado: 'LIBRE'),
      ]);
    });

    test('caso degenerado (sin nueva, sin vieja): solo limpia ENGANCHE', () {
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': '35244439',
        'campo': 'SOLICITUD_ENGANCHE',
        'patente': '',
        'unidad_actual': '',
      });
      expect(plan.camposDestino, {'ENGANCHE': ''});
      expect(plan.vehiculosUpdates, isEmpty);
    });
  });

  group('planificarAprobacion — campo NO permitido (seguridad 2026-05-30)', () {
    // Antes el fallback aceptaba CUALQUIER `campo` y escribía
    // {campo: fecha_vencimiento}. Eso permitía escalada de privilegios: un
    // chofer creaba una "revisión" con campo:'ROL' y al aprobarla el admin se
    // volvía ADMIN. Ahora se RECHAZA todo lo que no sea VENCIMIENTO_* o las 2
    // solicitudes. (La rule de REVISIONES valida la misma whitelist en el create.)
    test('campo ROL → StateError (no permite escalar a admin)', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': 'EMPLEADOS',
          'dni': '35244439',
          'campo': 'ROL',
          'fecha_vencimiento': 'ADMIN',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('campo ACTIVO → StateError (no permite revivir una baja)', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': 'EMPLEADOS',
          'dni': '35244439',
          'campo': 'ACTIVO',
          'fecha_vencimiento': true,
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('campo legacy sin prefijo VENCIMIENTO_ → StateError (ya no se acepta)', () {
      expect(
        () => planificarAprobacion({
          'coleccion_destino': 'EMPLEADOS',
          'dni': '35244439',
          'campo': 'CAMPO_LEGACY',
          'fecha_vencimiento': '2027-06-15',
        }),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('planificarAprobacion — defensas', () {
    test('valores con whitespace al borde se trimean', () {
      final plan = planificarAprobacion({
        'coleccion_destino': '  EMPLEADOS  ',
        'dni': '  35244439  ',
        'campo': '  VENCIMIENTO_LICENCIA  ',
        'fecha_vencimiento': '2027-05-30',
        'url_archivo': 'https://example.com/x.pdf',
      });
      expect(plan.colDestino, 'EMPLEADOS');
      expect(plan.idDoc, '35244439');
      expect(plan.campoAct, 'VENCIMIENTO_LICENCIA');
    });

    test('field types numéricos por error: coerción string', () {
      // Si un script accidentalmente guardó dni como número en
      // Firestore, no rompemos — toString() lo coerciona.
      final plan = planificarAprobacion({
        'coleccion_destino': 'EMPLEADOS',
        'dni': 35244439,
        'campo': 'VENCIMIENTO_LICENCIA',
        'fecha_vencimiento': '2027-05-30',
        'url_archivo': 'https://example.com/x.pdf',
      });
      expect(plan.idDoc, '35244439');
    });
  });
}
