#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

// --- ESTA ES LA LÍNEA QUE ARREGLA EL ERROR ---
extern "C" { int _Avx2WmemEnabled = 0; }
// ---------------------------------------------

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  
  // Usar escape Unicode ó (= 'o' acentuada) para evitar el bug de
  // encoding cuando MSVC interpreta el .cpp UTF-8 como Latin-1. Sin
  // esto, "Movil" en la barra de Windows aparece como "MA(c)vil".
  // Escape Unicode \u00F3 = '\u00F3' acentuada \u2014 sin esto MSVC interpreta
  // el .cpp UTF-8 como Latin-1 y "Movil" sale como "MA(c)vil".
  // La versi\u00F3n va en el t\u00EDtulo para que admin/operador pueda
  // verificar de un vistazo qu\u00E9 binario est\u00E1 corriendo. Usar guion
  // ASCII en lugar de em-dash por el mismo motivo de encoding.
  // Mantener sincronizada con pubspec.yaml \u2014 `scripts/bump_version.ps1`
  // actualiza los 3 lugares (pubspec, app_constants, main.cpp).
  if (!window.Create(L"Coopertrans Móvil — v 1.0.68 (build 71)", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}















































