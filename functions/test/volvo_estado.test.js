// Tests del parser PURO `parseEstadoVolvo` (lib/volvo_estado.js compilado).
// Lockea la extracción de campos del snapshot rFMS (VOLVOGROUPSNAPSHOT) que
// alimenta VOLVO_ESTADO → jornada/mantenimiento/carga. No requiere Firestore.

const { test, describe } = require('node:test');
const assert = require('node:assert');

const { parseEstadoVolvo } = require('../lib/volvo_estado');

// Snapshot representativo (estructura rFMS + lo visto en la web de Vecchi:
// AB493CP 79 km/h, odo 1.245.516, fuel 58%, peso tras 7,6 t, etc.).
const SAMPLE = {
  vin: 'yv2r0a1234567890',
  createdDateTime: '2026-05-21T19:26:00Z',
  hrTotalVehicleDistance: 1245516000, // m
  totalEngineHours: 23283,
  engineTotalFuelUsed: 500000,
  grossCombinationVehicleWeight: 7600, // kg
  snapshotData: {
    fuelLevel1: 58,
    catalystFuelLevel: 81,
    tachographSpeed: 79,
    wheelBasedSpeed: 78,
    engineSpeed: 1200,
    driver1WorkingState: 'DRIVE',
    engineCoolantTemperature: 88,
    gnssPosition: {
      latitude: -38.97043,
      longitude: -63.93092,
      heading: 270,
      speed: 77,
      positionDateTime: '2026-05-21T19:25:30Z',
    },
    axleWeight: [{ weight: 0 }, { weight: 7600 }],
    volvoGroupSnapshot: {
      estimatedDistanceToEmpty: { fuel: 2513000 }, // m
    },
  },
  uptimeData: {
    serviceDistance: 50000, // m
    engineCoolantTemperature: 91,
    tellTaleInfo: [
      { tellTale: 'ABS', status: 'RED' },
      { tellTale: 'AEBS', status: 'YELLOW' },
    ],
  },
};

describe('parseEstadoVolvo', () => {
  test('extrae todos los campos del snapshot', () => {
    const e = parseEstadoVolvo(SAMPLE);
    assert.strictEqual(e.vin, 'YV2R0A1234567890'); // upper + trim
    assert.strictEqual(e.lat, -38.97043);
    assert.strictEqual(e.lng, -63.93092);
    assert.strictEqual(e.speed_kmh, 79); // tachographSpeed gana
    assert.strictEqual(e.heading, 270);
    assert.strictEqual(e.motor_encendido, true); // engineSpeed 1200 > 0
    assert.strictEqual(e.conductor_estado, 'DRIVE'); // driver1WorkingState
    assert.strictEqual(e.posicion_ts, '2026-05-21T19:25:30Z'); // timestamp REAL
    assert.strictEqual(e.snapshot_ts, '2026-05-21T19:26:00Z');
    assert.strictEqual(e.odometro_km, 1245516);
    assert.strictEqual(e.horas_motor, 23283);
    assert.strictEqual(e.combustible_pct, 58);
    assert.strictEqual(e.adblue_pct, 81);
    assert.strictEqual(e.autonomia_km, 2513);
    assert.deepStrictEqual(e.peso_eje_t, [0, 7.6]);
    assert.strictEqual(e.peso_total_t, 7.6);
    assert.strictEqual(e.temp_motor_c, 91); // uptime gana sobre snapshot
    assert.strictEqual(e.service_distance_km, 50);
    assert.deepStrictEqual(e.tell_tales, [
      { id: 'ABS', estado: 'RED' },
      { id: 'AEBS', estado: 'YELLOW' },
    ]);
  });

  test('motor apagado y velocidad por gnss si no hay tacho', () => {
    const e = parseEstadoVolvo({
      vin: 'X',
      snapshotData: { engineSpeed: 0, gnssPosition: { speed: 12 } },
    });
    assert.strictEqual(e.motor_encendido, false);
    assert.strictEqual(e.speed_kmh, 12);
  });

  test('motor: sin engineSpeed pero con velocidad ⇒ encendido', () => {
    // Caso real flota Vecchi: engineSpeed ausente en 50/53 unidades.
    const movil = parseEstadoVolvo({
      vin: 'X',
      snapshotData: { wheelBasedSpeed: 60, gnssPosition: {} },
    });
    assert.strictEqual(movil.motor_encendido, true); // velocidad 60 > 0
    // Parado sin engineSpeed ⇒ null (puede estar en ralentí, no afirmamos).
    const parado = parseEstadoVolvo({
      vin: 'X',
      snapshotData: { wheelBasedSpeed: 0, gnssPosition: {} },
    });
    assert.strictEqual(parado.motor_encendido, null);
  });

  test('sin VIN → null', () => {
    assert.strictEqual(parseEstadoVolvo({ snapshotData: {} }), null);
    assert.strictEqual(parseEstadoVolvo(null), null);
    assert.strictEqual(parseEstadoVolvo('x'), null);
  });

  test('snapshot mínimo (solo vin) no rompe', () => {
    const e = parseEstadoVolvo({ vin: 'AB1' });
    assert.strictEqual(e.vin, 'AB1');
    assert.strictEqual(e.lat, null);
    assert.strictEqual(e.speed_kmh, null);
    assert.strictEqual(e.motor_encendido, null);
    assert.deepStrictEqual(e.tell_tales, []);
    assert.strictEqual(e.peso_eje_t, null);
  });
});
