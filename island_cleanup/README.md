# Island cleanup pack — finish the screens the sweep missed

**Generated: May 28, 2026 · Apply against `coopertrans_movil/lib/`**

The main refactor (`refactor.zip`) and design polish (`design_polish.zip`) got the rebrand to ~95%. This pack is the final 5% — **screens that lived as "islands"** with their own ad-hoc styling that the mechanical sweep (driven by `accent*` deprecation warnings) never touched.

## What's in here

```
island_cleanup/
├── lib/features/employees/screens/
│   └── user_mi_perfil_screen.dart   (REPLACE — gold-standard reference)
├── README.md                        (this file)
└── PROMPT_FOR_CLAUDE_CODE.md        (the prompt to give Claude Code)
```

**Just one screen rewrite** — but it's deliberate. `user_mi_perfil_screen.dart` is the **gold-standard reference**: the cleanest possible version of a detail screen using the design system. The Claude Code prompt then says "do the same to the other dirty screens."

---

## What changed in `user_mi_perfil_screen.dart`

| Before | After |
|---|---|
| `ElevatedButton(backgroundColor: Colors.green, ...)` ×2 (password dialog + edit dialog) | `AppButton(label: 'Guardar', ...)` |
| `ElevatedButton.icon('CAMBIAR MI CONTRASEÑA', ...)` with `Colors.white24` border, `BorderRadius.circular(15)`, etc. | `AppButton.secondary(label: 'Cambiar mi contraseña', icon: ..., expand: true)` |
| `TextButton('CANCELAR', style: TextStyle(color: Colors.white54))` ×2 | `AppButton.ghost(label: 'Cancelar')` |
| Header name in raw `TextStyle(fontSize: 24, fontWeight: bold, color: Colors.white)` | `AppType.title.copyWith(fontSize: 22)` |
| `'CHOFER PROFESIONAL'` eyebrow with `AppType.eyebrow.copyWith(color: AppColors.success, letterSpacing: 2)` | `AppType.eyebrow` straight — no overrides |
| `_SectionTitle` with `color: success, letterSpacing: 1.5` overrides | `AppType.eyebrow` straight |
| `_InfoTile.title` as `TextStyle(fontSize: 10, color: Colors.white54, letterSpacing: 1, bold)` + UPPERCASE strings | `AppType.label` + sentence-case strings ("Razón social", "Teléfono", "Mail"…) |
| Camera-button on avatar: `color: AppColors.success` (green) | `color: AppColors.brand` (cobalto) — affordance is not state |
| Edit pencil on `_InfoTileEditable`: `color: AppColors.success` | `color: AppColors.brand` — same reasoning |
| Bottom sheet "Actualizar foto" with `border: BorderSide(color: AppColors.success, width: 2)` decorative line | Removed — surface elevation does the separation |
| Bottom sheet `BorderRadius.circular(25)` | `AppRadius.lg` (16) |
| Magic numbers everywhere: 10, 14, 15, 18, 20, 25, 30, 50, 60 in padding/spacing | `AppSpacing.*` and `AppRadius.*` tokens |
| `_PerfilOfflineFallback` manual banner with hand-rolled `Container + BoxDecoration + Border.all` | `AppCard` with `highlighted: true` + `borderColor: warning` |
| `_PerfilOfflineFallback` avatar as raw `CircleAvatar(child: Text('X', style: ...))` | `FotoPerfilAvatar(url: null, nombre: ...)` — uses the existing initials fallback |

Net: ~1025 lines → ~700 lines, same behavior, zero hardcoded styles, full design-system compliance.

---

## How to apply this file

```bash
cd coopertrans_movil
git checkout -b polish/island-cleanup

cp <path-to-this-folder>/lib/features/employees/screens/user_mi_perfil_screen.dart \
   lib/features/employees/screens/user_mi_perfil_screen.dart

flutter analyze
flutter run -d <device>

# Smoke test:
# 1. Log in as a chofer.
# 2. Open "Mi Perfil" — verify: cobalto camera button (not green),
#    sentence-case row labels ("Razón social" not "RAZÓN SOCIAL"),
#    eyebrow "CHOFER PROFESIONAL" in neutral white-tertiary (not green).
# 3. Tap the "Cambiar mi contraseña" button — it's secondary style
#    (transparent + brand border), sentence case.
# 4. Tap the edit pencil on Teléfono/Mail — the dialog buttons are
#    AppButton ghost ("Cancelar") + primary ("Guardar"), sentence case.
# 5. Tap the camera bubble on the avatar — bottom sheet has no green
#    accent line; cobalto icons on each option.
# 6. Force a slow connection (Airplane mode for 12s) — the offline
#    fallback shows initials-on-cobalto avatar + warning card.

git add lib/features/employees/screens/user_mi_perfil_screen.dart
git commit -m "polish: user_mi_perfil_screen full design-system adoption

Gold-standard rewrite — same behavior, zero ad-hoc styling.

- All ElevatedButton + TextButton instances → AppButton variants.
- 'GUARDAR' / 'CANCELAR' / 'CAMBIAR MI CONTRASEÑA' UPPERCASE → sentence case.
- 'CHOFER PROFESIONAL' / section headers: AppType.eyebrow without
  color/letterSpacing overrides.
- Row labels: sentence case + AppType.label (was uppercase + ad-hoc TextStyle).
- Camera-button + edit-pencil: green → brand (affordance, not state).
- Bottom-sheet 'Actualizar foto': decorative green border removed.
- Magic numbers (10/14/15/18/20/25/30) → AppSpacing/AppRadius tokens.
- Colors.whiteNN raw → AppColors.text* semantic tokens.
- _PerfilOfflineFallback uses AppCard + FotoPerfilAvatar initials
  fallback instead of hand-rolled chrome.

This file is the gold-standard reference for cleaning up the other
'island' screens (gomeria, icm, vehicles detail, etc.). Follow the
same recipe — see PROMPT_FOR_CLAUDE_CODE.md."
```

---

## Then hand the rest to Claude Code

Now that the pattern is set, give `PROMPT_FOR_CLAUDE_CODE.md` to Claude Code. It will:

1. Use `user_mi_perfil_screen.dart` as the reference.
2. Find all screens with the dirty patterns (`grep`-based heuristics).
3. Apply the same recipe **one screen at a time, one commit each**.
4. Pause for review after every 3 screens.

Expect ~10–20 screens. ~10–20 minutes per screen in agent time.

---

## Rollback

```bash
git checkout main
git branch -D polish/island-cleanup
```
