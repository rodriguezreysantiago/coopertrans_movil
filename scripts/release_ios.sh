#!/usr/bin/env bash
# Build iOS release con symbols Dart + upload de symbols (Dart + iOS dSYMs)
# a Sentry. Genera el .ipa listo para subir a App Store Connect.
#
# Solo Mac (Apple toolchain).
#
# Pre-requisitos (one-time, ver RUNBOOK seccion "Setup one-time"):
#   - flutter en PATH.
#   - Pod install hecho con workaround Ruby 4.0:
#       cd ios
#       LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install
#       cd ..
#   - DEVELOPMENT_TEAM seteado en ios/Runner.xcodeproj/project.pbxproj
#     (10 chars de tu cuenta Apple Developer, ej. ABCD123456).
#   - Provisioning profile configurado en Xcode (Target Runner ->
#     Signing & Capabilities -> Team selecciona tu cuenta).
#   - sentry-cli instalado:
#       brew install getsentry/tools/sentry-cli
#     o
#       npm install -g @sentry/cli
#   - Config Sentry (mismo token que Win, o uno propio):
#       git config sentry.org "coopertrans"
#       git config sentry.project "flutter"
#       git config sentry.authtoken "sntryu_..."
#
# Uso (desde la raiz del repo):
#   ./scripts/release_ios.sh
#   ./scripts/release_ios.sh --notes "Fix de tal cosa"
#   ./scripts/release_ios.sh --dry-run

set -e

# Colores para output (terminal Mac soporta ANSI siempre)
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No color

NOTES=""
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --notes) NOTES="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Flag desconocido: $1"; exit 1 ;;
    esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBSPEC="$REPO_ROOT/pubspec.yaml"
SYMBOLS_DIR="$REPO_ROOT/build/symbols"
IPA_PATH="$REPO_ROOT/build/ios/ipa"
ARCHIVE_PATH="$REPO_ROOT/build/ios/archive/Runner.xcarchive"
DSYMS_DIR="$ARCHIVE_PATH/dSYMs"

# --- 1. Leer version de pubspec.yaml ---------------------------------
VERSION=$(grep -E '^version:' "$PUBSPEC" | sed -E 's/^version:[[:space:]]*//')
if [ -z "$VERSION" ]; then
    echo -e "${RED}ERROR: No encuentro 'version:' en pubspec.yaml${NC}"
    exit 1
fi
TAG="v$VERSION"

echo -e "${CYAN}==========================================${NC}"
echo -e "${CYAN}RELEASE iOS: $TAG${NC}"
echo -e "${CYAN}==========================================${NC}"

# --- 2. Verificar git limpio + pusheado ------------------------------
cd "$REPO_ROOT"
DIRTY=$(git status --porcelain)
if [ -n "$DIRTY" ]; then
    echo -e "${YELLOW}ADVERTENCIA: hay cambios sin commitear:${NC}"
    echo "$DIRTY"
    read -p "¿Seguir igual? (s/N) " confirm
    if [ "$confirm" != "s" ] && [ "$confirm" != "S" ]; then
        exit 1
    fi
fi
UNPUSHED=$(git log --oneline '@{u}..HEAD' 2>/dev/null || true)
if [ -n "$UNPUSHED" ]; then
    echo -e "${YELLOW}ADVERTENCIA: hay commits sin pushear:${NC}"
    echo "$UNPUSHED"
    read -p "Hacer git push primero? (S/n) " confirm
    if [ "$confirm" != "n" ] && [ "$confirm" != "N" ]; then
        git push
    fi
fi

# --- 3. Build IPA con symbols ----------------------------------------
echo ""
echo -e "${CYAN}[1/4] Buildeando IPA release con symbols Dart...${NC}"
mkdir -p "$SYMBOLS_DIR"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  [DRY-RUN] flutter build ipa --release --obfuscate --split-debug-info=$SYMBOLS_DIR${NC}"
else
    flutter build ipa --release --obfuscate --split-debug-info="$SYMBOLS_DIR"
    if [ $? -ne 0 ]; then
        echo -e "${RED}flutter build ipa falló${NC}"
        exit 1
    fi
fi

# --- 4. Upload symbols Dart + dSYMs a Sentry (best-effort) -----------
echo ""
echo -e "${CYAN}[2/4] Subiendo symbols a Sentry (Dart + iOS dSYMs)...${NC}"

