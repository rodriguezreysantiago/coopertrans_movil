// Tests para Capabilities (RBAC del cliente Flutter).
//
// Esta matriz define qué pantallas y acciones puede ver/hacer cada rol.
// Si un cambio acá rompe la herencia ADMIN ⊃ SUPERVISOR sin que nos
// enteremos, podríamos terminar con choferes que ven pantallas admin
// (UX rota — la rule de Firestore igual los rechazaría, pero es feo).
//
// Estos tests cubren:
//   - Defaults conservadores (rol unknown / null / empty → CHOFER, sin caps).
//   - Normalización de roles legacy (USUARIO → CHOFER).
//   - Que la herencia ADMIN ⊃ SUPERVISOR se respete.
//   - Capabilities exclusivas de ADMIN no estén en SUPERVISOR.
//   - canAny / canAll / ofRol con casos edge.

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/core/constants/app_constants.dart';
import 'package:coopertrans_movil/core/services/capabilities.dart';

void main() {
  group('Capabilities.can — fallback conservador (rol desconocido)', () {
    test('rol null → set vacío (sin acceso a nada admin)', () {
      expect(Capabilities.can(null, Capability.verPanelAdmin), isFalse);
      expect(Capabilities.can(null, Capability.verListaPersonal), isFalse);
      expect(Capabilities.can(null, Capability.verAuditoria), isFalse);
    });

    test('rol vacío → AppRoles.normalizar lo trata como CHOFER', () {
      expect(Capabilities.can('', Capability.verPanelAdmin), isFalse);
      expect(Capabilities.can('', Capability.crearEmpleado), isFalse);
    });

    test('rol desconocido (typo en Firestore) → trato como CHOFER', () {
      expect(Capabilities.can('SUPERADMIN_TIPO', Capability.verAuditoria),
          isFalse);
      expect(Capabilities.can('xxx', Capability.verPanelAdmin), isFalse);
    });
  });

  group('Capabilities.can — CHOFER y PLANTA (sin acceso admin)', () {
    test('CHOFER no entra al panel admin', () {
      expect(Capabilities.can(AppRoles.chofer, Capability.verPanelAdmin),
          isFalse);
      expect(Capabilities.can(AppRoles.chofer, Capability.verListaPersonal),
          isFalse);
      expect(Capabilities.can(AppRoles.chofer, Capability.verAlertasVolvo),
          isFalse);
    });

    test('PLANTA tampoco entra al panel admin', () {
      expect(Capabilities.can(AppRoles.planta, Capability.verPanelAdmin),
          isFalse);
      expect(Capabilities.can(AppRoles.planta, Capability.crearEmpleado),
          isFalse);
    });

    test('rol legacy USUARIO se normaliza a CHOFER (sin acceso)', () {
      expect(Capabilities.can(AppRoles.usuarioLegacy, Capability.verPanelAdmin),
          isFalse);
    });
  });

  group('Capabilities.can — SUPERVISOR', () {
    test('SUPERVISOR ve todas las pantallas admin operativas', () {
      const expectedTrue = [
        Capability.verPanelAdmin,
        Capability.verListaPersonal,
        Capability.verListaFlota,
        Capability.verVencimientos,
        Capability.verRevisiones,
        Capability.verReportes,
        Capability.verMantenimiento,
        Capability.verAlertasVolvo,
        Capability.verDescargas,
      ];
      for (final cap in expectedTrue) {
        expect(
          Capabilities.can(AppRoles.supervisor, cap),
          isTrue,
          reason: 'SUPERVISOR debe poder $cap',
        );
      }
    });

    test('SUPERVISOR NO ve el WhatsApp Bot (verEstadoBot exclusivo ADMIN, 2026-05-30)',
        () {
      expect(Capabilities.can(AppRoles.supervisor, Capability.verEstadoBot),
          isFalse);
    });

    test('SUPERVISOR puede gestionar personal y flota (excepto borrar)', () {
      expect(Capabilities.can(AppRoles.supervisor, Capability.crearEmpleado),
          isTrue);
      expect(Capabilities.can(AppRoles.supervisor, Capability.editarEmpleado),
          isTrue);
      expect(Capabilities.can(AppRoles.supervisor, Capability.crearVehiculo),
          isTrue);
      expect(Capabilities.can(AppRoles.supervisor, Capability.editarVehiculo),
          isTrue);
    });

    test('SUPERVISOR NO puede borrar personal/vehículos (solo ADMIN)', () {
      expect(Capabilities.can(AppRoles.supervisor, Capability.eliminarEmpleado),
          isFalse);
      expect(Capabilities.can(AppRoles.supervisor, Capability.eliminarVehiculo),
          isFalse);
    });

    test('SUPERVISOR NO puede asignar rol ADMIN ni cambiar roles', () {
      expect(Capabilities.can(AppRoles.supervisor, Capability.asignarRolAdmin),
          isFalse);
      expect(
          Capabilities.can(AppRoles.supervisor, Capability.cambiarRolEmpleado),
          isFalse);
    });

    test('SUPERVISOR NO ve auditoría (solo ADMIN)', () {
      expect(Capabilities.can(AppRoles.supervisor, Capability.verAuditoria),
          isFalse);
    });
  });

  group('Capabilities.can — SEG_HIGIENE (conducta)', () {
    test('SEG_HIGIENE ve ICM + tableros de conducta (Auditoría/Mapa)', () {
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verPanelAdmin),
          isTrue);
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verIcm), isTrue);
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verAlertasVolvo),
          isTrue);
    });

    test('SEG_HIGIENE NO ve Descargas (separado el 2026-05-30)', () {
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verDescargas),
          isFalse);
    });

    test('SEG_HIGIENE NO ve módulos de gestión (personal/gomería/bot)', () {
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verListaPersonal),
          isFalse);
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verGomeria),
          isFalse);
      expect(Capabilities.can(AppRoles.segHigiene, Capability.verEstadoBot),
          isFalse);
    });
  });

  group('Capabilities.can — GOMERIA (solo su módulo)', () {
    test('GOMERIA solo tiene verGomeria (sin panel admin, 2026-05-30)', () {
      expect(Capabilities.can(AppRoles.gomeria, Capability.verGomeria), isTrue);
      // Ya NO tiene verPanelAdmin: va directo a su módulo desde el inicio.
      expect(Capabilities.can(AppRoles.gomeria, Capability.verPanelAdmin),
          isFalse);
      expect(Capabilities.can(AppRoles.gomeria, Capability.verListaPersonal),
          isFalse);
      expect(Capabilities.can(AppRoles.gomeria, Capability.verDescargas),
          isFalse);
      // Único permiso = verGomeria.
      expect(Capabilities.ofRol(AppRoles.gomeria),
          equals({Capability.verGomeria}));
    });
  });

  group('Capabilities.can — ADMIN (herencia + exclusivas)', () {
    test('ADMIN tiene todas las capabilities de SUPERVISOR (herencia)', () {
      // Iteramos el set de SUPERVISOR y verificamos que cada cap esté en ADMIN.
      final supSet = Capabilities.ofRol(AppRoles.supervisor);
      for (final cap in supSet) {
        expect(
          Capabilities.can(AppRoles.admin, cap),
          isTrue,
          reason: 'ADMIN debe heredar $cap de SUPERVISOR',
        );
      }
    });

    test('ADMIN tiene las capabilities exclusivas', () {
      const exclusivasAdmin = [
        Capability.eliminarEmpleado,
        Capability.eliminarVehiculo,
        Capability.asignarRolAdmin,
        Capability.cambiarRolEmpleado,
        Capability.verAuditoria,
        Capability.verEstadoBot, // WhatsApp Bot: exclusivo ADMIN desde 2026-05-30
      ];
      for (final cap in exclusivasAdmin) {
        expect(
          Capabilities.can(AppRoles.admin, cap),
          isTrue,
          reason: 'ADMIN debe poder $cap (exclusiva)',
        );
      }
    });

    test('REGRESSION: si se rompe la herencia, ADMIN debería seguir teniendo TODAS', () {
      // Sanity check: ADMIN tiene exactamente |SUPERVISOR| + 6 exclusivas.
      // Las 6: eliminarEmpleado, eliminarVehiculo, asignarRolAdmin,
      // cambiarRolEmpleado, verAuditoria, verEstadoBot. (verEstadoBot pasó a
      // exclusivo ADMIN el 2026-05-30 al sacarlo de SUPERVISOR — el WhatsApp
      // Bot ya no lo ve el supervisor.) Si alguien agrega una capability nueva
      // en SUPERVISOR sin actualizar adminExtra, este test lo detecta.
      final supSize = Capabilities.ofRol(AppRoles.supervisor).length;
      final adminSize = Capabilities.ofRol(AppRoles.admin).length;
      expect(adminSize, equals(supSize + 6),
          reason:
              'ADMIN debería tener |SUPERVISOR| + 6 exclusivas. Si esto rompe, revisar adminExtra en _resolverHerencia.');
    });
  });

  group('Capabilities.canAny / canAll', () {
    test('canAny: SUPERVISOR tiene alguna entre [verAuditoria, verRevisiones]', () {
      expect(
        Capabilities.canAny(AppRoles.supervisor,
            [Capability.verAuditoria, Capability.verRevisiones]),
        isTrue,
        reason: 'tiene verRevisiones aunque no verAuditoria',
      );
    });

    test('canAny: CHOFER NO tiene ninguna admin', () {
      expect(
        Capabilities.canAny(AppRoles.chofer,
            [Capability.verAuditoria, Capability.verPanelAdmin]),
        isFalse,
      );
    });

    test('canAll: ADMIN tiene todas las exclusivas', () {
      expect(
        Capabilities.canAll(AppRoles.admin, [
          Capability.eliminarEmpleado,
          Capability.asignarRolAdmin,
          Capability.verAuditoria,
        ]),
        isTrue,
      );
    });

    test('canAll: SUPERVISOR NO tiene TODAS si una es exclusiva ADMIN', () {
      expect(
        Capabilities.canAll(AppRoles.supervisor, [
          Capability.crearEmpleado, // sí
          Capability.eliminarEmpleado, // no (ADMIN-only)
        ]),
        isFalse,
      );
    });

    test('canAny / canAll con lista vacía', () {
      // Caso edge: si no hay caps que chequear, canAny=false (no hay
      // ninguna que cumpla) y canAll=true (vacuously true).
      expect(Capabilities.canAny(AppRoles.admin, const []), isFalse);
      expect(Capabilities.canAll(AppRoles.admin, const []), isTrue);
    });
  });

  group('Capabilities.ofRol', () {
    test('ADMIN tiene set no vacío', () {
      expect(Capabilities.ofRol(AppRoles.admin), isNotEmpty);
    });

    test('CHOFER tiene set vacío (sin acceso a nada gateado)', () {
      expect(Capabilities.ofRol(AppRoles.chofer), isEmpty);
    });

    test('rol unknown → set vacío (mismo fallback que CHOFER)', () {
      expect(Capabilities.ofRol('NO_EXISTE'), isEmpty);
    });
  });
}
