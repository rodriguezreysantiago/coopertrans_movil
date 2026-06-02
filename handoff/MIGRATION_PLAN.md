# Migration Plan — Refactor Núcleo

> Plan operativo de 12 días-persona. Cada fase termina con commit + verificación en los 5 targets.

## Fase 1 · Theme engine — 1 día

### Dependencias
- [ ] `pubspec.yaml`: agregar `google_fonts: ^6.2.1`
- [ ] `pubspec.yaml`: agregar `window_manager: ^0.4.2` (solo si querés title bar custom en desktop)
- [ ] `flutter pub get`

### Archivos

> Los paths de este zip son espejo del codebase. **Reemplazar contenido in-place,
> NO mover.** Ver `FILE_MAP.md` para la tabla autoritativa.

- [ ] `handoff/lib/shared/constants/app_colors.dart` → reemplazar contenido en `lib/shared/constants/app_colors.dart` (mismo path)
- [ ] `handoff/lib/core/theme/app_typography.dart` → reemplazar contenido en `lib/core/theme/app_typography.dart`
- [ ] `handoff/lib/core/theme/app_spacing.dart` → reemplazar contenido
- [ ] `handoff/lib/core/theme/app_radius.dart` → ⊕ crear nuevo en `lib/core/theme/app_radius.dart`
- [ ] `handoff/lib/core/theme/app_shadows.dart` → ⊕ crear nuevo
- [ ] `handoff/lib/core/theme/app_theme.dart` → reemplazar contenido
- [ ] `handoff/lib/core/theme/platform_chrome.dart` → ⊕ crear nuevo

### Wire-up
- [ ] `lib/main.dart`:
  ```dart
  void main() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp(...);
    await PlatformChrome.apply(Brightness.dark); // default cabina
    // si querés desktop chrome custom: await _initDesktopWindow();
    runApp(const MyApp());
  }

  class MyApp extends StatelessWidget {
    @override
    Widget build(BuildContext context) {
      return MaterialApp(
        title: 'Coopertrans Móvil',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.dark,  // o ThemeMode.system para respetar SO
        ...
      );
    }
  }
  ```