if ! command -v sentry-cli &> /dev/null; then
    echo -e "${YELLOW}  sentry-cli no esta instalado. Salto upload de symbols.${NC}"
    echo -e "  Para activarlo: brew install getsentry/tools/sentry-cli"
elif [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  [DRY-RUN] sentry-cli debug-files upload ...${NC}"
else
    SENTRY_ORG=$(git config --get sentry.org || echo "")
    SENTRY_PROJECT=$(git config --get sentry.project || echo "")
    SENTRY_TOKEN=$(git config --get sentry.authtoken || echo "")

    if [ -z "$SENTRY_ORG" ] || [ -z "$SENTRY_PROJECT" ] || [ -z "$SENTRY_TOKEN" ]; then
        echo -e "${YELLOW}  Falta config Sentry (sentry.org/project/authtoken). Salto upload.${NC}"
        echo -e "  Para activarlo: git config sentry.{org,project,authtoken}"
    else
        # 4a. Symbols Dart
        if [ -d "$SYMBOLS_DIR" ]; then
            echo -e "  Subiendo symbols Dart desde $SYMBOLS_DIR ..."
            sentry-cli debug-files upload \
                --auth-token "$SENTRY_TOKEN" \
                --org "$SENTRY_ORG" \
                --project "$SENTRY_PROJECT" \
                --include-sources \
                "$SYMBOLS_DIR" || echo -e "${YELLOW}  WARN: upload Dart symbols fallo${NC}"
        fi
        # 4b. iOS dSYMs (si existen)
        if [ -d "$DSYMS_DIR" ]; then
            echo -e "  Subiendo iOS dSYMs desde $DSYMS_DIR ..."
            sentry-cli debug-files upload \
                --auth-token "$SENTRY_TOKEN" \
                --org "$SENTRY_ORG" \
                --project "$SENTRY_PROJECT" \
                "$DSYMS_DIR" || echo -e "${YELLOW}  WARN: upload dSYMs fallo${NC}"
        else
            echo -e "${YELLOW}  No hay $DSYMS_DIR — Xcode no genero dSYMs en este build.${NC}"
        fi
        echo -e "${GREEN}  OK — symbols subidos.${NC}"
    fi
fi

# --- 5. Verificar que el IPA existe ----------------------------------
echo ""
echo -e "${CYAN}[3/4] Verificando IPA...${NC}"

if [ "$DRY_RUN" = true ]; then
    echo -e "${YELLOW}  [DRY-RUN] skip${NC}"
else
    IPA_FILE=$(find "$IPA_PATH" -maxdepth 1 -name '*.ipa' -print -quit 2>/dev/null || true)
    if [ -z "$IPA_FILE" ]; then
        echo -e "${RED}ERROR: no encontre el .ipa en $IPA_PATH${NC}"
        exit 1
    fi
    SIZE_MB=$(du -m "$IPA_FILE" | cut -f1)
    echo -e "${GREEN}  OK — IPA: $IPA_FILE ($SIZE_MB MB)${NC}"
fi

# --- 6. Instrucciones para subir a App Store Connect ----------------
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}OK IPA LISTO PARA APP STORE CONNECT${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
echo -e "${CYAN}Archivo:${NC}"
if [ "$DRY_RUN" = false ] && [ -n "$IPA_FILE" ]; then
    echo -e "  $IPA_FILE"
else
    echo -e "  $IPA_PATH/*.ipa"
fi
echo ""
echo -e "${CYAN}Proximos pasos manuales (subir el IPA):${NC}"
echo -e "  Opcion A — Transporter (app oficial de Apple, mas simple):"
echo -e "    1) Descargar Transporter desde App Store si no lo tenes."
echo -e "    2) Abrir Transporter, login con tu Apple ID."
echo -e "    3) Drag & drop el .ipa, click 'Deliver'."
echo -e ""
echo -e "  Opcion B — Xcode Organizer:"
echo -e "    1) Abrir Xcode -> Window -> Organizer."
echo -e "    2) Tab Archives -> seleccionar el archive de hoy."
echo -e "    3) Click 'Distribute App' -> 'App Store Connect' -> 'Upload'."
echo -e ""
echo -e "  Despues del upload (App Store Connect web):"
echo -e "    https://appstoreconnect.apple.com -> Mi app -> TestFlight"
echo -e "    Esperar a que Apple procese (10-30 min)."
echo -e "    Asignar el build a un grupo de testers internos / externos."
echo -e ""
