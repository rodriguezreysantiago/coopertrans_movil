# PROMPT FOR CLAUDE CODE — Refactor Núcleo

> Pegá este archivo entero en Claude Code al iniciar la sesión.

## Contexto

Soy parte del equipo de **Coopertrans Móvil** (Flutter). Hicimos un refactor de diseño visual de toda la app y necesito aplicarlo al codebase. El sistema se llama **Núcleo** (escuela Linear / Cursor / Vercel) — negro real, indigo eléctrico como única tinta, Geist Sans + Geist Mono, hairlines, bento layouts, números héroe grandes.

El refactor anterior (2026-05-24) ya dejó la base limpia: tokens centralizados en `lib/shared/constants/app_colors.dart`, `lib/core/theme/app_typography.dart` y `app_spacing.dart`; widgets canónicos `AppButton`, `AppCard`, `AppStatusBadge`, `AppScaffold`. Esta vuelta **NO es un rewrite** — es una **sustitución de tokens + ampliación de widgets**, manteniendo los nombres existentes para que el cambio sea mecánico.

## Materiales adjuntos

Todo viene en el mismo zip. La estructura es **espejada del codebase** — cada
archivo `.dart` va al mismo path relativo donde está su versión actual:

```
handoff/
├── FILE_MAP.md                                 ← tabla autoritativa de copia
├── PROMPT_FOR_CLAUDE_CODE.md                   ← este archivo
├── MIGRATION_PLAN.md                           ← checklist de 5 fases × 12 días
├── Handoff.html                                ← landing visual (opcional)
│
├── lib/shared/constants/
│   └── app_colors.dart                         ← reemplazar contenido (mismo path que ya existe)
├── lib/core/theme/
│   ├── app_typography.dart                     ← reemplazar contenido
│   ├── app_spacing.dart                        ← reemplazar contenido
│   ├── app_radius.dart                         ⊕ nuevo
│   ├── app_shadows.dart                        ⊕ nuevo
│   ├── app_theme.dart                          ← reemplazar contenido
│   └── platform_chrome.dart                    ⊕ nuevo
├── lib/shared/widgets/
│   ├── app_button.dart                         ← reemplazar contenido
│   ├── app_card.dart                           ← reemplazar contenido
│   ├── app_badge.dart                          ⊕ nuevo (NO renombrar app_status_badge — ver FILE_MAP.md)
│   ├── app_input.dart                          ⊕ nuevo
│   ├── app_eyebrow.dart                        ⊕ nuevo (incluye AppDot, AppHairline)
│   ├── app_stat.dart                           ⊕ nuevo (incluye AppKpiStrip, AppSparkline)
│   └── app_ambient.dart                        ⊕ nuevo
│
└── nucleo/                                     ← materiales de REFERENCIA (no copiar al Flutter)
    ├── Styleguide.html                         — sistema completo
    ├── Prototipo.html                          — chofer + admin navegable
    ├── system.jsx                              — primitivos React (referencia 1:1)
    ├── screens-mobile.jsx                      — 8 pantallas chofer
    ├── screens-desktop-core.jsx                — 5 pantallas admin core
    └── screens-desktop-modules.jsx             — módulos admin
```

**ESTRATEGIA DE COPIA: reemplazar contenido in-place, NO mover archivos** entre
carpetas. La razón: los archivos existentes (`app_colors.dart`,
`app_typography.dart`, etc.) tienen ~80 imports apuntándolos en todo el repo.
Mover rompe el repo. Solo se cambia el contenido del archivo. **`FILE_MAP.md`
tiene la tabla autoritativa de qué va dónde.**

**Cuando duda exista sobre cómo se ve una pantalla, abrir el JSX correspondiente
de `nucleo/screens-*.jsx` y traducir el árbol React a Flutter widget tree.** Cada
`<div style={...}>` ahí ya tiene el espaciado, color y tipo que esperamos en el
Dart final.

## Cambios de tokens — tabla rápida

