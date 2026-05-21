#!/usr/bin/env python3
"""
Hook PreToolUse de Claude Code -- gate de validacion ANTES de cada `git commit`.

Ahora que los commits se pushean solos a main (y de ahi la PC dedicada hace pull
en ~5 min, y un `firebase deploy` puede ir a produccion), este gate evita que
entre codigo roto:

  - Si hay .ts staged en functions/      -> tsc --noEmit + eslint .
  - Si hay .dart staged en lib/ o test/  -> flutter analyze

Solo corre el validador de la categoria que tiene cambios staged: un commit que
toca solo docs/scripts/whatsapp-bot/cachatore NO paga el costo. Si un validador
no esta instalado, AVISA pero NO bloquea (mejor dejar pasar que trabar todo por
una tool ausente). Si un validador falla, BLOQUEA el commit.

El matcher del hook es "Bash" (corre para todo comando Bash), asi que el script
se auto-filtra: si el comando no es un `git commit`, sale al toque (exit 0).

Cross-platform (Win/Mac/Linux). Solo libreria estandar. ASCII puro.

Test sin tocar git:
    python validate_changes.py --files functions/src/x.ts lib/main.dart
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys

MAX_REASON = 1800  # chars de salida del validador que metemos en el motivo


def repo_root() -> str:
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env and os.path.isdir(env):
        return env
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=10, check=False,
        )
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except Exception:
        pass
    return os.getcwd()


def staged_files(root: str) -> list[str]:
    try:
        out = subprocess.run(
            ["git", "diff", "--cached", "--name-only"],
            cwd=root, capture_output=True, text=True, timeout=15, check=False,
        )
        if out.returncode == 0:
            return [l.strip() for l in out.stdout.splitlines() if l.strip()]
    except Exception:
        pass
    return []


def worktree_files(root: str) -> list[str]:
    """Paths con cambios en el working tree (staged + unstaged + untracked)."""
    try:
        out = subprocess.run(
            ["git", "status", "--porcelain"],
            cwd=root, capture_output=True, text=True, timeout=15, check=False,
        )
        if out.returncode != 0:
            return []
        res = []
        for line in out.stdout.splitlines():
            p = line[3:].strip() if len(line) > 3 else ""
            if "->" in p:  # rename: "viejo -> nuevo"
                p = p.split("->", 1)[1].strip()
            p = p.strip('"')
            if p:
                res.append(p)
        return res
    except Exception:
        return []


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def run_capture(cmd_str: str, cwd: str, timeout: int = 240) -> tuple[int, str]:
    """Corre un comando (string literal, sin input externo) via shell.

    shell=True para que en Windows resuelva npx.cmd / flutter.bat desde el PATH
    sin el lio de CreateProcess con .cmd/.bat. Los comandos son literales fijos
    definidos aca abajo (no hay interpolacion de datos del usuario)."""
    try:
        r = subprocess.run(
            cmd_str, cwd=cwd, shell=True,
            capture_output=True, text=True, timeout=timeout, check=False,
        )
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except subprocess.TimeoutExpired:
        return 124, "timeout"
    except Exception as e:  # noqa: BLE001
        return 127, str(e)


def deny(reason: str) -> None:
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }))
    sys.exit(0)


def es_git_commit(cmd_str: str) -> bool:
    # Cubre "git commit ..." al inicio o encadenado (git add x && git commit ...).
    return bool(re.search(r"(?:^|&&|;|\|)\s*git\s+commit\b", cmd_str.strip()))


def hay_git_add(cmd_str: str) -> bool:
    return bool(re.search(r"\bgit\s+add\b", cmd_str))


def es_commit_all(cmd_str: str) -> bool:
    # git commit -a / -am / --all : commitea todo lo trackeado modificado, asi
    # que los archivos a comitear pueden NO estar staged al correr el hook.
    m = re.search(r"git\s+commit\b([^&|;]*)", cmd_str)
    if not m:
        return False
    flags = m.group(1)
    return bool(re.search(r"(?:^|\s)-[a-zA-Z]*a", flags)) or "--all" in flags


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", nargs="*", default=None,
                    help="Archivos a tratar como staged (para testear).")
    args = ap.parse_args()

    root = repo_root()

    if args.files is None:
        # Modo hook real: leer tool_input de stdin para ver si es un git commit.
        raw = ""
        try:
            raw = sys.stdin.read()
        except Exception:
            raw = ""
        raw = raw.lstrip(chr(0xFEFF))  # tolera BOM (algunas shells lo agregan)
        cmd_str = ""
        if raw.strip():
            try:
                data = json.loads(raw)
                cmd_str = (data.get("tool_input") or {}).get("command", "") or ""
            except Exception:
                cmd_str = ""
        if not es_git_commit(cmd_str):
            return 0  # No es un commit -> no nos metemos.
        files = staged_files(root)
        # El hook corre ANTES del comando (PreToolUse). Si el comando stagea
        # dentro de si mismo (git add ... && git commit) o es commit -a/--all,
        # lo que se va a comitear todavia no esta en el index -> ampliamos al
        # working tree para no dejar pasar codigo roto encadenando comandos.
        if hay_git_add(cmd_str) or es_commit_all(cmd_str):
            files = sorted(set(files) | set(worktree_files(root)))
    else:
        files = args.files

    files = [f.replace("\\", "/") for f in files]

    toca_functions = any(
        f.startswith("functions/") and f.endswith(".ts")
        and "/lib/" not in f and "/node_modules/" not in f
        for f in files
    )
    toca_flutter = any(
        (f.startswith("lib/") or f.startswith("test/")) and f.endswith(".dart")
        for f in files
    )

    if not toca_functions and not toca_flutter:
        return 0  # Nada validable staged.

    fallos: list[str] = []
    detalle: list[str] = []

    if toca_functions:
        fdir = os.path.join(root, "functions")
        if not have("npx"):
            print("[validate] npx no encontrado -> salteo tsc/eslint (no bloqueo)",
                  file=sys.stderr)
        else:
            print("[validate] functions: tsc --noEmit ...", file=sys.stderr)
            rc, out = run_capture("npx tsc --noEmit", fdir)
            sys.stderr.write(out)
            if rc != 0:
                fallos.append("tsc (functions)")
                detalle.append("=== tsc ===\n" + out)
            print("[validate] functions: eslint . ...", file=sys.stderr)
            rc, out = run_capture("npx eslint .", fdir)
            sys.stderr.write(out)
            if rc != 0:
                fallos.append("eslint (functions)")
                detalle.append("=== eslint ===\n" + out)

    if toca_flutter:
        if not have("flutter"):
            print("[validate] flutter no encontrado -> salteo analyze (no bloqueo)",
                  file=sys.stderr)
        else:
            print("[validate] lib/test: flutter analyze --no-pub ...", file=sys.stderr)
            rc, out = run_capture("flutter analyze --no-pub", root, timeout=300)
            sys.stderr.write(out)
            if rc == 124:
                print("[validate] flutter analyze excedio el timeout (arranque en "
                      "frio del analysis server?) -> NO bloqueo. Conviene correrlo "
                      "a mano: flutter analyze", file=sys.stderr)
            elif rc != 0:
                fallos.append("flutter analyze")
                detalle.append("=== flutter analyze ===\n" + out)

    if fallos:
        cola = ("\n".join(detalle)).strip()
        if len(cola) > MAX_REASON:
            cola = "...(recortado)...\n" + cola[-MAX_REASON:]
        deny(
            "Commit BLOQUEADO por el gate de validacion. Fallo: "
            + ", ".join(fallos)
            + ". Arregla y volve a commitear.\n\n" + cola
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
