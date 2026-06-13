// Tests de la lógica PURA de deep links (DeepLinkService): el mapeo de
// keyword de destino → ruta interna, y la extracción del destino desde la
// URI `…/app/ir/{destino}`. El stream/initial-link en sí necesita el canal
// de plataforma (no se testea acá).

import 'package:flutter_test/flutter_test.dart';
import 'package:coopertrans_movil/core/constants/app_constants.dart';
import 'package:coopertrans_movil/core/services/deep_link_service.dart';

void main() {
  group('rutaDeDestino', () {
    test('destinos del chofer mapean a sus rutas', () {
      expect(DeepLinkService.rutaDeDestino('jornada'), AppRoutes.miJornada);
      expect(DeepLinkService.rutaDeDestino('vencimientos'),
          AppRoutes.misVencimientos);
      expect(DeepLinkService.rutaDeDestino('equipo'), AppRoutes.equipo);
      expect(DeepLinkService.rutaDeDestino('perfil'), AppRoutes.perfil);
      expect(DeepLinkService.rutaDeDestino('home'), AppRoutes.home);
    });

    test('case-insensitive y tolera espacios', () {
      expect(DeepLinkService.rutaDeDestino('  JORNADA '), AppRoutes.miJornada);
      expect(DeepLinkService.rutaDeDestino('Vencimientos'),
          AppRoutes.misVencimientos);
    });

    test('compat con payloads de notificación local existentes', () {
      expect(DeepLinkService.rutaDeDestino('vencimiento'),
          AppRoutes.misVencimientos);
      expect(DeepLinkService.rutaDeDestino('admin_revision'),
          AppRoutes.adminRevisiones);
    });

    test('destino desconocido o null → null (no navega)', () {
      expect(DeepLinkService.rutaDeDestino('inventado'), isNull);
      expect(DeepLinkService.rutaDeDestino(''), isNull);
      expect(DeepLinkService.rutaDeDestino(null), isNull);
    });
  });

  group('destinoDeUri', () {
    Uri u(String s) => Uri.parse(s);

    test('extrae el destino de /app/ir/{destino}', () {
      expect(
          DeepLinkService.destinoDeUri(
              u('https://coopertrans-movil.web.app/app/ir/jornada')),
          'jornada');
      expect(
          DeepLinkService.destinoDeUri(
              u('https://coopertrans-movil.web.app/app/ir/vencimientos')),
          'vencimientos');
    });

    test('tolera query y fragment', () {
      expect(
          DeepLinkService.destinoDeUri(
              u('https://coopertrans-movil.web.app/app/ir/equipo?x=1#y')),
          'equipo');
    });

    test('URI sin la forma /app/ir/* → null', () {
      expect(
          DeepLinkService.destinoDeUri(
              u('https://coopertrans-movil.web.app/privacidad')),
          isNull);
      expect(
          DeepLinkService.destinoDeUri(
              u('https://coopertrans-movil.web.app/app/ir/')),
          isNull);
      expect(DeepLinkService.destinoDeUri(u('https://otro.com/app/ir/jornada')),
          'jornada'); // el host lo valida el OS via .well-known, no el parser
    });

    test('extremo a extremo: URI → destino → ruta', () {
      final ruta = DeepLinkService.rutaDeDestino(DeepLinkService.destinoDeUri(
          u('https://coopertrans-movil.web.app/app/ir/jornada')));
      expect(ruta, AppRoutes.miJornada);
    });
  });
}
