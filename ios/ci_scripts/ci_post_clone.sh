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
echo "==> Clonando Flutter SDK..."
git clone https://github.com/flutter/flutter.git -b stable --depth 1 "$HOME/flutter"
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

# 3. Subir a la raiz del repo (Xcode Cloud nos deja en ios/)
echo "==> Yendo a la raiz del repo..."
cd "$CI_PRIMARY_REPOSITORY_PATH"
pwd

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

echo "===== Setup Flutter completado, Xcode Cloud puede arrancar el build ====="
