#!/bin/sh

# Xcode Cloud post-clone hook para macOS — paralelo al de iOS
# (ios/ci_scripts/ci_post_clone.sh). Apple corre este script
# automaticamente despues de clonar el repo en el Mac runner, ANTES
# del build de Xcode, SOLO cuando el workflow es para la plataforma
# macOS (porque vive bajo macos/ci_scripts/).
#
# Lo que hacemos:
#  1. Instalar Flutter (clone del SDK estable, version pineada).
#  2. Symlink a /usr/local/bin para que xcodebuild lo encuentre
#     en sus build phases (el PATH del shell no se propaga).
#  3. flutter pub get (deps Dart + genera Generated.xcconfig).
#  4. flutter precache --macos (baja el engine macOS).
#  5. cd macos && pod install (instala Pods).
#  6. Manual Signing: importa cert + profile desde env vars.
#
# Path estandar Apple: macos/ci_scripts/ci_post_clone.sh
# (al lado del Xcode workspace de macOS).

set -e

echo "===== Xcode Cloud post-clone macOS (Flutter setup) ====="

# 1. Instalar Flutter en HOME (unico path persistente entre passes)
# MISMA VERSION que iOS — mantener sincronizado con
# ios/ci_scripts/ci_post_clone.sh y .github/workflows/ci.yml.
FLUTTER_VERSION="3.41.7"
echo "==> Clonando Flutter SDK $FLUTTER_VERSION..."
git clone https://github.com/flutter/flutter.git -b "$FLUTTER_VERSION" --depth 1 "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

echo "==> Flutter version:"
flutter --version

# 2. Symlink global para que xcodebuild encuentre flutter en su build phase
echo "==> Creando symlink global a /usr/local/bin/flutter..."
mkdir -p /usr/local/bin
ln -sf "$HOME/flutter/bin/flutter" /usr/local/bin/flutter
ln -sf "$HOME/flutter/bin/dart" /usr/local/bin/dart
which flutter
flutter --version

# 2b. Instalar flutterfire CLI por consistencia con iOS — si en el futuro
# se activa Crashlytics macOS (build phase "FlutterFire: flutterfire
# upload-crashlytics-symbols") va a estar disponible. En macOS hoy no se
# corre, pero instalarlo no rompe nada y deja preparado el setup.
echo "==> Instalando flutterfire CLI..."
dart pub global activate flutterfire_cli
export PATH="$HOME/.pub-cache/bin:$PATH"
ln -sf "$HOME/.pub-cache/bin/flutterfire" /usr/local/bin/flutterfire
which flutterfire
flutterfire --version

# 3. Subir a la raiz del repo (Xcode Cloud nos deja en macos/)
echo "==> Yendo a la raiz del repo..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
pwd

# 4a. Mismo workaround SPM-vs-CocoaPods que iOS — Flutter SDK con SPM
# default rompe el build porque mezcla plugins SPM + CocoaPods. Forzar
# CocoaPods soluciona y es el modo "legacy estable".
echo "==> Forzando CocoaPods (desactivando SPM)..."
flutter config --no-enable-swift-package-manager

# 4. flutter pub get (crea macos/Flutter/Generated.xcconfig)
echo "==> flutter pub get..."
flutter pub get

# 5. Pre-cachear el engine macOS
echo "==> flutter precache --macos..."
flutter precache --macos

# 5b. Generar macos/Flutter/Generated.xcconfig.
#
# OJO (build 25 falló por esto): `flutter pub get` NO genera
# `macos/Flutter/Generated.xcconfig` aunque la app tenga macos/
# como plataforma. Sin ese archivo el xcodebuild del Archive falla
# porque no encuentra FLUTTER_ROOT / FLUTTER_APPLICATION_PATH.
#
# `flutter build macos --config-only` prepara el config sin
# compilar nada — exactamente lo que necesitamos pre-Xcode.
# (En iOS Apple lo genera transparente porque corre pod install
# desde ios/, y Flutter detecta y genera Generated.xcconfig en
# ese flujo. Para macOS hay que pedirlo explícito.)
echo "==> flutter build macos --config-only..."
flutter build macos --config-only

# 6. CocoaPods (workaround UTF-8 por si las moscas)
echo "==> pod install..."
cd macos
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
cd ..

# 7. Verificar Generated.xcconfig tenga FLUTTER_ROOT correcto
echo "==> Generated.xcconfig:"
cat macos/Flutter/Generated.xcconfig | grep -E "FLUTTER_ROOT|FLUTTER_APPLICATION_PATH"

