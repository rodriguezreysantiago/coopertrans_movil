#!/bin/sh

# Xcode Cloud post-clone hook para proyectos Flutter.
#
# Apple corre este script automaticamente despues de clonar el repo
# en su Mac runner (Apple Silicon), ANTES de iniciar el build de Xcode.
#
# Lo que hacemos aca:
#  1. Instalar Flutter (clone del SDK estable).
#  2. Symlink a /usr/local/bin/flutter para que xcodebuild lo encuentre
#     en sus build phases (el PATH del shell no se propaga).
#  3. flutter pub get (instala deps Dart + genera Generated.xcconfig).
#  4. flutter precache --ios (baja el engine iOS).
#  5. cd ios && pod install (instala los Pods de Cocoapods).
#
# Path estandar Apple: ios/ci_scripts/ci_post_clone.sh (al lado del Xcode workspace).

set -e

echo "===== Xcode Cloud post-clone (Flutter setup) ====="

# 1. Instalar Flutter en HOME (el unico path persistente entre passes)
# Flutter version PINEADA: sin pin, `-b stable` clona el HEAD del canal
# stable en cada run y un release breaking rompe el build sin warning.
# Build 14 ya fallo por esto (Flutter activo SPM por default ->
# "Module cloud_firestore not found"). Update manual cuando se decida
# adoptar nueva version + smoke test local antes. Mantener sincronizado
# con .github/workflows/ci.yml.
FLUTTER_VERSION="3.44.0"
echo "==> Clonando Flutter SDK $FLUTTER_VERSION..."
git clone https://github.com/flutter/flutter.git -b "$FLUTTER_VERSION" --depth 1 "$HOME/flutter"
export PATH="$HOME/flutter/bin:$PATH"

echo "==> Flutter version:"
flutter --version

# 2. Symlink global para que xcodebuild encuentre flutter en su build phase
#    El shell de xcodebuild NO hereda nuestro PATH, asi que necesitamos un
#    symlink en una ubicacion estandar del sistema. /usr/local/bin esta en
#    el PATH default de macOS.
echo "==> Creando symlink global a /usr/local/bin/flutter..."
mkdir -p /usr/local/bin
ln -sf "$HOME/flutter/bin/flutter" /usr/local/bin/flutter
ln -sf "$HOME/flutter/bin/dart" /usr/local/bin/dart
which flutter
flutter --version

# 2b. Instalar flutterfire CLI (lo necesita el Build Phase
# "FlutterFire: flutterfire upload-crashlytics-symbols" del pbxproj
# para subir los dSYMs a Firebase Crashlytics. Sin esto, el archive
# falla con "flutterfire: command not found".)
echo "==> Instalando flutterfire CLI (version PINEADA)..."
# Pin de version: sin pin, `activate` baja el ULTIMO de pub.dev en cada run y
# una version con flags cambiados de `upload-crashlytics-symbols` rompe el
# archive sin warning (misma clase de fragilidad que el pin de Flutter de
# arriba). Update manual + smoke test al adoptar una nueva.
dart pub global activate flutterfire_cli 1.3.2
export PATH="$HOME/.pub-cache/bin:$PATH"
ln -sf "$HOME/.pub-cache/bin/flutterfire" /usr/local/bin/flutterfire
which flutterfire
flutterfire --version

# 3. Subir a la raiz del repo (Xcode Cloud nos deja en ios/)
echo "==> Yendo a la raiz del repo..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
pwd

# 4a. FIX 2026-05-18 (Build 14 failure): Flutter SDK reciente trae
# Swift Package Manager activado por DEFAULT, lo que rompe el build
# porque divide los plugins entre SPM (Firebase, sentry, image_picker)
# y CocoaPods (printing, google_mlkit_*) — el `GeneratedPluginRegistrant.m`
# importa con `#import <cloud_firestore/...>` estilo CocoaPods y no
# encuentra el modulo porque Firebase se resolvio via SPM (que no
# esta declarado en el .pbxproj).
#
# Sintoma: "error: Module 'cloud_firestore' not found" + Archive
# trae solo 4 pods en lugar de los ~20 esperados.
#
# Fix: forzar a Flutter a usar SOLO CocoaPods (modo legacy). Hay
# que correrlo ANTES de `flutter pub get` porque `pub get` lee la
# config para decidir como generar `.flutter-plugins-dependencies`.
echo "==> Forzando CocoaPods (desactivando SPM)..."
flutter config --no-enable-swift-package-manager

# 4. flutter pub get (esto crea ios/Flutter/Generated.xcconfig, necesario para Xcode)
echo "==> flutter pub get..."
flutter pub get

# 5. Pre-cachear el engine iOS para que el build sea mas rapido
echo "==> flutter precache --ios..."
flutter precache --ios

