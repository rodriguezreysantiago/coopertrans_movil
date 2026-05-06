#!/usr/bin/env python3
"""
Hook SessionStart de Claude Code.

Cada vez que arrancás una sesion en cualquier PC/Mac, este script
intenta `git pull --ff-only` desde origin para que arranques con la
ultima version de main. Si el working dir tiene cambios sin commitear,
NO hace pull (no destruye nada) y avisa.

Usa solo la libreria estandar (subprocess + sys), corre en Win/Mac/Linux.
"""

from __future__ import annotations

import shutil
import subprocess
import sys


def run(cmd: list[str]) -> tuple[int, str]:
    """Corre un comando y devuelve (exit_code, stdout+stderr)."""
    try:
        out = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        return out.returncode, (out.stdout + out.stderr).strip()
    except FileNotFoundError:
        return 127, f"comando no encontrado: {cmd[0]}"
    except subprocess.TimeoutExpired:
        return 124, f"timeout: {' '.join(cmd)}"


def main() -> int:
    if not shutil.which("git"):
        print("⚠️ git no esta en PATH; salto el auto-pull.")
        return 0

    # Solo pulleamos si el working dir esta limpio. Nunca destruir
    # cambios locales sin que el user lo decida.
    rc, dirty = run(["git", "status", "--porcelain"])
    if rc != 0:
        # No es un repo git (o hay un error grave) — no hago nada.
        return 0
    if dirty:
        lines = dirty.splitlines()
        n = len(lines)
        print(f"⚠️ Hay {n} archivo(s) con cambios sin commitear — salto git pull automatico.")
        print("   Para ver: git status")
        return 0

    # Fetch primero (silencioso, no destructivo).
    run(["git", "fetch", "origin"])

    # ¿Estamos atrasados respecto al upstream?
    rc, upstream_log = run(["git", "log", "HEAD..@{u}", "--oneline"])
    if rc != 0 or not upstream_log:
        # No hay commits nuevos en remoto, o no hay upstream tracking.
        return 0

    nuevos = len(upstream_log.splitlines())
    print(f"📥 Hay {nuevos} commit(s) nuevo(s) en origin/main. Bajando con git pull --ff-only...")
    rc, output = run(["git", "pull", "--ff-only"])
    if rc == 0:
        print(f"✅ Sincronizado con origin. Arrancas con la ultima version.")
    else:
        print(f"⚠️ git pull --ff-only fallo. Revisa manualmente:\n{output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
