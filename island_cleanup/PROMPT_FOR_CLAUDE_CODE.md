# Prompt for Claude Code — island cleanup sweep

**Copy and paste the block below into Claude Code's chat**, after extracting `island_cleanup.zip` at the project root (so `island_cleanup/` sits next to `lib/`).

This is a **continuation prompt** — the main refactor and design polish are already applied. This pass cleans up the remaining "island" screens that the mechanical sweeps missed.

---

## The prompt

```
You are going to finish the design-system migration on the screens
that the previous sweep missed. Those screens weren't on the worklist
because they used `Colors.green` / `Colors.whiteNN` / ad-hoc
`ElevatedButton` directly — not the `accent*` tokens that drove
Phase 6.

Reference file: `island_cleanup/lib/features/employees/screens/user_mi_perfil_screen.dart`
That's the gold-standard rewrite. Read it end-to-end before
touching anything else.

## Step 1 — Apply the reference

cp island_cleanup/lib/features/employees/screens/user_mi_perfil_screen.dart \
   lib/features/employees/screens/user_mi_perfil_screen.dart

flutter analyze
flutter run -d <device> (smoke)

git checkout -b polish/island-cleanup
git add lib/features/employees/screens/user_mi_perfil_screen.dart
git commit  # use the template in island_cleanup/README.md

🛑 CHECKPOINT — show me the diff stat and pause:
   "Reference applied. Ready to start sweeping the other screens.
    Reply 'continuar' to proceed."

## Step 2 — Find the dirty screens

Run these searches and collect candidates:

  # Screens using ElevatedButton.styleFrom ad-hoc (should be AppButton).
  rg -l "ElevatedButton\.styleFrom\(|ElevatedButton\(" lib/features/

  # Screens with uppercase string literals (likely button/label shouting).
  rg -l "Text\(\s*'[A-ZÁÉÍÓÚÑ ]{4,}'\s*[,)]" lib/features/

  # Screens with raw Colors.whiteNN (should be AppColors.text*).
  rg -l "Colors\.white(12|24|38|54|60|70)" lib/features/

  # Screens with raw Colors.green / Colors.red / Colors.orange / blue/yellow
  # used as semantic (NOT the AppColors.* tokens — the raw Material ones).
  rg -l "(?<![\w.])Colors\.(green|red|orange|blue|yellow|purple|cyan|teal|amber)(?!Accent)(?![\w])" lib/features/

  # Screens with raw BorderRadius.circular(<num>) magic numbers.
  rg -l "BorderRadius\.circular\(\s*(10|12|14|15|18|20|22|25|30)\s*\)" lib/features/

The union of these lists is the worklist. Print it to me — there
will probably be 10–20 files. Sort by features/<area> for sanity.

## Step 3 — Apply the recipe, one file per commit

For each file in the worklist, apply the recipe demonstrated in
the reference:

  A. ElevatedButton + ElevatedButton.icon + TextButton
     →  AppButton (primary) / AppButton.secondary / AppButton.ghost
        / AppButton.danger
     - `isLoading: ...` instead of swapping to a separate spinner.
     - `expand: true` if the button was full-width.
     - `icon: ...` if it had a leading icon.
     - Drop all manual `style: ElevatedButton.styleFrom(...)`.

  B. Hardcoded uppercase string literals in button/section labels
     →  Sentence case in the source.
     - "GUARDAR" → "Guardar"
     - "CANCELAR" → "Cancelar"
     - "ACEPTAR" → "Aceptar"
     - "ELIMINAR" → "Eliminar" (and use AppButton.danger)
     - "DESCARGAR" → "Descargar"
     - "CAMBIAR..." → "Cambiar..."
     - Section row labels ("RAZÓN SOCIAL", "TRACTOR"): sentence case.
     - KEEP UPPERCASE for: section-header eyebrows (one per screen,
       inside an AppType.eyebrow Text). Acronyms (DNI, CUIL, ART, ICM).

  C. Raw Material color constants → semantic tokens.
     - Colors.green / Colors.green[XXX] → AppColors.success (state)
                                       or AppColors.brand (affordance)
                                       — pick the one that matches intent.
     - Colors.red / Colors.redAccent (any leftover) → AppColors.error
     - Colors.orange / amber → AppColors.warning
     - Colors.blue / cyan / teal → AppColors.brand or AppColors.info
     - Colors.white12 → AppColors.borderSubtle
     - Colors.white24 → AppColors.textHint
     - Colors.white38 → AppColors.textDisabled
     - Colors.white54 → AppColors.textTertiary
     - Colors.white60 / 70 → AppColors.textSecondary

     "Brand vs. state" rule of thumb: if the color is on a button or
     icon that you CAN TAP, it's affordance — use brand. If it indicates
     OK / vence / vencido / etc., it's state — use success/warning/error.

  D. Raw TextStyle(fontSize: ..., color: ..., fontWeight: ...) → AppType.
     - fontSize 24+ → AppType.title or AppType.display.copyWith(fontSize: X)
     - fontSize 16–18 bold → AppType.heading
     - fontSize 13–15 → AppType.body
     - fontSize 10–12 → AppType.label
     - fontSize 10 + uppercase + letterSpacing 1+ → AppType.eyebrow
       AND drop the manual letterSpacing override (eyebrow has 1.2).
     - Numeric values (KPIs, prices) → AppType.mono

     NEVER use `AppType.X.copyWith(letterSpacing: ...)` on an eyebrow.
     The whole point of AppType.eyebrow is the tracking is baked in.

  E. Magic numbers in EdgeInsets / SizedBox / BorderRadius → tokens.
     - 4 → AppSpacing.xs
     - 8 → AppSpacing.sm
     - 10/12 → AppSpacing.md
     - 14/15/16 → AppSpacing.lg
     - 18/20/22/24 → AppSpacing.xl
     - 28/30/32 → AppSpacing.xxl
     - 40/45/48 → AppSpacing.xxxl
     - BorderRadius.circular(12) → AppRadius.md
     - BorderRadius.circular(14/15/16/18/20/22/25) → AppRadius.lg
     - BorderRadius.circular(999 / 100+) → AppRadius.full

For each file:

  1. Apply the recipe.
  2. Run `flutter analyze` — confirm 0 NEW compile errors.
  3. Git diff the file — sanity check no behavior change.
  4. Commit with title:
        polish: <feature> screen full design-system adoption
     and body listing the changes (look at the reference file's
     commit message for the format).

🛑 CHECKPOINT — every 3 commits, pause:
   "Migrated [N/M] screens so far. Last 3: [list]. Reply
    'continuar' to keep going."

If you hit a screen where the cleanup is more than mechanical
(e.g. the screen has unusual layout that doesn't fit a normal pattern,
or removing a button changes UX), STOP and show me the diff before
committing. I'd rather review than have you guess.

## Step 4 — Adopt AppOfflineBanner + AppSkeleton at call-sites

After the recipe sweep, do a second pass for the two widgets the
design polish installed but didn't adopt:

  # Find screens with a CircularProgressIndicator that gates a list /
  # detail view (typical "loading state").
  rg -nC 2 "CircularProgressIndicator" lib/features/

For each candidate, ask me whether to migrate. If yes:
  - Lists: wrap with AppSkeletonList(count: 6–10) instead of the spinner.
  - Detail screens: compose AppSkeleton.circle + AppSkeleton.line for
    the visible structure.
  - Don't replace spinners INSIDE buttons (AppButton has its own).
  - Don't replace spinners inside `_loadingDialog`.

  # Find screens that should show the offline banner.
  rg -nC 5 "_conexionLenta|StreamBuilder<DocumentSnapshot" lib/features/

For each StreamBuilder that gates the whole body, ask me whether to
wrap with AppOfflineBanner. Don't migrate the local _conexionLenta
pattern from user_mi_perfil_screen — that one is already cleaned in
the reference and keeps a richer cached-data fallback.

🛑 FINAL CHECKPOINT — pause:
   "Sweep complete. Final stats: [files touched, commits, lines net].
    Ready to merge polish/island-cleanup → main? Reply 'yes' or 'wait'."

## If you get stuck

- If flutter analyze adds an error you can't trivially fix: STOP, revert
  the file, tell me which file and why.
- If a screen has so much custom logic that the recipe doesn't apply
  cleanly (e.g. it's a chart screen with very specific Canvas drawing):
  skip it and add to a "manual followup" list.
- If a button's intent isn't clear (primary? secondary? danger?): ask me
  with the line of context.
```

---

## When it's done

The branch `polish/island-cleanup` will have ~10–20 commits. Open a PR:

```
Title: polish: finish design-system adoption on island screens

Body:
- N screens cleaned (one commit each — see log)
- ElevatedButton ad-hoc → AppButton variants
- Uppercase button/label literals → sentence case
- Colors.whiteNN + raw Material colors → AppColors.* tokens
- Magic numbers in EdgeInsets/SizedBox/BorderRadius → tokens
- AppOfflineBanner adopted on N streams
- AppSkeleton adopted on N list/detail screens

After this, the design-system migration is done.
```

---

## Tips while it's running

- **It will probably want clarifications on intent** — most calls are mechanical, but "is this button danger or secondary?" comes up. Answer fast; the agent waits.
- **If you don't like a sentence-case rendering** (e.g. "ART" should stay uppercase, "Mi DNI" should keep DNI uppercase), tell it the rule. The recipe already says "preserve acronyms" but edge cases come up.
- **Skim each commit** — three lines per file usually tells you if the agent did the right thing. If it took liberties, revert and tell it the rule.
