import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/constants/posiciones.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_marca.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_modelo.dart';

/// Tests del módulo Gomería — modelos data + constantes de posiciones.
///
/// Foco crítico: la validación tipo_uso vs posición (decisión confirmada
/// por Santiago: "que no le permita, sería un error de tipeo seguramente"),
/// el cálculo de km_esperados según vidas, los parsers defensivos
/// (Firestore puede devolver datos parciales sin que la app crashee), y
/// el cálculo de % de vida útil consumida en vivo.
void main() {
  // ===========================================================================
  // POSICIONES — layout fijo + validación estricta tipo_uso
  // ===========================================================================
  group('PosicionCubierta — layout fijo', () {
    test('tractor tiene exactamente 10 posiciones', () {
      expect(posicionesTractor.length, 10);
    });

    test('enganche tiene exactamente 12 posiciones (3 ejes × 4 ruedas)', () {
      expect(posicionesEnganche.length, 12);
    });

    test('todas las posiciones tienen códigos únicos', () {
      final codigos = [
        ...posicionesTractor.map((p) => p.codigo),
        ...posicionesEnganche.map((p) => p.codigo),
      ];
      expect(codigos.toSet().length, codigos.length,
          reason: 'no debe haber códigos duplicados entre tractor y enganche');
    });

    test('tractor: 2 DIRECCION, 4 TRACCION (motriz), 4 ARRASTRE (neumático)', () {
      final dir = posicionesTractor
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.direccion)
          .length;
      final trac = posicionesTractor
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.traccion)
          .length;
      final arr = posicionesTractor
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.arrastre)
          .length;
      expect(dir, 2);
      expect(trac, 4); // solo el eje motriz (TRAC1)
      expect(arr, 4); // el eje neumático (TRAC2) es libre → arrastre (fix 2026-06-05)
    });

    test('eje neumático del tractor (TRAC2) acepta ARRASTRE, no tracción', () {
      expect(posTractorTrac2IzqExt.tipoUsoRequerido, TipoUsoCubierta.arrastre);
      expect(posTractorTrac2IzqExt.aceptaTipoUso(TipoUsoCubierta.arrastre), isTrue);
      expect(posTractorTrac2IzqExt.aceptaTipoUso(TipoUsoCubierta.traccion), isFalse);
    });

    test('enganche: 0 DIRECCION, 0 TRACCION, 12 ARRASTRE', () {
      // Los ejes del enganche son libres (de arrastre): ni dirección ni
      // tracción. Antes estaban como TRACCIÓN por falta del tipo ARRASTRE.
      final dir = posicionesEnganche
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.direccion)
          .length;
      final trac = posicionesEnganche
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.traccion)
          .length;
      final arr = posicionesEnganche
          .where((p) => p.tipoUsoRequerido == TipoUsoCubierta.arrastre)
          .length;
      expect(dir, 0);
      expect(trac, 0);
      expect(arr, 12);
    });

    test('todas las posiciones de enganche son del mismo tipoUnidad', () {
      for (final p in posicionesEnganche) {
        expect(p.tipoUnidad, TipoUnidadCubierta.enganche);
      }
    });

    test('todas las posiciones de tractor son del mismo tipoUnidad', () {
      for (final p in posicionesTractor) {
        expect(p.tipoUnidad, TipoUnidadCubierta.tractor);
      }
    });

    test('posicionPorCodigo resuelve códigos válidos', () {
      expect(posicionPorCodigo['DIR_IZQ'], posTractorDirIzq);
      expect(posicionPorCodigo['TRAC1_DER_EXT'], posTractorTrac1DerExt);
      expect(posicionPorCodigo['ENG1_IZQ_EXT']?.tipoUnidad,
          TipoUnidadCubierta.enganche);
      expect(posicionPorCodigo['ENG3_DER_INT']?.eje, 3);
    });

    test('posicionPorCodigo devuelve null si no existe', () {
      expect(posicionPorCodigo['INEXISTENTE'], isNull);
      expect(posicionPorCodigo[''], isNull);
    });

    test('posicionesParaUnidad devuelve la lista correcta', () {
      expect(posicionesParaUnidad(TipoUnidadCubierta.tractor),
          posicionesTractor);
      expect(posicionesParaUnidad(TipoUnidadCubierta.enganche),
          posicionesEnganche);
    });
  });

  group('PosicionCubierta.aceptaTipoUso — validación ESTRICTA', () {
    test('cubierta DIRECCION en posición DIRECCION → OK', () {
      expect(posTractorDirIzq.aceptaTipoUso(TipoUsoCubierta.direccion), isTrue);
    });

    test('cubierta TRACCION en posición DIRECCION → RECHAZA', () {
      // Esta es LA regla crítica. Santiago: "es un error de tipeo seguramente,
      // es imposible que salga con una de tracción en la dirección".
      expect(posTractorDirIzq.aceptaTipoUso(TipoUsoCubierta.traccion), isFalse);
    });

    test('cubierta DIRECCION en posición TRACCION → RECHAZA', () {
      expect(posTractorTrac1IzqExt.aceptaTipoUso(TipoUsoCubierta.direccion),
          isFalse);
    });

    test('cubierta TRACCION en posición TRACCION del tractor → OK', () {
      expect(posTractorTrac1IzqExt.aceptaTipoUso(TipoUsoCubierta.traccion),
          isTrue);
    });

    test('enganche: recapadas SOLO en el primer eje (ejes 2 y 3 solo nuevas)',
        () {
      final eje1 = posicionesEnganche.where((p) => p.eje == 1);
      final ejes23 = posicionesEnganche.where((p) => p.eje != 1);
      expect(eje1.isNotEmpty, isTrue);
      expect(eje1.every((p) => p.permiteRecapada), isTrue,
          reason: 'el primer eje del enganche admite recapadas');
      expect(ejes23.every((p) => !p.permiteRecapada), isTrue,
          reason: 'los ejes 2 y 3 del enganche solo admiten nuevas');
    });

    test('tractor: recapadas SOLO en el eje neumático (dir y tracción nuevas)',
        () {
      // Eje 3 = neumático (libre) → admite recapadas. Ejes 1 (dirección) y 2
      // (tracción/motriz) → solo nuevas (ejes críticos, seguridad).
      final neumatico = posicionesTractor.where((p) => p.eje == 3);
      final dirYTrac = posicionesTractor.where((p) => p.eje != 3);
      expect(neumatico.every((p) => p.permiteRecapada), isTrue,
          reason: 'el eje neumático admite recapadas');
      expect(dirYTrac.every((p) => !p.permiteRecapada), isTrue,
          reason: 'dirección y tracción solo nuevas');
    });

    test('posición de enganche acepta SOLO ARRASTRE (no traccion ni direccion)',
        () {
      final pEng = posicionesEnganche.first;
      expect(pEng.tipoUsoRequerido, TipoUsoCubierta.arrastre);
      expect(pEng.aceptaTipoUso(TipoUsoCubierta.arrastre), isTrue);
      expect(pEng.aceptaTipoUso(TipoUsoCubierta.traccion), isFalse);
      expect(pEng.aceptaTipoUso(TipoUsoCubierta.direccion), isFalse);
    });

    test('cubierta ARRASTRE en posición de tractor → RECHAZA', () {
      // Una cubierta de arrastre no entra ni en dirección ni en tracción.
      expect(posTractorTrac1IzqExt.aceptaTipoUso(TipoUsoCubierta.arrastre),
          isFalse);
      expect(posTractorDirIzq.aceptaTipoUso(TipoUsoCubierta.arrastre), isFalse);
    });
  });

  group('TipoUsoCubierta.fromCodigo', () {
    test('parsea códigos válidos', () {
      expect(TipoUsoCubierta.fromCodigo('DIRECCION'),
          TipoUsoCubierta.direccion);
      expect(TipoUsoCubierta.fromCodigo('TRACCION'),
          TipoUsoCubierta.traccion);
      expect(TipoUsoCubierta.fromCodigo('ARRASTRE'),
          TipoUsoCubierta.arrastre);
    });

    test('case-insensitive y trimmed', () {
      expect(TipoUsoCubierta.fromCodigo('  direccion  '),
          TipoUsoCubierta.direccion);
      expect(TipoUsoCubierta.fromCodigo('Traccion'),
          TipoUsoCubierta.traccion);
    });

    test('null o desconocido → null', () {
      expect(TipoUsoCubierta.fromCodigo(null), isNull);
      expect(TipoUsoCubierta.fromCodigo('OTRO'), isNull);
      expect(TipoUsoCubierta.fromCodigo(''), isNull);
    });
  });

  // ===========================================================================
  // CUBIERTA_MARCA — modelo simple
  // ===========================================================================
  // Equality por id — sin esto, los DropdownButtonFormField en los
  // diálogos pierden la selección entre rebuilds del StreamBuilder.
  // Bug encontrado en producción 2026-05-04 (Santiago no podía guardar
  // un modelo porque el dropdown de marca se "des-seleccionaba" al
  // refrescar el snapshot).
  group('Equality por id (anti-regresión dropdown bug)', () {
    test('CubiertaMarca: dos instancias con mismo id son iguales', () {
      final a = CubiertaMarca.fromMap('id1', {'nombre': 'Bridgestone'});
      final b = CubiertaMarca.fromMap('id1', {'nombre': 'Bridgestone'});
      expect(identical(a, b), isFalse, reason: 'son instancias distintas');
      expect(a == b, isTrue, reason: 'pero deben ser equals por id');
      expect(a.hashCode, b.hashCode);
    });

    test('CubiertaMarca: distinto id → no iguales', () {
      final a = CubiertaMarca.fromMap('id1', {'nombre': 'X'});
      final b = CubiertaMarca.fromMap('id2', {'nombre': 'X'});
      expect(a == b, isFalse);
    });

    test('CubiertaModelo: dos instancias con mismo id son iguales', () {
      final a = CubiertaModelo.fromMap('id1', {'modelo': 'R268'});
      final b = CubiertaModelo.fromMap('id1', {'modelo': 'OTRO'});
      expect(a == b, isTrue);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('CubiertaMarca.fromMap', () {
    test('parsea correctamente', () {
      final m = CubiertaMarca.fromMap('marcaA', {
        'nombre': 'Bridgestone',
        'activo': true,
      });
      expect(m.id, 'marcaA');
      expect(m.nombre, 'Bridgestone');
      expect(m.activo, isTrue);
    });

    test('data null → defaults sin romper', () {
      final m = CubiertaMarca.fromMap('marcaB', null);
      expect(m.nombre, '');
      expect(m.activo, isTrue, reason: 'default activo=true');
    });

    test('campo activo no-bool → fallback a true', () {
      final m = CubiertaMarca.fromMap('x', {'nombre': 'X', 'activo': 'sí'});
      expect(m.activo, isTrue);
    });
  });

  // ===========================================================================
  // CUBIERTA_MODELO — km_esperados + recapable + etiqueta
  // ===========================================================================
  group('CubiertaModelo.kmEsperadosParaVida', () {
    const modelo = CubiertaModelo(
      id: 'mod1',
      marcaId: 'marca1',
      marcaNombre: 'Bridgestone',
      modelo: 'R268',
      medida: '295/80R22.5',
      tipoUso: TipoUsoCubierta.direccion,
      kmVidaEstimadaNueva: 120000,
      kmVidaEstimadaRecapada: 60000,
      recapable: true,
      presionRecomendadaPsi: null,
      profundidadBandaMinimaMm: null,
      activo: true,
    );

    test('vida 1 (nueva) → km_vida_estimada_nueva', () {
      expect(modelo.kmEsperadosParaVida(1), 120000);
    });

    test('vida 2+ (recapada) → km_vida_estimada_recapada', () {
      expect(modelo.kmEsperadosParaVida(2), 60000);
      expect(modelo.kmEsperadosParaVida(3), 60000);
    });

    test('vida 0 o negativa (corrupción) → trata como nueva', () {
      expect(modelo.kmEsperadosParaVida(0), 120000);
      expect(modelo.kmEsperadosParaVida(-1), 120000);
    });

    test('si km_recapada es null (no recapable) → null en vida 2+', () {
      const noRecapable = CubiertaModelo(
        id: 'mod2',
        marcaId: 'marca2',
        marcaNombre: 'GenericaChina',
        modelo: 'XYZ',
        medida: '11R22.5',
        tipoUso: TipoUsoCubierta.traccion,
        kmVidaEstimadaNueva: 50000,
        kmVidaEstimadaRecapada: null,
        recapable: false,
        presionRecomendadaPsi: null,
        profundidadBandaMinimaMm: null,
        activo: true,
      );
      expect(noRecapable.kmEsperadosParaVida(1), 50000);
      expect(noRecapable.kmEsperadosParaVida(2), isNull);
    });
  });

  group('CubiertaModelo.etiqueta', () {
    test('formato compacto para listados', () {
      const m = CubiertaModelo(
        id: 'mod1',
        marcaId: 'marca1',
        marcaNombre: 'Bridgestone',
        modelo: 'R268',
        medida: '295/80R22.5',
        tipoUso: TipoUsoCubierta.direccion,
        kmVidaEstimadaNueva: 120000,
        kmVidaEstimadaRecapada: 60000,
        recapable: true,
        presionRecomendadaPsi: null,
        profundidadBandaMinimaMm: null,
        activo: true,
      );
      expect(m.etiqueta, 'Bridgestone R268 295/80R22.5 — Dirección');
    });
  });

  group('CubiertaModelo.fromMap', () {
    test('parsea todos los campos incluyendo presión y banda', () {
      final m = CubiertaModelo.fromMap('mod1', {
        'marca_id': 'marca1',
        'marca_nombre': 'Bridgestone',
        'modelo': 'R268',
        'medida': '295/80R22.5',
        'tipo_uso': 'DIRECCION',
        'km_vida_estimada_nueva': 120000,
        'km_vida_estimada_recapada': 60000,
        'recapable': true,
        'presion_recomendada_psi': 110,
        'profundidad_banda_minima_mm': 3.0,
        'activo': true,
      });
      expect(m.id, 'mod1');
      expect(m.tipoUso, TipoUsoCubierta.direccion);
      expect(m.kmVidaEstimadaNueva, 120000);
      expect(m.kmVidaEstimadaRecapada, 60000);
      expect(m.recapable, isTrue);
      expect(m.presionRecomendadaPsi, 110);
      expect(m.profundidadBandaMinimaMm, 3.0);
    });

    test('data null → defaults sin romper', () {
      final m = CubiertaModelo.fromMap('x', null);
      expect(m.marcaNombre, '');
      expect(m.tipoUso, TipoUsoCubierta.traccion,
          reason: 'fallback más conservador (mayoría de posiciones son traccion)');
      expect(m.recapable, isFalse);
      expect(m.activo, isTrue);
      expect(m.kmVidaEstimadaNueva, isNull);
      expect(m.presionRecomendadaPsi, isNull);
      expect(m.profundidadBandaMinimaMm, isNull);
    });

    test('km_vida_estimada como double → toInt()', () {
      final m = CubiertaModelo.fromMap('x', {
        'km_vida_estimada_nueva': 120000.5,
      });
      expect(m.kmVidaEstimadaNueva, 120000);
    });
  });

  group('CubiertaModelo.toMap → fromMap roundtrip', () {
    test('preserva todos los campos relevantes', () {
      const original = CubiertaModelo(
        id: 'mod1',
        marcaId: 'marca1',
        marcaNombre: 'Pirelli',
        modelo: 'FR01',
        medida: '11R22.5',
        tipoUso: TipoUsoCubierta.traccion,
        kmVidaEstimadaNueva: 100000,
        kmVidaEstimadaRecapada: 45000,
        recapable: true,
        presionRecomendadaPsi: 105,
        profundidadBandaMinimaMm: 4.0,
        activo: false,
      );
      final reparsed = CubiertaModelo.fromMap(original.id, original.toMap());
      expect(reparsed.marcaId, original.marcaId);
      expect(reparsed.marcaNombre, original.marcaNombre);
      expect(reparsed.modelo, original.modelo);
      expect(reparsed.medida, original.medida);
      expect(reparsed.tipoUso, original.tipoUso);
      expect(reparsed.kmVidaEstimadaNueva, original.kmVidaEstimadaNueva);
      expect(reparsed.kmVidaEstimadaRecapada, original.kmVidaEstimadaRecapada);
      expect(reparsed.recapable, original.recapable);
      expect(reparsed.presionRecomendadaPsi, original.presionRecomendadaPsi);
      expect(reparsed.profundidadBandaMinimaMm,
          original.profundidadBandaMinimaMm);
      expect(reparsed.activo, original.activo);
    });
  });

}