# 8. Manual Signing setup (igual que iOS).
#
# Las 3 env vars necesarias en el workflow macOS de Xcode Cloud
# (App Store Connect -> tu app -> Xcode Cloud -> workflow -> Edit ->
# Custom Environment Variables, los 3 como "Secret"):
#   - MACOS_DIST_CERT_P12_BASE64     base64 de CoopertransMac.p12
#   - MACOS_DIST_CERT_P12_PASSWORD   passphrase del .p12
#   - MACOS_DIST_PROFILE_BASE64      base64 del .provisionprofile
if [ -n "$MACOS_DIST_CERT_P12_BASE64" ] && [ -n "$MACOS_DIST_CERT_P12_PASSWORD" ] && [ -n "$MACOS_DIST_PROFILE_BASE64" ]; then
    echo "==> Manual Signing detectado: importando cert + profile..."

    # Limpiamos whitespace (CRLF de Windows en el copy-paste rompe base64)
    CERT_B64_CLEAN=$(printf '%s' "$MACOS_DIST_CERT_P12_BASE64" | tr -d '\r\n\t ')
    PROFILE_B64_CLEAN=$(printf '%s' "$MACOS_DIST_PROFILE_BASE64" | tr -d '\r\n\t ')

    echo "   cert b64 length    : ${#CERT_B64_CLEAN} chars (raw ${#MACOS_DIST_CERT_P12_BASE64})"
    echo "   profile b64 length : ${#PROFILE_B64_CLEAN} chars (raw ${#MACOS_DIST_PROFILE_BASE64})"
    echo "   password length    : ${#MACOS_DIST_CERT_P12_PASSWORD} chars"

    if [ ${#CERT_B64_CLEAN} -lt 100 ]; then
        echo "ERROR: MACOS_DIST_CERT_P12_BASE64 vacio o muy corto (${#CERT_B64_CLEAN} chars). Revisar el secret en Xcode Cloud workflow."
        exit 1
    fi
    if [ ${#PROFILE_B64_CLEAN} -lt 100 ]; then
        echo "ERROR: MACOS_DIST_PROFILE_BASE64 vacio o muy corto (${#PROFILE_B64_CLEAN} chars). Revisar el secret en Xcode Cloud workflow."
        exit 1
    fi

    # Keychain temporal solo para este build
    KEYCHAIN_PATH="$HOME/build.keychain"
    KEYCHAIN_PASSWORD="ci-temp-$(date +%s)"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security default-keychain -s "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security set-keychain-settings -t 3600 -u "$KEYCHAIN_PATH"

    # Decode .p12 + import
    printf '%s' "$CERT_B64_CLEAN" | base64 --decode > "$HOME/cert.p12"
    CERT_SIZE=$(stat -f%z "$HOME/cert.p12" 2>/dev/null || wc -c < "$HOME/cert.p12")
    echo "   cert.p12 decoded   : $CERT_SIZE bytes"
    if [ "$CERT_SIZE" -lt 1000 ]; then
        echo "ERROR: cert.p12 decoded vacio o muy chico ($CERT_SIZE bytes). El base64 esta corrupto."
        exit 1
    fi

    security import "$HOME/cert.p12" \
        -P "$MACOS_DIST_CERT_P12_PASSWORD" \
        -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
    rm "$HOME/cert.p12"

    # Permitir codesign sin password prompt
    security set-key-partition-list -S apple-tool:,apple: \
        -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

    # Instalar el provisioning profile
    # NOTA: macOS Xcode 11+ usa la misma ruta que iOS para profiles
    # (~/Library/MobileDevice/Provisioning Profiles/) aunque el nombre
    # de la carpeta tenga "MobileDevice" por historia.
    PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILES_DIR"
    PROFILE_PATH="$PROFILES_DIR/Coopertrans_Movil_Mac_App_Store.provisionprofile"
    printf '%s' "$PROFILE_B64_CLEAN" | base64 --decode > "$PROFILE_PATH"
    PROFILE_SIZE=$(stat -f%z "$PROFILE_PATH" 2>/dev/null || wc -c < "$PROFILE_PATH")
    echo "   profile decoded    : $PROFILE_SIZE bytes"
    if [ "$PROFILE_SIZE" -lt 1000 ]; then
        echo "ERROR: profile decoded vacio o muy chico ($PROFILE_SIZE bytes). El base64 esta corrupto."
        exit 1
    fi

    echo "==> Manual Signing OK: cert importado + profile instalado."
else
    echo "==> Manual Signing skip (env vars no definidas — usando Auto Signing)."
fi

echo "===== Setup Flutter macOS completado, Xcode Cloud puede arrancar el build ====="
