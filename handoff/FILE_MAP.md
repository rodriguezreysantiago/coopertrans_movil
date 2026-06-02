# FILE MAP — Refactor Núcleo

> **Esta tabla manda.** Cualquier ambigüedad en el plan se resuelve mirando acá.

## Regla principal

**Reemplazá contenidos in-place. NO muevas archivos entre carpetas** —
cada archivo del codebase tiene ~10-80 imports apuntándolo. Mover rompe el repo.

Los nuevos archivos (los marcados con ⊕) van al path indicado abajo y se importan
desde donde se necesiten.

## Mapping

| Archivo en este zip | Path destino en el codebase | Acción |
|---|---|---|
| `lib/shared/constants/app_colors.dart` | `lib/shared/constants/app_colors.dart` | **reemplazar contenido** |
| `lib/core/theme/app_typography.dart` | `lib/core/theme/app_typography.dart` | **reemplazar contenido** |
| `lib/core/theme/app_spacing.dart` | `lib/core/theme/app_spacing.dart` | **reemplazar contenido** |
| `lib/core/theme/app_radius.dart` | `lib/core/theme/app_radius.dart` | ⊕ nuevo |
| `lib/core/theme/app_shadows.dart` | `lib/core/theme/app_shadows.dart` | ⊕ nuevo |
| `lib/core/theme/app_theme.dart` | `lib/core/theme/app_theme.dart` | **reemplazar contenido** |
| `lib/core/theme/platform_chrome.dart` | `lib/core/theme/platform_chrome.dart` | ⊕ nuevo |
| `lib/shared/widgets/app_button.dart` | `lib/shared/widgets/app_button.dart` | **reemplazar contenido** |
| `lib/shared/widgets/app_card.dart` | `lib/shared/widgets/app_card.dart` | **reemplazar contenido** |
| `lib/shared/widgets/app_badge.dart` | `lib/shared/widgets/app_badge.dart` | ⊕ nuevo · ver nota ① |
| `lib/shared/widgets/app_input.dart` | `lib/shared/widgets/app_input.dart` | ⊕ nuevo |
| `lib/shared/widgets/app_eyebrow.dart` | `lib/shared/widgets/app_eyebrow.dart` | ⊕ nuevo (incluye `AppDot`, `AppHairline`) |
| `lib/shared/widgets/app_stat.dart` | `lib/shared/widgets/app_stat.dart` | ⊕ nuevo (incluye `AppKpiStrip`, `AppSparkline`) |
| `lib/shared/widgets/app_ambient.dart` | `lib/shared/widgets/app_ambient.dart` | ⊕ nuevo |

### ① Nota sobre `app_status_badge` → `app_badge`

El widget existente se llama `AppStatusBadge` en
`lib/shared/widgets/app_status_badge.dart`. El nuevo se llama `AppBadge` en
`lib/shared/widgets/app_badge.dart`. Tenés dos opciones:

**Opción A (recomendada) — agregar el nuevo, deprecar el viejo en fase 4:**
1. Agregás `app_badge.dart` como nuevo archivo
2. En `app_status_badge.dart` agregás un `@Deprecated('Usar AppBadge')` en la clase
3. A medida que migrás cada feature folder, reemplazás `AppStatusBadge(...)` por `AppBadge(...)`
4. Cuando no quedan call-sites, borrás `app_status_badge.dart`

**Opción B — search & replace en un solo PR:**
1. Renombrás el archivo (`git mv app_status_badge.dart app_badge.dart`)
2. Reemplazás contenido por el de este zip
3. `grep -rl 'AppStatusBadge' lib/ | xargs sed -i 's/AppStatusBadge/AppBadge/g'`
4. `grep -rl 'app_status_badge' lib/ | xargs sed -i 's/app_status_badge/app_badge/g'`
5. `flutter analyze` y arreglás casos puntuales (constructores con args distintos)

Para esta refactor usar **Opción A** salvo que el calendario apriete.

## Barrel file (`app_widgets.dart`)

Agregar exports nuevos:

```dart
// lib/shared/widgets/app_widgets.dart
// ... exports existentes ...
export 'app_ambient.dart';
export 'app_badge.dart';        // nuevo
export 'app_eyebrow.dart';      // incluye AppDot, AppHairline
export 'app_input.dart';
export 'app_stat.dart';         // incluye AppKpiStrip, AppSparkline
```

## Materiales de referencia (NO se copian al Flutter)

| Archivo en este zip | Para qué |
|---|---|
| `nucleo/Styleguide.html` | Sistema completo en una página. Abrir en browser para inspeccionar tokens, type, componentes, patrones, estados. |
| `nucleo/Prototipo.html` | Chofer móvil + admin escritorio navegable lado a lado, 16 pantallas. **La spec visual de cada pantalla a migrar.** |
| `nucleo/system.jsx` | Los primitivos React. Referencia 1:1 al traducir a Dart widgets. |
| `nucleo/screens-mobile.jsx` | 8 pantallas chofer (Splash, Login, Home, Perfil, VencList, VencDetail, Unidad, Notifs). |
| `nucleo/screens-desktop-core.jsx` | 5 pantallas admin core (Login, Dashboard, Personal, PersonalDetail, Vencimientos). |
| `nucleo/screens-desktop-modules.jsx` | Módulos admin (Flota, Logística, Servicios, Gomería/Eco/ICM como coming-soon). |

**Cómo usar el JSX como spec:** cada `<div style={{...}}>` se traduce a un `Container(decoration: BoxDecoration(...))` o `Row/Column` con los mismos valores. Los colores son hex inline (no usan tokens) — al portar a Dart, mapeá cada hex al token semántico equivalente (`context.colors.brand`, `.text`, `.surface2`, etc.).
