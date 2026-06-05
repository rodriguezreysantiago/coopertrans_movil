import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/features/gomeria/constants/posiciones.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_instalada.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_marca.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_modelo.dart';
import 'package:coopertrans_movil/features/gomeria/models/cubierta_recapado.dart';

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

  group('EstadoCubierta.fromCodigo', () {
    test('parsea los 4 estados', () {
      expect(EstadoCubierta.fromCodigo('EN_DEPOSITO'),
          EstadoCubierta.enDeposito);
      expect(EstadoCubierta.fromCodigo('INSTALADA'),
          EstadoCubierta.instalada);
      expect(EstadoCubierta.fromCodigo('EN_RECAPADO'),
          EstadoCubierta.enRecapado);
      expect(EstadoCubierta.fromCodigo('DESCARTADA'),
          EstadoCubierta.descartada);
    });

    test('null o desconocido → null (el modelo aplica default)', () {
      expect(EstadoCubierta.fromCodigo(null), isNull);
      expect(EstadoCubierta.fromCodigo('FOO'), isNull);
    });
  });

  group('ResultadoRecapado.fromCodigo', () {
    test('parsea los 2 resultados', () {
      expect(ResultadoRecapado.fromCodigo('RECIBIDA'),
          ResultadoRecapado.recibida);
      expect(ResultadoRecapado.fromCodigo('DESCARTADA_POR_PROVEEDOR'),
          ResultadoRecapado.descartadaPorProveedor);
    });

    test('null mientras está en proceso', () {
      expect(ResultadoRecapado.fromCodigo(null), isNull);
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

    test('Cubierta: dos instancias con mismo id son iguales', () {
      final a = Cubierta.fromMap('id1', {'codigo': 'CUB-0001'});
      final b = Cubierta.fromMap('id1', {'codigo': 'CUB-0099'});
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

  // ===========================================================================
  // CUBIERTA — estado + puedeRecaparse + parsing defensivo
  // ===========================================================================
  group('Cubierta.puedeRecaparse', () {
    Cubierta crear(EstadoCubierta estado) => Cubierta(
          id: 'c1',
          codigo: 'CUB-0001',
          modeloId: 'mod1',
          modeloEtiqueta: 'Bridgestone R268',
          tipoUso: TipoUsoCubierta.direccion,
          estado: estado,
          vidas: 1,
          kmAcumulados: 0,
          observaciones: null,
          precioCompra: null,
          creadoEn: null,
        );

    test('EN_DEPOSITO → puede', () {
      expect(crear(EstadoCubierta.enDeposito).puedeRecaparse, isTrue);
    });

    test('INSTALADA → NO puede (debe retirarse al depósito antes)', () {
      // El service rechaza si no está EN_DEPOSITO; el flag tiene que
      // alinearse con eso para que la UI no ofrezca opciones que
      // después fallan al guardar (bug encontrado en testing).
      expect(crear(EstadoCubierta.instalada).puedeRecaparse, isFalse);
    });

    test('EN_RECAPADO → no puede (ya está allá)', () {
      expect(crear(EstadoCubierta.enRecapado).puedeRecaparse, isFalse);
    });

    test('DESCARTADA → no puede (fin de vida)', () {
      expect(crear(EstadoCubierta.descartada).puedeRecaparse, isFalse);
    });
  });

  group('Cubierta.fromMap', () {
    test('parsea todos los campos incluyendo precioCompra', () {
      final c = Cubierta.fromMap('c1', {
        'codigo': 'CUB-0042',
        'modelo_id': 'mod1',
        'modelo_etiqueta': 'Bridgestone R268 295/80R22.5 — Dirección',
        'tipo_uso': 'DIRECCION',
        'estado': 'INSTALADA',
        'vidas': 2,
        'km_acumulados': 87500.5,
        'observaciones': 'pinchazo en lateral',
        'precio_compra': 850000,
        'creado_en': Timestamp.fromDate(DateTime(2026, 1, 15)),
      });
      expect(c.codigo, 'CUB-0042');
      expect(c.tipoUso, TipoUsoCubierta.direccion);
      expect(c.estado, EstadoCubierta.instalada);
      expect(c.vidas, 2);
      expect(c.kmAcumulados, 87500.5);
      expect(c.observaciones, 'pinchazo en lateral');
      expect(c.precioCompra, 850000);
      expect(c.creadoEn, DateTime(2026, 1, 15));
    });

    test('data null → defaults sin romper', () {
      final c = Cubierta.fromMap('c1', null);
      expect(c.codigo, '');
      expect(c.estado, EstadoCubierta.enDeposito,
          reason: 'default razonable: una cubierta nueva está en depósito');
      expect(c.vidas, 1);
      expect(c.kmAcumulados, 0);
      expect(c.tipoUso, TipoUsoCubierta.traccion);
      expect(c.precioCompra, isNull);
    });

    test('campos numéricos como int → toDouble graceful', () {
      final c = Cubierta.fromMap('c1', {
        'codigo': 'CUB-0001',
        'km_acumulados': 50000, // int, no double
      });
      expect(c.kmAcumulados, 50000.0);
    });

    test('estado desconocido → fallback a EN_DEPOSITO', () {
      final c = Cubierta.fromMap('c1', {'estado': 'BASURA'});
      expect(c.estado, EstadoCubierta.enDeposito);
    });
  });

  // ===========================================================================
  // CUBIERTA_INSTALADA — esActiva + posicionTipada + duración + % vida
  // ===========================================================================
  CubiertaInstalada nuevaInstalada({
    DateTime? hasta,
    DateTime? desde,
    double? kmInst,
    double? kmRet,
    int? kmEsperados,
  }) =>
      CubiertaInstalada(
        id: 'i1',
        cubiertaId: 'c1',
        cubiertaCodigo: 'CUB-0001',
        unidadId: 'TR123',
        unidadTipo: TipoUnidadCubierta.tractor,
        posicion: 'DIR_IZQ',
        vidaAlInstalar: 1,
        modeloEtiqueta: null,
        kmVidaEstimadaAlInstalar: kmEsperados,
        desde: desde ?? DateTime(2026, 1, 1),
        hasta: hasta,
        kmUnidadAlInstalar: kmInst,
        kmUnidadAlRetirar: kmRet,
        kmRecorridos: null,
        instaladoPorDni: '111',
        instaladoPorNombre: 'Sup',
        retiradoPorDni: null,
        retiradoPorNombre: null,
        motivo: null,
        ultimaPresionPsi: null,
        ultimaProfundidadBandaMm: null,
        ultimaLecturaEn: null,
        ultimaLecturaPorDni: null,
        ultimaLecturaPorNombre: null,
      );

  group('CubiertaInstalada.esActiva', () {
    test('hasta == null → activa', () {
      expect(nuevaInstalada().esActiva, isTrue);
    });

    test('hasta != null → cerrada', () {
      expect(nuevaInstalada(hasta: DateTime(2026, 4, 1)).esActiva, isFalse);
    });
  });

  group('CubiertaInstalada.porcentajeVidaConsumida', () {
    test('km recorridos en vivo (50% del esperado)', () {
      final i = nuevaInstalada(kmInst: 100000, kmEsperados: 100000);
      expect(i.porcentajeVidaConsumida(kmActualUnidad: 150000), 50);
    });

    test('superó la vida estimada → > 100%', () {
      final i = nuevaInstalada(kmInst: 100000, kmEsperados: 80000);
      // 100000 km recorridos contra 80000 esperados = 125%
      expect(
        i.porcentajeVidaConsumida(kmActualUnidad: 200000),
        125,
      );
    });

    test('odómetro retrocedió → 0% (no negativo)', () {
      final i = nuevaInstalada(kmInst: 100000, kmEsperados: 80000);
      expect(i.porcentajeVidaConsumida(kmActualUnidad: 90000), 0);
    });

    test('sin km esperados → null', () {
      final i = nuevaInstalada(kmInst: 100000, kmEsperados: null);
      expect(i.porcentajeVidaConsumida(kmActualUnidad: 200000), isNull);
    });

    test('sin km de unidad ni de retiro → null', () {
      final i = nuevaInstalada(kmInst: 100000, kmEsperados: 80000);
      expect(i.porcentajeVidaConsumida(), isNull);
    });

    test('cerrada usa kmUnidadAlRetirar (no kmActualUnidad)', () {
      final i = nuevaInstalada(
        hasta: DateTime(2026, 6, 1),
        kmInst: 100000,
        kmRet: 180000,
        kmEsperados: 80000,
      );
      expect(i.porcentajeVidaConsumida(kmActualUnidad: 999999), 100);
    });
  });

  group('CubiertaInstalada.posicionTipada', () {
    test('posición tractor válida → resuelve correctamente', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'TR123',
        'unidad_tipo': 'TRACTOR',
        'posicion': 'DIR_IZQ',
        'desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(i.posicionTipada, posTractorDirIzq);
      expect(
          i.posicionTipada?.tipoUsoRequerido, TipoUsoCubierta.direccion);
    });

    test('posición enganche válida → resuelve correctamente', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'BAT456',
        'unidad_tipo': 'ENGANCHE',
        'posicion': 'ENG2_DER_INT',
        'desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(i.posicionTipada?.codigo, 'ENG2_DER_INT');
      expect(i.posicionTipada?.tipoUnidad, TipoUnidadCubierta.enganche);
      expect(i.posicionTipada?.eje, 2);
    });

    test('posición desconocida → null (no crashea)', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'TR123',
        'unidad_tipo': 'TRACTOR',
        'posicion': 'INEXISTENTE',
        'desde': Timestamp.fromDate(DateTime(2026, 1, 1)),
      });
      expect(i.posicionTipada, isNull);
    });
  });

  group('CubiertaInstalada.diasDuracion', () {
    test('instalación cerrada usa hasta', () {
      final i = nuevaInstalada(
        desde: DateTime(2026, 1, 1),
        hasta: DateTime(2026, 1, 31),
      );
      expect(i.diasDuracion(), 30);
    });

    test('instalación activa cuenta hasta ahora', () {
      final hace10 = DateTime.now().subtract(const Duration(days: 10));
      final i = nuevaInstalada(desde: hace10);
      expect(i.diasDuracion(), greaterThanOrEqualTo(9));
      expect(i.diasDuracion(), lessThanOrEqualTo(10));
    });
  });

  group('CubiertaInstalada.fromMap — defensas', () {
    test('unidad_tipo "ENGANCHE" → enum correcto', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'unidad_tipo': 'ENGANCHE',
        'cubierta_id': 'c1',
      });
      expect(i.unidadTipo, TipoUnidadCubierta.enganche);
    });

    test('unidad_tipo "TRACTOR" → enum correcto', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'unidad_tipo': 'TRACTOR',
        'cubierta_id': 'c1',
      });
      expect(i.unidadTipo, TipoUnidadCubierta.tractor);
    });

    test('unidad_tipo inválido → throw (no enmascarar errores)', () {
      // Antes el fromMap caía a "tractor" por default y enmascaraba
      // bugs de escritura. Ahora tira excepción explícita para que
      // surfacee el problema.
      expect(
        () => CubiertaInstalada.fromMap('i1', {
          'unidad_tipo': 'FOO',
          'cubierta_id': 'c1',
        }),
        throwsA(isA<StateError>()),
      );
    });

    test('parsea snapshot del modelo y lectura de control', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'TR123',
        'unidad_tipo': 'TRACTOR',
        'posicion': 'DIR_IZQ',
        'modelo_etiqueta': 'Bridgestone R268',
        'km_vida_estimada_al_instalar': 120000,
        'ultima_presion_psi': 105,
        'ultima_profundidad_banda_mm': 11.5,
      });
      expect(i.modeloEtiqueta, 'Bridgestone R268');
      expect(i.kmVidaEstimadaAlInstalar, 120000);
      expect(i.ultimaPresionPsi, 105);
      expect(i.ultimaProfundidadBandaMm, 11.5);
    });

    test('legacy_inicial true → flag = true', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'TR123',
        'unidad_tipo': 'TRACTOR',
        'posicion': 'DIR_IZQ',
        'desde': Timestamp.fromDate(DateTime(2026, 5, 8)),
        'legacy_inicial': true,
      });
      expect(i.legacyInicial, isTrue);
    });

    test('legacy_inicial ausente → flag = false (default)', () {
      final i = CubiertaInstalada.fromMap('i1', {
        'cubierta_id': 'c1',
        'unidad_id': 'TR123',
        'unidad_tipo': 'TRACTOR',
        'posicion': 'DIR_IZQ',
        'desde': Timestamp.fromDate(DateTime(2026, 5, 8)),
      });
      expect(i.legacyInicial, isFalse);
    });
  });

  // ===========================================================================
  // CUBIERTA_RECAPADO — enProceso + diasEnRecapado + parsing
  // ===========================================================================
  group('CubiertaRecapado.enProceso', () {
    test('fechaRetorno == null → en proceso', () {
      final r = CubiertaRecapado(
        id: 'r1',
        cubiertaId: 'c1',
        cubiertaCodigo: 'CUB-0001',
        vidaRecapado: 2,
        proveedor: 'Recauchutados Sur',
        fechaEnvio: DateTime(2026, 4, 1),
        fechaRetorno: null,
        costo: null,
        resultado: null,
        notas: null,
        enviadoPorDni: '111',
        enviadoPorNombre: 'Sup',
        cerradoPorDni: null,
        cerradoPorNombre: null,
      );
      expect(r.enProceso, isTrue);
    });

    test('fechaRetorno != null → cerrado', () {
      final r = CubiertaRecapado(
        id: 'r1',
        cubiertaId: 'c1',
        cubiertaCodigo: 'CUB-0001',
        vidaRecapado: 2,
        proveedor: 'Recauchutados Sur',
        fechaEnvio: DateTime(2026, 4, 1),
        fechaRetorno: DateTime(2026, 4, 20),
        costo: 45000,
        resultado: ResultadoRecapado.recibida,
        notas: 'OK',
        enviadoPorDni: '111',
        enviadoPorNombre: 'Sup',
        cerradoPorDni: '111',
        cerradoPorNombre: 'Sup',
      );
      expect(r.enProceso, isFalse);
    });
  });

  group('CubiertaRecapado.diasEnRecapado', () {
    test('cerrado usa fechaRetorno', () {
      final r = CubiertaRecapado(
        id: 'r1',
        cubiertaId: 'c1',
        cubiertaCodigo: 'CUB-0001',
        vidaRecapado: 2,
        proveedor: 'X',
        fechaEnvio: DateTime(2026, 4, 1),
        fechaRetorno: DateTime(2026, 4, 21),
        costo: null,
        resultado: ResultadoRecapado.recibida,
        notas: null,
        enviadoPorDni: '111',
        enviadoPorNombre: null,
        cerradoPorDni: '111',
        cerradoPorNombre: null,
      );
      expect(r.diasEnRecapado(), 20);
    });
  });
}
