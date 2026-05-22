// Tests del calculator del ICM (Índice de Conducta de Manejo).
//
// Foco: `categorizarIcm` (función pública top-level) y la lógica de
// umbrales YPF 91/71 que decide si un chofer es BAJO / MEDIO / ALTO
// riesgo según la Minuta de Revisión ICM VECCHI (Bajo 100-91, Medio
// 90-71, Alto 70-0).
//
// Los umbrales están DUPLICADOS en 4 lugares (icm_cesvi.dart,
// icm_historico_service.dart [delega], vista_ejecutiva_service.dart, e
// functions/src/icm_cesvi.ts server-side). Este test es la red de
// seguridad que detecta drift si alguien cambia uno y olvida los otros —
// si los thresholds 91/71 cambian acá, este test ROMPE y obliga a
// revisar todos los call sites.
//
// El flujo completo `IcmCalculator.calcularRanking` (bucketing por día +
// km por patente) se testea en `icm_calculator_flujo_test.dart`.

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/icm/services/icm_calculator.dart';

void main() {
  group('categorizarIcm — umbrales YPF 91/71', () {
    test('ICM 100 (perfecto) → BAJO riesgo', () {
      expect(categorizarIcm(100), CategoriaIcm.bajo);
    });

    test('ICM 91 (límite verde) → BAJO (inclusivo)', () {
      // Crítico: 91 cae en BAJO, no en MEDIO. Si se cambia este
      // umbral, hay que cambiarlo TAMBIÉN en:
      //   - functions/src/icm_cesvi.ts (server)
      //   - icm_cesvi.dart
      //   - vista_ejecutiva_service.dart
      expect(categorizarIcm(91), CategoriaIcm.bajo);
    });

    test('ICM 90.99 (justo abajo del verde) → MEDIO', () {
      expect(categorizarIcm(90.99), CategoriaIcm.medio);
    });

    test('ICM 71 (límite amarillo) → MEDIO (inclusivo)', () {
      // Mismo argumento que 91 — cambio acá obliga a cambiar en los
      // 4 lugares listados arriba.
      expect(categorizarIcm(71), CategoriaIcm.medio);
    });

    test('ICM 70.99 (justo abajo del amarillo) → ALTO', () {
      expect(categorizarIcm(70.99), CategoriaIcm.alto);
    });

    test('ICM 0 (peor caso) → ALTO', () {
      expect(categorizarIcm(0), CategoriaIcm.alto);
    });

    test('ICM 50 (medio del rango ALTO) → ALTO', () {
      expect(categorizarIcm(50), CategoriaIcm.alto);
    });

    test('ICM 79 (medio del rango MEDIO) → MEDIO', () {
      expect(categorizarIcm(79), CategoriaIcm.medio);
    });

    test('ICM 95 (medio del rango BAJO) → BAJO', () {
      expect(categorizarIcm(95), CategoriaIcm.bajo);
    });
  });

  group('categorizarIcm — flag tieneKmReales', () {
    test('tieneKmReales=false → SIN_DATOS aunque el ICM sea alto', () {
      // Caso real: chofer con < 50 km en la semana (umbral
      // _kmMinimoParaIcm). No tenemos suficiente data para calcular
      // ICM significativo — preferimos sinDatos antes que un número
      // ruidoso (ej. 1 sobrevelocidad en 5 km daría ICM 0 falso).
      //
      // Antes del fix 2026-05-17, estos choferes aparecían con
      // categoría ALTO (icm=0) y ocupaban los primeros puestos del
      // ranking "peores" en el reporte a Molina, enmascarando a los
      // realmente problemáticos.
      expect(categorizarIcm(100, tieneKmReales: false), CategoriaIcm.sinDatos);
    });

    test('tieneKmReales=false con ICM 0 → SIN_DATOS (no se confunde con ALTO)', () {
      expect(categorizarIcm(0, tieneKmReales: false), CategoriaIcm.sinDatos);
    });

    test('tieneKmReales=true es el default (omitir el flag)', () {
      // Si alguien refactorea y olvida pasar el flag, queremos que
      // el comportamiento default sea "categorizar normal" (no
      // sinDatos como fallback silencioso).
      expect(categorizarIcm(95), CategoriaIcm.bajo);
      expect(categorizarIcm(80), CategoriaIcm.medio);
      expect(categorizarIcm(40), CategoriaIcm.alto);
    });
  });

  group('categorizarIcm — edge cases defensivos', () {
    test('ICM > 100 (no debería pasar pero defensivo) → BAJO', () {
      // El calculator clamp() a 100, pero si alguna versión vieja del
      // doc en Firestore tiene un valor descalibrado, no rompemos.
      expect(categorizarIcm(150), CategoriaIcm.bajo);
    });

    test('ICM negativo (defensivo) → ALTO', () {
      // Mismo argumento que el anterior — clamp() previene esto pero
      // por defensa.
      expect(categorizarIcm(-10), CategoriaIcm.alto);
    });

    test('ICM con decimales en el borde — 90.5 → MEDIO', () {
      expect(categorizarIcm(90.5), CategoriaIcm.medio);
    });

    test('ICM con decimales en el borde — 91.000001 → BAJO', () {
      // Verifica que el >= es estricto (no margen de tolerancia).
      expect(categorizarIcm(91.000001), CategoriaIcm.bajo);
    });
  });

  group('kTiposInfraccionIcm — set de eventos peligrosos YPF', () {
    // Espejo de functions/src/index.ts:TIPOS_PELIGROSOS_SITRACK.
    // Drift detection: si alguien agrega o quita un tipo, este test
    // rompe y obliga a verificar que el servidor también se actualizó.

    test('contiene los 5 tipos CESVI puros del catálogo Sitrack', () {
      // Refactor Santiago 2026-05-19: el set se redujo de 10 a 5
      // eventos al alinear con la fórmula CESVI homologada YPF.
      // Los otros eventos (267 chofer sin identificar, 326 advertencia
      // colisión, 444 distancia frenado, 1006 salida carril, 1007
      // colisión) son alertas Volvo/Mobileye que NO son parte del ICM
      // CESVI — viven solo en `TIPOS_PELIGROSOS_SITRACK` (TS) para el
      // resumen Molina.
      //
      // CESVI cuenta:
      //   8/9    Inicio/fin de sobrevelocidad → pareados como 1 evento
      //   66     Aceleración brusca           → peso -2.8
      //   67     Frenada brusca               → peso -5.8
      //   383    Giro brusco                  → peso -2.8
      expect(kTiposInfraccionIcm, {8, 9, 66, 67, 383});
    });

    test('cantidad exacta = 5 (CESVI puro)', () {
      expect(kTiposInfraccionIcm.length, 5);
    });

    test('NO incluye eventos Volvo/Mobileye (no son CESVI)', () {
      expect(kTiposInfraccionIcm.contains(267), isFalse);  // chofer sin id
      expect(kTiposInfraccionIcm.contains(326), isFalse);  // adv colisión
      expect(kTiposInfraccionIcm.contains(444), isFalse);  // dist frenado
      expect(kTiposInfraccionIcm.contains(1006), isFalse); // salida carril
      expect(kTiposInfraccionIcm.contains(1007), isFalse); // colisión
    });

    test('un tipo cualquiera que NO debería estar (ej. ignición) NO está', () {
      // ID 1 (ignición ON) NO es infracción — verifica que el set
      // sea cerrado y no incluya eventos benignos.
      expect(kTiposInfraccionIcm.contains(1), isFalse);
      expect(kTiposInfraccionIcm.contains(100), isFalse);
      expect(kTiposInfraccionIcm.contains(0), isFalse);
    });
  });

  group('IcmChofer — modelo inmutable', () {
    test('constructor + campos legibles', () {
      const c = IcmChofer(
        choferDni: '12345678',
        choferNombre: 'PEREZ JUAN',
        totalEventos: 5,
        kmRecorridos: 500,
        infraccionesPor100Km: 1.0,
        icm: 95,
        categoria: CategoriaIcm.bajo,
        eventosPorTipo: {'Sobrevelocidad': 3, 'Frenada brusca': 2},
        patentes: ['AB123CD', 'EF456GH'],
      );
      expect(c.choferDni, '12345678');
      expect(c.choferNombre, 'PEREZ JUAN');
      expect(c.totalEventos, 5);
      expect(c.kmRecorridos, 500);
      expect(c.infraccionesPor100Km, 1.0);
      expect(c.icm, 95);
      expect(c.categoria, CategoriaIcm.bajo);
      expect(c.eventosPorTipo['Sobrevelocidad'], 3);
      expect(c.patentes.length, 2);
    });
  });
}
