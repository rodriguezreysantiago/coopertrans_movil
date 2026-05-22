// Tests de la lógica PURA de parseo/derivación del ICM OFICIAL de Sitrack
// (`IcmOficialPeriodo.fromMap` + getters + helper de color). No tocan
// Firestore — alimentamos un map sintético con la MISMA forma que el doc
// real `ICM_OFICIAL/{YYYY-MM}` (ver sitrack_sync/parser.py).
//
// Recordatorio de escala: en el ICM oficial **MÁS BAJO = MEJOR**.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:coopertrans_movil/features/icm/services/icm_oficial_service.dart';

Map<String, dynamic> _chofer({
  required String dni,
  required String nombre,
  required double icm,
  required String severidad,
  required String severidadLabel,
  int infLeves = 0,
  int infMedias = 0,
  int infAltas = 0,
}) {
  return {
    'dni': dni,
    'nombre': nombre,
    'icm': icm,
    'icm_urbano': icm * 0.7,
    'icm_no_urbano': icm * 1.0,
    'distancia_km': 1000.0,
    'tiempo_h': 20.0,
    'inf_leves': infLeves,
    'inf_medias': infMedias,
    'inf_altas': infAltas,
    'excesos_velocidad': 2,
    'conduccion_agresiva': 5,
    'severidad': severidad,
    'severidad_label': severidadLabel,
  };
}

Map<String, dynamic> _docSintetico() => {
      'periodo': '2026-05',
      'alcance': 'mensual',
      'fecha_desde': '2026-05-01',
      'fecha_hasta': '2026-05-22',
      'icm_general': 20.42,
      'distancia_total_km': 477319.8,
      'tiempo_total_h': 5030.8,
      'infracciones_leves': 674,
      'infracciones_medias': 408,
      'infracciones_altas': 550,
      'choferes_total': 4,
      'choferes_activos': 3,
      'fuente': 'sitrack_icm_oficial',
      // Orden tal cual lo deja el parser: peor→mejor por severidad,
      // sin actividad al final.
      'choferes': [
        _chofer(
          dni: '37389867',
          nombre: 'LESCANO GASTON',
          icm: 61.1,
          severidad: 'HIGH',
          severidadLabel: 'Alto',
          infLeves: 18,
          infMedias: 11,
          infAltas: 27,
        ),
        _chofer(
          dni: '20111222',
          nombre: 'PEREZ JUAN',
          icm: 25.0,
          severidad: 'MEDIUM',
          severidadLabel: 'Medio',
          infMedias: 4,
        ),
        _chofer(
          dni: '30999888',
          nombre: 'GOMEZ ANA',
          icm: 3.0,
          severidad: 'NO',
          severidadLabel: 'Sin infracciones',
        ),
        // Unidad sin chofer identificado → dni vacío + sin actividad.
        _chofer(
          dni: '',
          nombre: 'Vecchi Ariel 012E823C',
          icm: 0.0,
          severidad: 'UNAVAILABLE_NO_ACTIVITY',
          severidadLabel: 'Sin actividad',
        ),
      ],
      'vehiculos': [
        {
          'patente': 'AD614JF',
          'icm': 61.08,
          'icm_urbano': 43.65,
          'icm_no_urbano': 63.96,
          'distancia_km': 6888.7,
          'tiempo_h': 72.5,
          'inf_leves': 18,
          'inf_medias': 11,
          'inf_altas': 27,
          'severidad': 'HIGH',
          'severidad_label': 'Alto',
        },
      ],
    };

