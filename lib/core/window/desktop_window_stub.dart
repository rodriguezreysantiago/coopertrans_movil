// REFACTOR NÚCLEO · Fase 5 · ventana desktop — stub web.
//
// En web no hay ventana nativa que configurar (y window_manager no se puede
// importar porque depende de dart:io). No-op: la title bar custom no aplica y
// la app se dibuja tal cual.
import 'package:flutter/widgets.dart';

Future<void> initDesktopWindow() async {}

Widget wrapDesktopChrome(Widget child) => child;