### Verificación
- [ ] `flutter run -d chrome` carga sin warnings
- [ ] `flutter run -d <ios sim>` carga sin warnings
- [ ] El bg de la app es near-black (#050505), no azulado
- [ ] Las fuentes son Geist (verificable inspeccionando un Text widget)

---

## Fase 2 · Widgets base — 1 día

### Archivos
- [ ] `handoff/lib/shared/widgets/app_button.dart` → reemplazar contenido
- [ ] `handoff/lib/shared/widgets/app_card.dart` → reemplazar contenido
- [ ] `handoff/lib/shared/widgets/app_badge.dart` → ⊕ crear nuevo (NO renombrar `app_status_badge.dart`, ver FILE_MAP.md nota ①)
- [ ] `handoff/lib/shared/widgets/app_input.dart` → ⊕ crear nuevo
- [ ] `handoff/lib/shared/widgets/app_eyebrow.dart` → ⊕ crear nuevo
- [ ] `handoff/lib/shared/widgets/app_stat.dart` → ⊕ crear nuevo
- [ ] `handoff/lib/shared/widgets/app_ambient.dart` → ⊕ crear nuevo

### Barrel + deprecación incremental del badge viejo
- [ ] `lib/shared/widgets/app_widgets.dart`: agregar exports de los 5 archivos nuevos
- [ ] `lib/shared/widgets/app_status_badge.dart`: marcar la clase con `@Deprecated('Usar AppBadge — ver FILE_MAP.md')`
- [ ] **NO borrar `app_status_badge.dart` en esta fase** — se reemplazan los call-sites a medida que se migra cada feature folder en fase 4. Al cierre, si no quedan call-sites, se borra.

### Verificación
- [ ] `flutter analyze` sin errores
- [ ] La app sigue compilando

---

## Fase 3 · Pantallas críticas — 3 días

Cada pantalla se migra en este patrón:

1. Abrir el JSX correspondiente del prototipo (`nucleo/screens-mobile.jsx` o `screens-desktop-*.jsx`)
2. Identificar el árbol React → Flutter equivalente (`<div>` → `Container`, `<div style={{display:'flex'}}>` → `Row/Column`)
3. Reescribir el `build()` del screen
4. Reemplazar colores `Color(0xFF...)` literales por `context.colors.brand`, etc.
5. Reemplazar `TextStyle(fontSize:..)` literales por `AppType.h3`, etc.
6. Verificar en al menos 1 target mobile + 1 desktop

### 3.1 Login chofer · 0.5d
Ref: `nucleo/screens-mobile.jsx :: Login`
- [ ] `features/auth/screens/login_screen.dart`
- [ ] `AppAmbient` arriba; logo + hero "Buenas tardes" h1; 2 `AppInput` (DNI + Password); `AppButton.primary(full: true, iconAfter: Icons.arrow_forward)`
- [ ] Footer: v3.0.0 + `AppDot` ok + "sistemas ok"

### 3.2 Home chofer · 0.5d
Ref: `nucleo/screens-mobile.jsx :: Home`
- [ ] `features/home/screens/main_panel.dart`
- [ ] AppBar custom: AppLogo + AppDot badge + Avatar
- [ ] Greeting hero h1 "Hola Santi"
- [ ] Warning row clickable → expira_detail
- [ ] 2 tiles cuadrados (perfil + unidad) + 1 tile ancho (vencimientos)
- [ ] AppPrompt al fondo (versión sencilla, no funcional aún)

### 3.3 Admin dashboard · 1d
Ref: `nucleo/screens-desktop-core.jsx :: Dashboard`
- [ ] `features/admin_dashboard/screens/admin_panel_screen.dart`
- [ ] Top nav fija + live ticker
- [ ] Hero h1 + segmented "Hoy/7d/30d/90d"
- [ ] Bento 12 columnas: urgent card (8), AI assist card (4), KPI strip (12), chart (8), services (4)
- [ ] Chart: usar `fl_chart` envuelto en `AppCard` con el mismo estilo área-fill del prototipo (gradient indigo a transparent)

### 3.4 Fleet map · 1d
Ref: `nucleo/screens-desktop-modules.jsx :: Flota`
- [ ] `features/fleet_map/screens/fleet_map_screen.dart`
- [ ] 3-col layout: lista (320) + mapa (flex) + detalle (320)
- [ ] Lista: filter chips + AppListRow custom por unit
- [ ] Mapa: mantener Sitrack actual; encima añadir overlay de markers con bg blur 8px + borde indigo
- [ ] Detalle: stats grid 2x3 + eventos timeline + CTA secundario

### 3.5 Vencimientos chofer · 0.5d
- [ ] Lista: `features/expirations/screens/vencimientos_list.dart`
- [ ] Detalle: `features/expirations/screens/vencimiento_detail.dart`
- [ ] Hero number 112px en color del estado (warn / crit / ok)
- [ ] CTA primary "Subir comprobante" + secondary "Avisar a RRHH"

### 3.6 Personal lista admin · 0.5d
Ref: `screens-desktop-core.jsx :: Personal`
- [ ] `features/employees/screens/personal_list_screen.dart`
- [ ] Tabla con header sticky + 32 filas con avatar circular, badge de alerta, chevron
- [ ] Filter chips arriba + botón "Nuevo" primary

---

## Fase 4 · Módulos restantes — 5 días

Mismo patrón. Orden sugerido por complejidad ascendente:

- [ ] 4.1 — `features/employees/personal_detail_screen.dart` (drawer page completo)
- [ ] 4.2 — `features/expirations/admin_view_screen.dart` (tabla densa + KPI strip)
- [ ] 4.3 — `features/logistica/screens/*` (tabla de viajes + form de creación)
- [ ] 4.4 — `features/cachatore/*` (Cachatore = el módulo de turnos)
- [ ] 4.5 — `features/whatsapp_bot/*` (panel del bot WA con stats grid)
- [ ] 4.6 — `features/eco_driving/*`, `features/icm/*` (charts fl_chart con estilo Núcleo)
- [ ] 4.7 — `features/gomeria/*` (stock + recapados con tabla)
- [ ] 4.8 — `features/vehicles/*` (lista + ficha)
- [ ] 4.9 — `features/reports/*` (preview + export)
- [ ] 4.10 — `features/checklist/*`, `features/revisions/*`, `features/jornada_historico/*`, `features/asignaciones/*`, `features/zonas_descarga/*`, `features/empresas_empleadoras/*`, `features/auditoria_asignaciones/*`, `features/vista_ejecutiva/*` — módulos administrativos, mismo patrón que Personal

**Pantallas sin referencia explícita en el prototipo:** seguir el patrón visual del módulo más cercano + reglas del styleguide. Si una pantalla necesita componentes que no están en el handoff (ej. timeline vertical compleja, comparador antes/después), avisame.

---

## Fase 5 · Polish + multiplataforma — 2 días

### 5.1 iOS · 0.25d
- [ ] Status bar transparent + light icons (ya configurado en PlatformChrome.apply)
- [ ] SafeArea en cada scaffold body (no en el bg, sí en el contenido)
- [ ] Swipe-back gesture funcional en navigation stack
- [ ] Touch targets ≥ 44pt verificados con widget inspector
- [ ] Test en iPhone 12 mini (más chico) y iPhone 15 Pro Max (notch + Dynamic Island)

### 5.2 Android · 0.25d
- [ ] System nav bar matchea bg
- [ ] Edge-to-edge en Android 15+
- [ ] Touch targets ≥ 48dp
- [ ] Test en API 26 (mín) y API 34

### 5.3 macOS · 0.5d
- [ ] `_initDesktopWindow()` en main.dart con `window_manager`
- [ ] Title bar oculta + drag region en topbar custom (los 50px top del scaffold)
- [ ] Trafic lights posicionados (si title bar hidden) o style nativo (si visible)
- [ ] Min window 1200x720
- [ ] Build .app y test en Sonoma + Sequoia

### 5.4 Windows · 0.5d
- [ ] Title bar custom con `window_manager`
- [ ] Window controls (minimize/max/close) custom-render con icons del sistema
- [ ] Min window 1200x720
- [ ] Build .exe y test en Windows 11

### 5.5 Web · 0.5d
- [ ] `web/index.html`: meta theme-color (dark + light)
- [ ] `web/manifest.json`: theme_color y background_color en `#050505`
- [ ] Splash screen del browser matchea bg
- [ ] Test en Chrome, Edge, Safari
- [ ] Lighthouse audit > 90 en performance

---

## Checklist de cierre

- [ ] PR-by-feature mergeados (no un PR monolítico)
- [ ] `flutter analyze` limpio en main
- [ ] `flutter test` pasa
- [ ] CI guards actualizados: detectar uso de `Color(0xFF0EA5E9)`, `Colors.<accent>`, `fontFamily: 'Roboto'`
- [ ] Screenshots de las 5 plataformas en `docs/screenshots/v3.0/`
- [ ] CHANGELOG.md con la entrada `v1.0.86 — Refactor Núcleo`
- [ ] Versión bumpeada en pubspec
- [ ] App icons + splash screens actualizados al brand nuevo
- [ ] Smoke test grabado (video) corriendo en los 5 targets
- [ ] Demo al directorio: agendado, materiales preparados
