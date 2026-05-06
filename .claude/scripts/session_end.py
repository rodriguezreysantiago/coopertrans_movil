#!/usr/bin/env python3
"""
Hook Stop / SessionEnd de Claude Code.

Cuando termina la sesion, chequea:
  1. Cambios sin commitear en el working dir.
  2. Commits locales sin pushear al origin.

Si encuentra alguno, imprime un aviso visible al user — la idea es
que NO se vaya a dormir / cambie de PC olvidandose de pushear.

Cross-platform (Win/Mac/Linux). Usa solo libreria estandar.
"""

from __future__ import annotations

import shutil
import subprocess
import sys


def run(cmd: list[str]) -> tuple[int, str]:
    try:
        out = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )
        return out.returncode, (out.stdout + out.stderr).strip()
    except FileNotFoundError:
        return 127, ""
    except subprocess.TimeoutExpired:
        return 124, ""


def main() -> int:
    if not shutil.which("git"):
        return 0

    rc, _ = run(["git", "rev-parse", "--git-dir"])
    if rc != 0:
        return 0  # No es un repo git.

    # 1. Cambios sin commitear.
    rc, dirty = run(["git", "status", "--porcelain"])
    cambios = dirty.splitlines() if rc == 0 and dirty else []

    # 2. Commits sin pushear (HEAD por delante del upstream).
    rc, ahead = run(["git", "log", "@{u}..HEAD", "--oneline"])
    unpushed = ahead.splitlines() if rc == 0 and ahead else []

    if not cambios and not unpushed:
        return 0  # Todo sincronizado, nada que avisar.

    print()
    print("=" * 60)
    print("⚠️  ANTES DE CAMBIAR DE PC O CERRAR")
    print("=" * 60)

    if cambios:
        print(f"\n📝 {len(cambios)} archivo(s) con cambios sin commitear:")
        for line in cambios[:10]:
            print(f"   {line}")
        if len(cambios) > 10:
            print(f"   ... y {len(cambios) - 10} mas")
        print("\n   Para commitear:  git add ... && git commit -m '...'")

    if unpushed:
        print(f"\n📤 {len(unpushed)} commit(s) sin pushear a origin:")
        for line in unpushed[:10]:
            print(f"   {line}")
        if len(unpushed) > 10:
            print(f"   ... y {len(unpushed) - 10} mas")
        print("\n   Para pushear:    git push")

    print()
    print("Si te vas a otra PC/Mac, asegurate de pushear primero.")
    print("Sino los cambios quedan solo aca y la otra maquina")
    print("arranca desactualizada.")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(main())