| Token | Antes (2026-05-24) | Ahora (Núcleo) |
|---|---|---|
| `AppColors.brand` | `#0EA5E9` cobalto | `#7C83FF` indigo (dark) / `#5B62E0` (light) |
| `AppColors.surface0` | `#09141F` azulado | `#050505` near-black |
| `AppColors.surface2` | `#132538` | `#0F0F10` |
| `AppColors.success` | `#1F8A5B` | `#4ADE80` (dark) / `#16A34A` (light) |
| `AppColors.warning` | `#C46A14` | `#FBBF24` (dark) / `#D97706` (light) |
| `AppColors.error` | `#B3261E` | `#FB7185` (dark) / `#E11D48` (light) |
| `AppType.display` | 32 / Roboto / w700 | 32 / Geist / w600 (mantiene size) |
| `AppType.title` | 22 / Roboto | 22 / Geist · ALIAS de h4 |
| `AppRadius` default | 16 | 12 (cards), 8 (botones, inputs) |
| Font family | Roboto | Geist + Geist Mono via `google_fonts` |

**Nuevos estilos tipo:** `AppType.mega` (96), `AppType.hero` (72), `AppType.h1`..`h5`, `AppType.bodyLg`, `AppType.bodySm`, `AppType.monoSm`.

**Nuevos widgets:** `AppEyebrow`, `AppDot`, `AppHairline`, `AppStat`, `AppKpiStrip`, `AppSparkline`, `AppAmbient`, `AppInput`.

## Plan de migración

Seguir `MIGRATION_PLAN.md`. Resumen:

**Fase 1 — Theme engine (1 día)**
- [ ] Agregar `google_fonts: ^6.2.1` y `window_manager: ^0.4.2` a `pubspec.yaml`
- [ ] Copiar los 7 archivos de `handoff/lib/core/theme/` reemplazando los existentes
- [ ] Refactorizar `lib/main.dart` para registrar `AppTheme.dark()` y `AppTheme.light()` y llamar `PlatformChrome.apply(...)` al inicio
- [ ] Verificar que la app compila en los 5 targets (iOS / Android / macOS / Windows / Chrome)

**Fase 2 — Widgets base (1 día)**
- [ ] Copiar los 7 archivos de `handoff/lib/shared/widgets/` reemplazando o agregando
- [ ] Actualizar `app_widgets.dart` (barrel file) para exportar los nuevos
- [ ] Borrar `app_status_badge.dart` (reemplazado por `app_badge.dart`)
- [ ] Ajustar imports rotos por el cambio de nombre

**Fase 3 — Pantallas críticas (3 días)**
En este orden, usando los JSX del prototipo como spec:

1. `features/auth/screens/login_screen.dart` ← `nucleo/screens-mobile.jsx :: Login`
2. `features/home/screens/main_panel.dart` (home chofer) ← `nucleo/screens-mobile.jsx :: Home`
3. `features/admin_dashboard/screens/admin_panel_screen.dart` ← `screens-desktop-core.jsx :: Dashboard`
4. `features/fleet_map/screens/fleet_map_screen.dart` ← `screens-desktop-modules.jsx :: Flota`
5. `features/expirations/` (lista + detalle del chofer) ← `screens-mobile.jsx :: VencList, VencDetail`
6. `features/employees/screens/personal_list.dart` ← `screens-desktop-core.jsx :: Personal`

**Fase 4 — Módulos restantes (5 días)**
Mismo patrón. Si un módulo no tiene referencia JSX (gomería, eco-driving, ICM, reportes, jornada_historico), usar empty-state visual del prototipo y mantener la lógica actual.

**Fase 5 — Polish + multiplataforma (2 días)**
- [ ] Status bars correctos en iOS y Android (dark fondo → ícons claros)
- [ ] Title bar custom en macOS / Windows (negro, sin gradient nativo)
- [ ] `web/index.html` con `<meta name="theme-color" content="#050505">`
- [ ] PWA manifest `theme_color` y `background_color`
- [ ] Safe area en mobile (`SafeArea` envolviendo cada scaffold)
- [ ] Min touch target 44x44 verificado en todos los `GestureDetector` y `InkWell`
- [ ] Smoke test en los 5 targets

**Total estimado: 12 días-persona.** Si vas a paralelizar, las fases 3 y 4 se pueden trabajar por módulo en paralelo (cada uno aislado en su feature folder).

## Reglas de oro (no negociables)

