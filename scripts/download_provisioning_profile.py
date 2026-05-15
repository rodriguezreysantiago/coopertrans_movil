#!/usr/bin/env python3
"""
Descarga un Provisioning Profile desde App Store Connect API + lo guarda
local + genera el base64 listo para pegar como Custom Environment Variable
en Xcode Cloud.

Uso:
    python3 download_provisioning_profile.py \\
        --key-id 7K3A7243WL \\
        --issuer-id 2b70dc6f-0859-4830-925f-743881d5cf1c \\
        --key-path /path/to/AuthKey_XXXX.p8 \\
        --profile-name "Coopertrans Movil App Store" \\
        --output-dir /path/donde/guardar

Salida (en --output-dir):
    {safe_profile_name}.mobileprovision    binario para instalar
    {safe_profile_name}_BASE64.txt         base64 listo para env var

El base64 se pega como valor de la env var IOS_DIST_PROFILE_BASE64 en el
workflow de Xcode Cloud (App Store Connect -> tu app -> Xcode Cloud ->
workflow -> Edit -> Custom Environment Variables -> "+", marcar Secret).

Requisitos:
    pip3 install --user pyjwt cryptography

Casos de uso:
    - Re-descargar el .mobileprovision cuando vence (cada 1 anyo).
    - Setup inicial de Xcode Cloud sin Mac (cuenta nueva o desde
      Windows/Linux con Python 3 + pyjwt).
    - Diagnosticar que profiles tiene la cuenta (lista todos antes de
      filtrar por nombre).

Ejemplo Coopertrans:
    python3 scripts/download_provisioning_profile.py \\
        --key-id 7K3A7243WL \\
        --issuer-id 2b70dc6f-0859-4830-925f-743881d5cf1c \\
        --key-path "G:/Mi unidad/ClaudeCodeSync/secrets-ios/AuthKey_7K3A7243WL.p8" \\
        --profile-name "Coopertrans Movil App Store" \\
        --output-dir "G:/Mi unidad/ClaudeCodeSync/secrets-ios"

Generado durante la sesion 2026-05-15 cuando la API de signing de Apple no
funcionaba para cuentas recien aprobadas y necesitabamos pre-cargar el
profile al runner Xcode Cloud via secret env var (Manual Signing).
"""
import argparse
import base64
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import jwt


def safe_filename(name: str) -> str:
    """Convierte un name de profile a filename seguro."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", name)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Descarga provisioning profile desde App Store Connect API."
    )
    parser.add_argument("--key-id", required=True, help="Key ID (10 chars).")
    parser.add_argument("--issuer-id", required=True, help="Issuer ID (UUID).")
    parser.add_argument(
        "--key-path",
        required=True,
        type=Path,
        help="Path al .p8 con la private key.",
    )
    parser.add_argument(
        "--profile-name",
        required=True,
        help='Nombre exacto del profile (ej. "Coopertrans Movil App Store").',
    )
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="Directorio donde guardar el .mobileprovision + base64.",
    )
    args = parser.parse_args()

    if not args.key_path.exists():
        print(f"ERROR: no existe {args.key_path}", file=sys.stderr)
        return 1
    args.output_dir.mkdir(parents=True, exist_ok=True)

    # 1. Generar JWT firmado con ES256 (formato exigido por App Store Connect API)
    private_key = args.key_path.read_bytes()
    now = int(time.time())
    payload = {
        "iss": args.issuer_id,
        "iat": now,
        "exp": now + 1200,  # 20 min
        "aud": "appstoreconnect-v1",
    }
    headers = {"alg": "ES256", "kid": args.key_id, "typ": "JWT"}
    token = jwt.encode(payload, private_key, algorithm="ES256", headers=headers)
    print(f"JWT generado, len={len(token)}")

    # 2. Listar profiles
    list_url = "https://api.appstoreconnect.apple.com/v1/profiles?limit=200"
    req = urllib.request.Request(
        list_url, headers={"Authorization": f"Bearer {token}"}
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            list_data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print(f"ERROR HTTP {e.code}: {body[:500]}", file=sys.stderr)
        return 1

    profiles = list_data.get("data", [])
    print(f"Profiles disponibles ({len(profiles)}):")
    for p in profiles:
        attrs = p["attributes"]
        print(
            f"  - {attrs['name']!r} ({attrs['profileType']}, {attrs['profileState']})"
        )

    # 3. Buscar el target
    target = next(
        (p for p in profiles if p["attributes"]["name"] == args.profile_name), None
    )
    if not target:
        print(
            f"\nERROR: no encontre profile con nombre exacto {args.profile_name!r}",
            file=sys.stderr,
        )
        return 1
    attrs = target["attributes"]
    print(
        f"\nProfile encontrado: id={target['id']}, "
        f"type={attrs['profileType']}, state={attrs['profileState']}"
    )

    # 4. profileContent ya viene en base64 en la respuesta
    profile_content_b64: str = attrs["profileContent"]
    profile_bytes = base64.b64decode(profile_content_b64)
    print(f"profileContent: {len(profile_bytes)} bytes")

    # 5. Guardar binario + base64
    safe_name = safe_filename(args.profile_name)
    profile_path = args.output_dir / f"{safe_name}.mobileprovision"
    base64_path = args.output_dir / f"{safe_name}_BASE64.txt"

    profile_path.write_bytes(profile_bytes)
    base64_path.write_text(profile_content_b64)

    print(f"\nGuardado: {profile_path}")
    print(f"Base64 listo para pegar en env var: {base64_path}")
    print(f"  ({len(profile_content_b64)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
