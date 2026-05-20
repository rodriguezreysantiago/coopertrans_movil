import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/shared/utils/phone_formatter.dart';

void main() {
  group('PhoneFormatter.paraGuardar', () {
    test('número local de 10 dígitos le agrega 549', () {
      expect(PhoneFormatter.paraGuardar('2914567890'), '5492914567890');
    });

    test('ya canónico (549...) lo deja igual', () {
      expect(PhoneFormatter.paraGuardar('5492914567890'), '5492914567890');
    });

    test('formato con +, espacios y guiones se limpia', () {
      expect(PhoneFormatter.paraGuardar('+54 9 291 456-7890'),
          '5492914567890');
    });

    test('saca el 0 inicial de área (02914567890)', () {
      expect(PhoneFormatter.paraGuardar('02914567890'), '5492914567890');
    });

    test('saca el 15 móvil del formato viejo (0291 15-4567890)', () {
      expect(PhoneFormatter.paraGuardar('0291 15-4567890'), '5492914567890');
    });

    test('vino con 54 pero sin el 9 móvil → le mete el 9', () {
      expect(PhoneFormatter.paraGuardar('542914567890'), '5492914567890');
    });

    test('entradas inválidas devuelven vacío', () {
      expect(PhoneFormatter.paraGuardar(''), '');
      expect(PhoneFormatter.paraGuardar('-'), '');
      expect(PhoneFormatter.paraGuardar('abc'), '');
      expect(PhoneFormatter.paraGuardar(null), '');
    });

    test(
        'REGRESIÓN: número normal de 10 dígitos que CONTIENE "15" no se mutila',
        () {
      // Bug 2026-05-20: el teléfono de Errazu "no se guardaba" (decía
      // "guardado" pero quedaba vacío). El regex que saca el "15" móvil
      // matcheaba números legítimos de 10 dígitos donde el "15" caía en el
      // medio (ej. "2915456789" = área 291 + abonado 5456789), los recortaba
      // a 8 dígitos → quedaba corto → devolvía "". El guard `length == 12`
      // evita tocar los de 10 dígitos. Si esto vuelve a romper, el síntoma
      // es teléfonos que se borran solos al grabar.
      expect(PhoneFormatter.paraGuardar('2915456789'), '5492915456789');
      // Otro con "15" embebido en otra posición.
      expect(PhoneFormatter.paraGuardar('1156789015'), '5491156789015');
    });

    test('CABA (área 11) de 10 dígitos también funciona', () {
      expect(PhoneFormatter.paraGuardar('1155551234'), '5491155551234');
    });
  });

  group('PhoneFormatter.paraMostrar', () {
    test('canónico 549... se muestra local (sin 549)', () {
      expect(PhoneFormatter.paraMostrar('5492914567890'), '2914567890');
      expect(PhoneFormatter.paraMostrar('5491155551234'), '1155551234');
    });

    test('si ya estaba sin prefijo lo deja igual', () {
      expect(PhoneFormatter.paraMostrar('2914567890'), '2914567890');
    });

    test('vacío / guion / null → placeholder "-"', () {
      expect(PhoneFormatter.paraMostrar(''), '-');
      expect(PhoneFormatter.paraMostrar('-'), '-');
      expect(PhoneFormatter.paraMostrar(null), '-');
    });

    test('caso raro: 54 sin el 9 móvil saca solo el 54', () {
      expect(PhoneFormatter.paraMostrar('542914567890'), '2914567890');
    });
  });

  group('PhoneFormatter round-trip', () {
    test('guardar y luego mostrar devuelve el local original', () {
      for (final local in ['2914567890', '1155551234', '2915456789']) {
        final guardado = PhoneFormatter.paraGuardar(local);
        expect(PhoneFormatter.paraMostrar(guardado), local,
            reason: 'round-trip falló para $local');
      }
    });
  });
}