1. **Una sola tinta brillante por pantalla.** El indigo del brand. Verde/ámbar/coral son SOLO semánticos (ok/warn/crit) — nunca decorativos.
2. **Una sola línea uppercase por bloque.** El `AppEyebrow`. Nada más en uppercase.
3. **Mono solo para lo técnico.** Timestamps, IDs, métricas, status labels, atajos de teclado. Lo humano (títulos, copy, botones) va en Geist Sans.
4. **Hairlines, no bordes pesados.** `border: 1px solid context.colors.border` (que es rgba a 6-12%). Nunca colores fuertes para separar.
5. **Sombras solo brand-glow.** No drop-shadows decorativos. Las cards bento se separan por surface2 sobre bg + border, no por sombra.
6. **Radius fijo por componente.** Botones e inputs: 8px. Cards: 12px. Modales/sheets: 16px. Pills: 999. No mezclar.
7. **Números KPI siempre tabular-nums.** Para que no "bailen" al cambiar de valor.
8. **Empty / Loading / Error / NoPerm estados son obligatorios** en cada pantalla con data. Usar los componentes de la sección 08 del `Styleguide.html` (los puedo armar como widget si los necesitás).

## Multiplataforma — checklist por target

### iOS
- Status bar: `Brightness.light` icons sobre fondo oscuro (Settings → `PlatformChrome.apply`)
- Safe area: envolver scaffold body con `SafeArea`
- Notch / Dynamic Island: el header del prototipo (status bar mock) NO va en producción; usar `MediaQuery.padding.top`
- Touch targets ≥ 44pt (iOS HIG)
- Cupertino-style swipe back se mantiene en navigator

### Android
- Status bar y system nav bar configuradas vía `SystemUiOverlayStyle`
- Material 3 enabled (ya lo está en `useMaterial3: true`)
- Touch targets ≥ 48dp (Material guidelines)
- Edge-to-edge habilitado en Android 15+ (`SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)`)

### macOS
- Title bar oculta (`TitleBarStyle.hidden`) con drag region en el topbar custom
- Window background: `#050505` (matchea bg) — sin "flash" blanco al abrir
- Min window size: 1200x720
- Cmd+W cierra, Cmd+Q quita
- Trafic-light buttons custom-positioned si title bar oculta (`window_manager` API)

### Windows
- Title bar custom (sin Mica/acrylic nativos) — fondo `#050505`
- Window controls: usar `window_manager` o `flutter_acrylic` con title bar custom
- Min size: 1200x720
- Soporte teclado completo (Tab navegación, Esc para cerrar dialogs)

### Chrome (web)
- `web/index.html`: `<meta name="theme-color" content="#050505" media="(prefers-color-scheme: dark)">` y la versión light
- PWA manifest: `theme_color: #050505`, `background_color: #050505`
- Splash screen del manifest matchea bg
- Service worker para offline básico (ya está en el codebase)
- No abusar de `RawKeyboardListener` — usar `Focus` y `Shortcuts` para que funcione con accesibilidad del browser

## Tipografía — instalación de Geist

`google_fonts: ^6.2.1` ya incluye Geist y Geist Mono. Primera carga es desde fonts.googleapis.com → se cachea. Para uso offline, embed los .ttf en `assets/fonts/` y declararlos en `pubspec.yaml`. Sample:

```yaml
flutter:
  fonts:
    - family: Geist
      fonts:
        - asset: assets/fonts/Geist-Regular.ttf
        - asset: assets/fonts/Geist-Medium.ttf
          weight: 500
        - asset: assets/fonts/Geist-SemiBold.ttf
          weight: 600
        - asset: assets/fonts/Geist-Bold.ttf
          weight: 700
    - family: GeistMono
      fonts:
        - asset: assets/fonts/GeistMono-Regular.ttf
        - asset: assets/fonts/GeistMono-Medium.ttf
          weight: 500
```

Bajar de https://vercel.com/font o de Google Fonts directo.

## Aceptación / quality bar

Para considerar la migración terminada:

- [ ] La app compila y corre en los 5 targets
- [ ] No quedan referencias a `Colors.<accent>` neon del prototipo (CI guard)
- [ ] No quedan referencias a `Color(0xFF0EA5E9)` (cobalto viejo)
- [ ] `flutter analyze` limpio
- [ ] `flutter test` pasa (los widget tests existentes pueden necesitar update de selectores)
- [ ] Las 16 pantallas del prototipo reproducidas pixel-aware (no pixel-perfect — el target es Flutter, no HTML)
- [ ] Splash screen y app icon actualizados al brand nuevo
- [ ] PR-by-feature, no un PR monolítico

## Si surge una decisión que el handoff no cubre

Mandame un mensaje describiendo el caso. NO inventés. Ejemplos típicos:
- Pantalla del Flutter actual que no tiene equivalente en el prototipo
- Componente de form complejo (date picker, multi-select)
- Animaciones / transiciones específicas
- Manejo de un caso de error puntual de Firestore

Suelo poder responder en menos de un día.
