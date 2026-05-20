import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/shared/utils/formatters.dart';

void main() {
  group('AppFormatters.tryParseFecha', () {
    test('null devuelve null', () {
      expect(AppFormatters.tryParseFecha(null), isNull);
    });

    test('string vacío devuelve null', () {
      expect(AppFormatters.tryParseFecha(''), isNull);
    });

    test('"---" (placeholder de campo no cargado) devuelve null', () {
      expect(AppFormatters.tryParseFecha('---'), isNull);
    });

    test('"nan" devuelve null', () {
      expect(AppFormatters.tryParseFecha('nan'), isNull);
    });

    test('string basura devuelve null (no rolea a 1970 ni a sentinel)', () {
      // Regression: antes "abc" hacía que calcularDiasRestantes devolviera
      // 999 y el badge se pintaba verde "OK" silenciando la alarma.
      expect(AppFormatters.tryParseFecha('abc'), isNull);
      expect(AppFormatters.tryParseFecha('hola mundo'), isNull);
      expect(AppFormatters.tryParseFecha('xx-yy-zzzz'), isNull);
    });

    test('formato ISO YYYY-MM-DD construye DateTime local sin desfase TZ', () {
      final r = AppFormatters.tryParseFecha('2026-05-30');
      expect(r, isNotNull);
      expect(r!.year, 2026);
      expect(r.month, 5);
      expect(r.day, 30);
      // El bug histórico: DateTime.tryParse('2026-05-30') devolvía UTC
      // midnight, que en ART (UTC-3) al convertir a local quedaba 29/05.
      // Verificamos que es local explícito.
      expect(r.isUtc, isFalse);
    });

    test('formato DD/MM/YYYY parsea correcto', () {
      final r = AppFormatters.tryParseFecha('30/05/2026');
      expect(r, isNotNull);
      expect(r!.year, 2026);
      expect(r.month, 5);
      expect(r.day, 30);
    });

    test('formato DD-MM-YYYY parsea correcto', () {
      final r = AppFormatters.tryParseFecha('30-05-2026');
      expect(r, isNotNull);
      expect(r!.year, 2026);
      expect(r.month, 5);
      expect(r.day, 30);
    });

    test('DateTime nativo se devuelve tal cual', () {
      final dt = DateTime(2026, 5, 30, 14, 30);
      final r = AppFormatters.tryParseFecha(dt);
      expect(r, equals(dt));
    });

    test('string ISO con T y Z (timestamp completo) extrae solo la fecha', () {
      final r = AppFormatters.tryParseFecha('2026-05-30T14:30:00Z');
      expect(r, isNotNull);
      expect(r!.year, 2026);
      expect(r.month, 5);
      expect(r.day, 30);
    });
  });

  group('AppFormatters.calcularDiasRestantes', () {
    test('null devuelve null (no 999, no sentinel)', () {
      // Regression: antes devolvía 999. Eso lo interpretaba el badge
      // como "lejos en el futuro" → estado OK verde.
      expect(AppFormatters.calcularDiasRestantes(null), isNull);
    });

    test('vacío devuelve null', () {
      expect(AppFormatters.calcularDiasRestantes(''), isNull);
    });

    test('string corrupto devuelve null (no silencia alarma)', () {
      // Regression del bug crítico: una fecha tipeada mal en consola
      // de Firebase quedaba como 999 días → badge verde → admin no se
      // entera de que el dato está roto.
      expect(AppFormatters.calcularDiasRestantes('abc'), isNull);
      expect(AppFormatters.calcularDiasRestantes('XXXX-XX-XX'), isNull);
    });

    test('fecha de hoy devuelve 0', () {
      final hoy = DateTime.now();
      final hoyStr =
          '${hoy.year}-${hoy.month.toString().padLeft(2, '0')}-${hoy.day.toString().padLeft(2, '0')}';
      expect(AppFormatters.calcularDiasRestantes(hoyStr), 0);
    });

    test('fecha de mañana devuelve 1', () {
      final manana = DateTime.now().add(const Duration(days: 1));
      final mananaStr =
          '${manana.year}-${manana.month.toString().padLeft(2, '0')}-${manana.day.toString().padLeft(2, '0')}';
      expect(AppFormatters.calcularDiasRestantes(mananaStr), 1);
    });

    test('fecha de ayer devuelve -1', () {
      final ayer = DateTime.now().subtract(const Duration(days: 1));
      final ayerStr =
          '${ayer.year}-${ayer.month.toString().padLeft(2, '0')}-${ayer.day.toString().padLeft(2, '0')}';
      expect(AppFormatters.calcularDiasRestantes(ayerStr), -1);
    });
  });

  group('AppFormatters.aIsoFechaLocal', () {
    test('DateTime local devuelve YYYY-MM-DD con componentes locales', () {
      final dt = DateTime(2026, 5, 30, 14, 30);
      expect(AppFormatters.aIsoFechaLocal(dt), '2026-05-30');
    });

    test('DateTime UTC se convierte a local antes de extraer componentes', () {
      // 2026-05-30 02:00 UTC = 2026-05-29 23:00 ART (UTC-3).
      // El método debe devolver el día LOCAL, no UTC.
      // Si la máquina que corre el test no está en ART, el test sigue
      // sirviendo: verifica que .toLocal() se aplica antes de formatear.
      final utc = DateTime.utc(2026, 5, 30, 2, 0);
      final local = utc.toLocal();
      final esperado =
          '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
      expect(AppFormatters.aIsoFechaLocal(utc), esperado);
    });

    test('día y mes con un dígito se padean a 2 dígitos', () {
      final dt = DateTime(2026, 1, 5);
      expect(AppFormatters.aIsoFechaLocal(dt), '2026-01-05');
    });
  });

  group('AppFormatters.formatearDNI', () {
    test('DNI de 8 dígitos formatea XX.XXX.XXX', () {
      expect(AppFormatters.formatearDNI('29820141'), '29.820.141');
    });

    test('DNI de 7 dígitos formatea X.XXX.XXX', () {
      expect(AppFormatters.formatearDNI('9820141'), '9.820.141');
    });

    test('DNI con guiones/espacios se limpia antes de formatear', () {
      expect(AppFormatters.formatearDNI('29.820.141'), '29.820.141');
      expect(AppFormatters.formatearDNI('29 820 141'), '29.820.141');
    });

    test('null o vacío devuelve cadena vacía', () {
      expect(AppFormatters.formatearDNI(null), '');
      expect(AppFormatters.formatearDNI(''), '');
    });
  });

  // ===========================================================================
  // FORMATEO DE NÚMEROS GRANDES (formato AR: 123.456.789 / 123.456.789,00)
  // ===========================================================================
  group('AppFormatters.formatearMiles', () {
    test('enteros chicos sin separador (< 1000)', () {
      expect(AppFormatters.formatearMiles(0), '0');
      expect(AppFormatters.formatearMiles(1), '1');
      expect(AppFormatters.formatearMiles(999), '999');
    });

    test('enteros con separador AR (.)', () {
      expect(AppFormatters.formatearMiles(1000), '1.000');
      expect(AppFormatters.formatearMiles(45000), '45.000');
      expect(AppFormatters.formatearMiles(200000), '200.000');
      expect(AppFormatters.formatearMiles(123456789), '123.456.789');
    });

    test('negativos', () {
      expect(AppFormatters.formatearMiles(-1500), '-1.500');
    });

    test('decimales se truncan por defecto (sin parámetro)', () {
      expect(AppFormatters.formatearMiles(1234.99), '1.234');
    });

    test('con decimales: usa coma AR', () {
      expect(AppFormatters.formatearMiles(45000, decimales: 2), '45.000,00');
      expect(AppFormatters.formatearMiles(45000.5, decimales: 2), '45.000,50');
      expect(AppFormatters.formatearMiles(123456789.99, decimales: 2),
          '123.456.789,99');
    });

    test('null devuelve placeholder', () {
      expect(AppFormatters.formatearMiles(null), '—');
    });
  });

  group('AppFormatters.formatearMonto', () {
    test('formato AR completo con ,00 forzado', () {
      expect(AppFormatters.formatearMonto(45000), '45.000,00');
      expect(AppFormatters.formatearMonto(0), '0,00');
      expect(AppFormatters.formatearMonto(123456789.5), '123.456.789,50');
    });

    test('null devuelve placeholder', () {
      expect(AppFormatters.formatearMonto(null), '—');
    });
  });

  group('AppFormatters.parsearMiles', () {
    test('parsea string formateado AR', () {
      expect(AppFormatters.parsearMiles('200.000'), 200000);
      expect(AppFormatters.parsearMiles('123.456.789'), 123456789);
    });

    test('parsea string crudo sin separadores', () {
      expect(AppFormatters.parsearMiles('200000'), 200000);
    });

    test('null o vacío devuelve null', () {
      expect(AppFormatters.parsearMiles(null), isNull);
      expect(AppFormatters.parsearMiles(''), isNull);
      expect(AppFormatters.parsearMiles('   '), isNull);
    });

    test('roundtrip formatear → parsear preserva valor', () {
      for (final v in [0, 1, 999, 1000, 45000, 200000, 123456789]) {
        final str = AppFormatters.formatearMiles(v);
        expect(AppFormatters.parsearMiles(str), v,
            reason: 'roundtrip de $v');
      }
    });
  });

  group('AppFormatters.parsearMonto (decimales AR)', () {
    test('parsea monto con miles y decimales', () {
      expect(AppFormatters.parsearMonto('123.456,50'), 123456.5);
      expect(AppFormatters.parsearMonto('45.000,00'), 45000.0);
      expect(AppFormatters.parsearMonto('123.456.789,00'), 123456789.0);
    });

    test('acepta entero sin coma y crudo', () {
      expect(AppFormatters.parsearMonto('123.456'), 123456.0);
      expect(AppFormatters.parsearMonto('123456,5'), 123456.5);
      expect(AppFormatters.parsearMonto('0,50'), 0.5);
    });

    test('null / vacío devuelve null', () {
      expect(AppFormatters.parsearMonto(null), isNull);
      expect(AppFormatters.parsearMonto(''), isNull);
      expect(AppFormatters.parsearMonto('   '), isNull);
    });

    test('roundtrip formatearMonto → parsearMonto preserva valor', () {
      for (final v in [0.0, 1.0, 999.99, 45000.0, 123456.5, 200000.05]) {
        final str = AppFormatters.formatearMonto(v);
        expect(AppFormatters.parsearMonto(str), closeTo(v, 0.001),
            reason: 'roundtrip de $v (formateado "$str")');
      }
    });
  });

  group('AppFormatters.inputMilesDecimal (formatter en vivo)', () {
    String fmt(String input) {
      final r = AppFormatters.inputMilesDecimal.formatEditUpdate(
        const TextEditingValue(text: ''),
        TextEditingValue(
          text: input,
          selection: TextSelection.collapsed(offset: input.length),
        ),
      );
      return r.text;
    }

    test('agrega separador de miles a la parte entera', () {
      expect(fmt('123456789'), '123.456.789');
      expect(fmt('1000'), '1.000');
    });

    test('mantiene la coma decimal (hasta 2 dígitos)', () {
      expect(fmt('123456789,5'), '123.456.789,5');
      expect(fmt('1000000,00'), '1.000.000,00');
    });

    test('corta a 2 decimales y descarta comas extra', () {
      expect(fmt('1234,567'), '1.234,56');
      expect(fmt('12,34,56'), '12,34');
    });

    test('descarta caracteres no numéricos y vacío queda vacío', () {
      expect(fmt('abc'), '');
      expect(fmt(''), '');
      expect(fmt(r'$ 4.500,50'), '4.500,50');
    });
  });
}