void main() {
  group('IcmOficialPeriodo.fromMap', () {
    test('mapea cabecera y listas con la forma real del doc', () {
      final p = IcmOficialPeriodo.fromMap(_docSintetico());
      expect(p.periodo, '2026-05');
      expect(p.icmGeneral, 20.42);
      expect(p.choferesActivos, 3);
      expect(p.choferesTotal, 4);
      expect(p.choferes.length, 4);
      expect(p.vehiculos.length, 1);
      expect(p.infraccionesAltas, 550);
      expect(p.vacio, isFalse);
    });

    test('vacío cuando no hay choferes', () {
      final p = IcmOficialPeriodo.fromMap({'periodo': '2026-06'});
      expect(p.vacio, isTrue);
      expect(p.choferesConActividad, isEmpty);
      expect(p.mejores(5), isEmpty);
    });
  });

  group('derivaciones de ranking (MÁS BAJO = MEJOR)', () {
    final p = IcmOficialPeriodo.fromMap(_docSintetico());

    test('choferesConActividad excluye los UNAVAILABLE_NO_ACTIVITY', () {
      expect(p.choferesConActividad.length, 3);
      expect(
        p.choferesConActividad.every((c) => !c.sinActividad),
        isTrue,
      );
    });

    test('mejores = ICM más bajo entre los activos (GOMEZ primero)', () {
      final mejores = p.mejores(3);
      expect(mejores.first.nombre, 'GOMEZ ANA');
      expect(mejores.last.nombre, 'LESCANO GASTON');
    });

    test('peores = ICM más alto entre los activos (LESCANO primero)', () {
      final peores = p.peores(3);
      expect(peores.first.nombre, 'LESCANO GASTON');
      expect(peores.last.nombre, 'GOMEZ ANA');
    });

    test('choferesParaRanking: peor arriba, sin actividad al final', () {
      final r = p.choferesParaRanking;
      expect(r.first.nombre, 'LESCANO GASTON'); // peor (icm 61.1)
      expect(r.last.sinActividad, isTrue); // la unidad sin chofer
    });

    test('conteoPorSeveridad cuenta solo los activos', () {
      final c = p.conteoPorSeveridad;
      expect(c[SeveridadIcm.alto], 1);
      expect(c[SeveridadIcm.medio], 1);
      expect(c[SeveridadIcm.sinInfracciones], 1);
      expect(c.containsKey(SeveridadIcm.sinActividad), isFalse);
    });
  });

  group('exclusión de testers/tanqueros', () {
    test('excluirDni saca al chofer por DNI pero deja los de dni vacío', () {
      final p = IcmOficialPeriodo.fromMap(
        _docSintetico(),
        excluirDni: (dni) => dni == '37389867', // LESCANO excluido
      );
      expect(p.choferes.any((c) => c.dni == '37389867'), isFalse);
      // El de dni vacío (unidad sin chofer) NO se filtra por DNI.
      expect(p.choferes.any((c) => c.nombre.contains('Vecchi Ariel')), isTrue);
      // El peor visible ahora es PEREZ (icm 25).
      expect(p.choferesParaRanking.first.nombre, 'PEREZ JUAN');
    });
  });

  group('chofer con actividad pero SIN DNI (no rankeable/premiable)', () {
    // Caso real confirmado en Sitrack: BUSCIO/BASTIAS son choferes sin DNI
    // cargado. Si alguna vez manejan, Sitrack les calcula score con
    // severidad real — pero sin DNI no se pueden matchear a EMPLEADOS ni
    // premiar/castigar. Deben quedar FUERA del universo rankeable.
    final doc = {
      'periodo': '2026-05',
      'choferes': [
        _chofer(
          dni: '',
          nombre: 'BUSCIO GUILLERMO',
          icm: 40.0,
          severidad: 'MEDIUM',
          severidadLabel: 'Medio',
          infMedias: 5,
        ),
        _chofer(
          dni: '30999888',
          nombre: 'GOMEZ ANA',
          icm: 3.0,
          severidad: 'NO',
          severidadLabel: 'Sin infracciones',
        ),
      ],
    };
    final p = IcmOficialPeriodo.fromMap(doc);

    test('el sin-DNI con actividad NO entra a choferesConActividad/top5', () {
      expect(p.choferesConActividad.length, 1);
      expect(p.choferesConActividad.first.nombre, 'GOMEZ ANA');
      expect(p.mejores(5).any((c) => c.nombre == 'BUSCIO GUILLERMO'), isFalse);
      expect(p.peores(5).any((c) => c.nombre == 'BUSCIO GUILLERMO'), isFalse);
    });

    test('pero SÍ aparece en choferesParaRanking, al final', () {
      final r = p.choferesParaRanking;
      expect(r.any((c) => c.nombre == 'BUSCIO GUILLERMO'), isTrue);
      expect(r.first.nombre, 'GOMEZ ANA'); // rankeable arriba
      expect(r.last.nombre, 'BUSCIO GUILLERMO'); // resto al final
    });
  });

  group('helpers de severidad', () {
    test('severidadIcmDesde normaliza los strings de Sitrack', () {
      expect(severidadIcmDesde('HIGH'), SeveridadIcm.alto);
      expect(severidadIcmDesde('medium'), SeveridadIcm.medio);
      expect(severidadIcmDesde('LOW'), SeveridadIcm.bajo);
      expect(severidadIcmDesde('NO'), SeveridadIcm.sinInfracciones);
      expect(severidadIcmDesde('UNAVAILABLE_NO_ACTIVITY'),
          SeveridadIcm.sinActividad);
      expect(severidadIcmDesde('???'), SeveridadIcm.desconocida);
    });

    test('colorSeveridadIcm: alto rojo, medio ámbar, bajo/sin verde', () {
      expect(colorSeveridadIcm('HIGH'), Colors.red.shade600);
      expect(colorSeveridadIcm('MEDIUM'), Colors.amber.shade700);
      expect(colorSeveridadIcm('LOW'), Colors.green.shade600);
      expect(colorSeveridadIcm('NO'), Colors.green.shade600);
      expect(colorSeveridadIcm('UNAVAILABLE_NO_ACTIVITY'),
          Colors.blueGrey.shade600);
    });
  });

  group('IcmOficialService.periodoId / labelPeriodo', () {
    test('periodoId tiene forma YYYY-MM', () {
      expect(IcmOficialService.periodoId(), matches(r'^\d{4}-\d{2}$'));
    });

    test('labelPeriodo traduce a mes en español', () {
      expect(IcmOficialService.labelPeriodo('2026-05'), 'Mayo 2026');
      expect(IcmOficialService.labelPeriodo('2026-01'), 'Enero 2026');
    });
  });
}