# 6. CocoaPods (workaround UTF-8 por si las moscas)
echo "==> pod install..."
cd ios
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
cd ..

# 7. Verificar Generated.xcconfig tenga FLUTTER_ROOT correcto
echo "==> Generated.xcconfig:"
cat ios/Flutter/Generated.xcconfig | grep -E "FLUTTER_ROOT|FLUTTER_APPLICATION_PATH"

# 8. Manual Signing setup (opcional — solo si las env vars estan definidas)
#
# Workaround para cuentas Apple Developer recien aprobadas donde Apple Cloud
# no puede comunicarse con el portal Apple para generar profiles automatica-
# mente ("Communication with Apple failed: No profiles for X were found").
#
# Si las 3 env vars estan setadas, importamos el cert + profile pre-generados
# y dejamos que xcodebuild use Manual Signing.
#
# Setup en Xcode Cloud (App Store Connect -> tu app -> Xcode Cloud ->
# workflow -> Edit -> Custom Environment Variables):
#   - IOS_DIST_CERT_P12_BASE64       (Secret) — base64 del .p12 exportado del Keychain
#   - IOS_DIST_CERT_P12_PASSWORD     (Secret) — password con que se exporto el .p12
#   - IOS_DIST_PROFILE_BASE64        (Secret) — base64 del .mobileprovision bajado del portal Apple
if [ -n "$IOS_DIST_CERT_P12_BASE64" ] && [ -n "$IOS_DIST_CERT_P12_PASSWORD" ] && [ -n "$IOS_DIST_PROFILE_BASE64" ]; then
    echo "==> Manual Signing detectado: importando cert + profile..."

    # Diagnostico: el build 7 fallo con "base64: stdin: (null): error decoding"
    # porque el base64 pegado en App Store Connect tenia CRLF de Windows o
    # se trunco. Limpiamos whitespace + chequeamos tamano antes de decodear.
    CERT_B64_CLEAN=$(printf '%s' "$IOS_DIST_CERT_P12_BASE64" | tr -d '\r\n\t ')
    PROFILE_B64_CLEAN=$(printf '%s' "$IOS_DIST_PROFILE_BASE64" | tr -d '\r\n\t ')

    echo "   cert b64 length    : ${#CERT_B64_CLEAN} chars (raw ${#IOS_DIST_CERT_P12_BASE64})"
    echo "   profile b64 length : ${#PROFILE_B64_CLEAN} chars (raw ${#IOS_DIST_PROFILE_BASE64})"
    echo "   password length    : ${#IOS_DIST_CERT_P12_PASSWORD} chars"

    if [ ${#CERT_B64_CLEAN} -lt 100 ]; then
        echo "ERROR: IOS_DIST_CERT_P12_BASE64 vacio o muy corto (${#CERT_B64_CLEAN} chars). Revisar el secret en Xcode Cloud workflow."
        exit 1
    fi
    if [ ${#PROFILE_B64_CLEAN} -lt 100 ]; then
        echo "ERROR: IOS_DIST_PROFILE_BASE64 vacio o muy corto (${#PROFILE_B64_CLEAN} chars). Revisar el secret en Xcode Cloud workflow."
        exit 1
    fi

    # Crear keychain temporal solo para este build
    KEYCHAIN_PATH="$HOME/build.keychain"
    KEYCHAIN_PASSWORD="ci-temp-$(date +%s)"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security default-keychain -s "$KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    security set-keychain-settings -t 3600 -u "$KEYCHAIN_PATH"

    # Decodear .p12 e importar (printf '%s' evita newline final que corrompe base64)
    printf '%s' "$CERT_B64_CLEAN" | base64 --decode > "$HOME/cert.p12"
    CERT_SIZE=$(stat -f%z "$HOME/cert.p12" 2>/dev/null || wc -c < "$HOME/cert.p12")
    echo "   cert.p12 decoded   : $CERT_SIZE bytes"
    if [ "$CERT_SIZE" -lt 1000 ]; then
        echo "ERROR: cert.p12 decoded vacio o muy chico ($CERT_SIZE bytes). El base64 esta corrupto."
        exit 1
    fi

    security import "$HOME/cert.p12" \
        -P "$IOS_DIST_CERT_P12_PASSWORD" \
        -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
    rm "$HOME/cert.p12"

    # Permitir que codesign acceda al cert sin password prompt
    security set-key-partition-list -S apple-tool:,apple: \
        -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

    # Instalar el provisioning profile
    PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILES_DIR"
    PROFILE_PATH="$PROFILES_DIR/Coopertrans_Movil_App_Store.mobileprovision"
    printf '%s' "$PROFILE_B64_CLEAN" | base64 --decode > "$PROFILE_PATH"
    PROFILE_SIZE=$(stat -f%z "$PROFILE_PATH" 2>/dev/null || wc -c < "$PROFILE_PATH")
    echo "   profile decoded    : $PROFILE_SIZE bytes"
    if [ "$PROFILE_SIZE" -lt 1000 ]; then
        echo "ERROR: profile decoded vacio o muy chico ($PROFILE_SIZE bytes). El base64 esta corrupto."
        exit 1
    fi

    # Validar que el Name INTERNO del profile coincida con el
    # PROVISIONING_PROFILE_SPECIFIER del pbxproj ("Coopertrans Movil App
    # Store"). xcodebuild resuelve el profile por su Name interno (no por el
    # nombre de archivo): si el secret trae OTRO profile, el archive falla con
    # un error poco evidente. Abortamos acá con un mensaje claro. Best-effort:
    # si no se puede leer el Name, no abortamos.
    PROFILE_NAME=$(security cms -D -i "$PROFILE_PATH" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || echo "")
    EXPECTED_PROFILE_NAME="Coopertrans Movil App Store"
    if [ -n "$PROFILE_NAME" ] && [ "$PROFILE_NAME" != "$EXPECTED_PROFILE_NAME" ]; then
        echo "ERROR: el profile instalado tiene Name '$PROFILE_NAME' pero el pbxproj espera '$EXPECTED_PROFILE_NAME'. Revisar el secret IOS_DIST_PROFILE_BASE64."
        exit 1
    fi
    echo "   profile Name       : ${PROFILE_NAME:-(no se pudo leer, sigo)}"

    # ─── Profiles adicionales OPCIONALES (Ad Hoc + Development) ───────
    # Xcode Cloud SIEMPRE genera los 3 tipos de export-archive (App Store
    # + Ad Hoc + Development) en paralelo, independiente de la
    # "Preparacion de la distribucion" elegida en el workflow. Si solo
    # tenemos el profile App Store (caso original), los exports Ad Hoc
    # y Development fallan con "No profiles for 'com.coopertrans.movil'
    # were found" — son errores ruidosos en el log que NO afectan el
    # build (el app-store export sigue OK), pero molestan.
    #
    # Si las env vars IOS_ADHOC_PROFILE_BASE64 y IOS_DEV_PROFILE_BASE64
    # estan setadas, instalamos esos profiles tambien y los 3 exports
    # succeed. Sin las env vars, el comportamiento es identico al
    # anterior (solo App Store ok, los otros 2 fallan ruidosamente).
    #
    # Setup en Xcode Cloud (opcional):
    #   IOS_ADHOC_PROFILE_BASE64  (Secret) — base64 del .mobileprovision
    #     Ad Hoc bajado desde developer.apple.com/account/resources/profiles
    #   IOS_DEV_PROFILE_BASE64    (Secret) — base64 del .mobileprovision
    #     iOS App Development bajado del portal
    install_profile_optional() {
        local var_b64="$1"   # contenido base64 ya en variable
        local nombre="$2"    # nombre del archivo para guardar
        local etiqueta="$3"  # etiqueta legible para logs
        if [ -z "$var_b64" ]; then
            echo "   $etiqueta: skip (env var no seteada)"
            return 0
        fi
        local b64_clean
        b64_clean=$(printf '%s' "$var_b64" | tr -d '\r\n\t ')
        if [ ${#b64_clean} -lt 100 ]; then
            echo "   $etiqueta: ERROR base64 muy corto (${#b64_clean} chars), skip"
            return 0
        fi
        local out_path="$PROFILES_DIR/$nombre"
        printf '%s' "$b64_clean" | base64 --decode > "$out_path"
        local sz
        sz=$(stat -f%z "$out_path" 2>/dev/null || wc -c < "$out_path")
        if [ "$sz" -lt 1000 ]; then
            echo "   $etiqueta: ERROR profile decoded vacio ($sz bytes), skip"
            rm -f "$out_path"
            return 0
        fi
        echo "   $etiqueta: instalado ($sz bytes)"
    }
    install_profile_optional "$IOS_ADHOC_PROFILE_BASE64" \
        "Coopertrans_Movil_Ad_Hoc.mobileprovision" "Ad Hoc profile"
    install_profile_optional "$IOS_DEV_PROFILE_BASE64" \
        "Coopertrans_Movil_Development.mobileprovision" "Development profile"

    echo "==> Manual Signing OK: cert importado + profile(s) instalado(s)."
else
    echo "==> Manual Signing skip (env vars no definidas — usando Auto Signing)."
fi

echo "===== Setup Flutter completado, Xcode Cloud puede arrancar el build ====="
