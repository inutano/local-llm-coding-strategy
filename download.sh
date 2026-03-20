#!/usr/bin/env bash
#
# download.sh — Download all software for offline installation in an air-gapped environment
#
# Run this on an internet-connected machine. It downloads Ollama, a Qwen 3.5
# model, Python, and Aider, then packages everything into a directory ready
# to copy onto a USB drive.
#
# Usage:
#   ./download.sh                              # Default: Windows 11, 9b model
#   ./download.sh --model 27b                  # Specify model size (0.8b|2b|4b|9b|27b)
#   ./download.sh --os linux                   # Target OS: windows|linux
#   ./download.sh --arch arm64                 # Target arch: amd64|arm64
#   ./download.sh --output /path/to/usb        # Output directory
#
# After download, copy the output directory to USB and run the install script
# on the target machine.
#
# Requires: curl, python3, pip, ollama (auto-installed if missing)

set -euo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────────

MODEL_SIZE="9b"
TARGET_OS="windows"
TARGET_ARCH="amd64"
OUTPUT_DIR=""
PYTHON_VERSION="3.12.9"

# ─── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            [[ $# -ge 2 ]] || error "--model requires a size argument (e.g., --model 9b)"
            MODEL_SIZE="$2"
            shift 2
            ;;
        --os)
            [[ $# -ge 2 ]] || error "--os requires an argument (windows|linux)"
            TARGET_OS="$2"
            shift 2
            ;;
        --arch)
            [[ $# -ge 2 ]] || error "--arch requires an argument (amd64|arm64)"
            TARGET_ARCH="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || error "--output requires a path argument"
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --help|-h)
            head -19 "$0" | tail -15
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

# Validate
case "$MODEL_SIZE" in
    0.8b|2b|4b|9b|27b) ;;
    *) error "Invalid model size: $MODEL_SIZE. Choose from: 0.8b, 2b, 4b, 9b, 27b" ;;
esac
case "$TARGET_OS" in
    windows|linux) ;;
    *) error "Invalid target OS: $TARGET_OS. Choose from: windows, linux" ;;
esac
case "$TARGET_ARCH" in
    amd64|arm64) ;;
    *) error "Invalid target arch: $TARGET_ARCH. Choose from: amd64, arm64" ;;
esac

MODEL_TAG="qwen3.5:${MODEL_SIZE}"
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="./airgap-bundle-${TARGET_OS}-${TARGET_ARCH}-qwen3.5-${MODEL_SIZE}"
fi

echo ""
echo "============================================"
echo " Air-Gap Bundle Downloader"
echo "============================================"
echo ""
info "Target OS:    ${TARGET_OS}"
info "Target Arch:  ${TARGET_ARCH}"
info "Model:        ${MODEL_TAG}"
info "Output:       ${OUTPUT_DIR}"
echo ""

# ─── Create output structure ──────────────────────────────────────────────────

mkdir -p "${OUTPUT_DIR}/ollama"
mkdir -p "${OUTPUT_DIR}/model"
mkdir -p "${OUTPUT_DIR}/python"
mkdir -p "${OUTPUT_DIR}/aider"

# ─── Step 1: Download Ollama ─────────────────────────────────────────────────

download_ollama() {
    info "Step 1/5: Downloading Ollama for ${TARGET_OS}/${TARGET_ARCH}..."

    case "${TARGET_OS}" in
        windows)
            OLLAMA_URL="https://ollama.com/download/OllamaSetup.exe"
            OLLAMA_FILE="${OUTPUT_DIR}/ollama/OllamaSetup.exe"
            if [[ -f "$OLLAMA_FILE" ]]; then
                ok "Ollama already downloaded"
                return 0
            fi
            curl -fSL "$OLLAMA_URL" -o "$OLLAMA_FILE"
            ok "Ollama downloaded ($(du -h "$OLLAMA_FILE" | cut -f1))"
            ;;
        linux)
            # Ollama distributes Linux as a .tar.zst archive containing bin/ollama + lib/ollama/
            OLLAMA_ARCHIVE="${OUTPUT_DIR}/ollama/ollama-linux-${TARGET_ARCH}.tar.zst"
            if [[ -f "$OLLAMA_ARCHIVE" ]]; then
                ok "Ollama archive already downloaded"
                return 0
            fi
            OLLAMA_URL="https://ollama.com/download/ollama-linux-${TARGET_ARCH}.tar.zst"
            curl -fSL "$OLLAMA_URL" -o "$OLLAMA_ARCHIVE"
            ok "Ollama archive downloaded ($(du -h "$OLLAMA_ARCHIVE" | cut -f1))"
            ;;
    esac
}

# ─── Step 2: Download model ──────────────────────────────────────────────────

download_model() {
    info "Step 2/5: Downloading model ${MODEL_TAG}... (this may take a long time)"

    # We need ollama running locally to pull the model
    ensure_local_ollama

    # Check if model already pulled
    if ollama list 2>/dev/null | grep -q "qwen3.5:${MODEL_SIZE}"; then
        info "Model already pulled locally"
    else
        ollama pull "$MODEL_TAG"
    fi

    # Copy only the requested model's files to the bundle.
    # Ollama stores models in ~/.ollama/models/ with this structure:
    #   manifests/registry.ollama.ai/<namespace>/<model>/<tag>  (JSON manifest)
    #   blobs/sha256-<hash>  (actual model layers)
    # Detect Ollama models directory: env var, user home, or systemd service location
    if [[ -n "${OLLAMA_MODELS:-}" && -d "$OLLAMA_MODELS" ]]; then
        : # already set
    elif [[ -d "${HOME}/.ollama/models" ]]; then
        OLLAMA_MODELS="${HOME}/.ollama/models"
    elif [[ -d "/usr/share/ollama/.ollama/models" ]]; then
        OLLAMA_MODELS="/usr/share/ollama/.ollama/models"
    else
        error "Ollama models directory not found. Set OLLAMA_MODELS env var."
    fi

    info "Copying model files for ${MODEL_TAG} to bundle..."

    # Copy the manifest file
    MANIFEST_DIR="manifests/registry.ollama.ai/library/qwen3.5"
    if [[ -d "${OLLAMA_MODELS}/${MANIFEST_DIR}" ]]; then
        mkdir -p "${OUTPUT_DIR}/model/${MANIFEST_DIR}"
        cp "${OLLAMA_MODELS}/${MANIFEST_DIR}/${MODEL_SIZE}" \
           "${OUTPUT_DIR}/model/${MANIFEST_DIR}/${MODEL_SIZE}"
    else
        error "Manifest not found for ${MODEL_TAG} at ${OLLAMA_MODELS}/${MANIFEST_DIR}"
    fi

    # Parse the manifest to find referenced blob digests, then copy only those blobs
    mkdir -p "${OUTPUT_DIR}/model/blobs"
    MANIFEST_FILE="${OLLAMA_MODELS}/${MANIFEST_DIR}/${MODEL_SIZE}"
    DIGESTS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
digests = set()
if 'config' in m:
    digests.add(m['config']['digest'])
for layer in m.get('layers', []):
    digests.add(layer['digest'])
for d in sorted(digests):
    print(d)
" "$MANIFEST_FILE" 2>/dev/null) || error "Failed to parse manifest"

    BLOB_COUNT=0
    for digest in $DIGESTS; do
        # Ollama stores blobs as sha256-<hex> (colon replaced with dash)
        blob_file=$(echo "$digest" | tr ':' '-')
        src="${OLLAMA_MODELS}/blobs/${blob_file}"
        if [[ -f "$src" ]]; then
            cp "$src" "${OUTPUT_DIR}/model/blobs/${blob_file}"
            BLOB_COUNT=$((BLOB_COUNT + 1))
        else
            warn "Blob not found: ${blob_file}"
        fi
    done
    ok "Model files copied: ${BLOB_COUNT} blobs ($(du -sh "${OUTPUT_DIR}/model/" | cut -f1))"
}

ensure_local_ollama() {
    if command -v ollama &>/dev/null; then
        ok "Local ollama available"
    else
        info "Installing ollama locally for model download..."
        curl -fsSL https://ollama.com/install.sh | sh
    fi

    # Ensure server is running
    if ! curl -sf "http://127.0.0.1:11434/api/tags" &>/dev/null; then
        info "Starting local ollama server..."
        ollama serve &>/dev/null &
        for i in $(seq 1 30); do
            if curl -sf "http://127.0.0.1:11434/api/tags" &>/dev/null; then
                break
            fi
            if [[ $i -eq 30 ]]; then
                error "Ollama server failed to start"
            fi
            sleep 1
        done
    fi
    ok "Local ollama server running"
}

# ─── Step 3: Download Python ─────────────────────────────────────────────────

download_python() {
    info "Step 3/5: Downloading Python ${PYTHON_VERSION} for ${TARGET_OS}/${TARGET_ARCH}..."

    case "${TARGET_OS}" in
        windows)
            case "${TARGET_ARCH}" in
                amd64) PY_ARCH="amd64" ;;
                arm64) PY_ARCH="arm64" ;;
            esac
            PY_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/python-${PYTHON_VERSION}-${PY_ARCH}.exe"
            PY_FILE="${OUTPUT_DIR}/python/python-${PYTHON_VERSION}-${PY_ARCH}.exe"
            ;;
        linux)
            # For Linux, we note that Python is typically pre-installed
            info "Linux targets typically have Python pre-installed. Skipping Python download."
            info "If needed, install via system package manager before running the offline installer."
            ok "Python download skipped (Linux)"
            return 0
            ;;
    esac

    if [[ -f "$PY_FILE" ]]; then
        ok "Python installer already downloaded"
        return 0
    fi

    curl -fSL "$PY_URL" -o "$PY_FILE"
    ok "Python installer downloaded ($(du -h "$PY_FILE" | cut -f1))"
}

# ─── Step 4: Download Aider wheels ───────────────────────────────────────────

download_aider() {
    info "Step 4/5: Downloading Aider and dependencies as wheels..."

    # Detect if we're building for the current platform or cross-platform
    CURRENT_ARCH=$(uname -m)
    case "$CURRENT_ARCH" in
        x86_64)  CURRENT_ARCH="amd64" ;;
        aarch64) CURRENT_ARCH="arm64" ;;
    esac

    if [[ "$TARGET_OS" == "linux" && "$TARGET_ARCH" == "$CURRENT_ARCH" ]]; then
        # Same platform — pip download without constraints (most reliable)
        info "Downloading wheels for current platform..."
        python3 -m pip download \
            --dest "${OUTPUT_DIR}/aider/" \
            aider-chat 2>&1 | tail -3 || true
    else
        # Cross-platform download — use platform constraints
        case "${TARGET_OS}" in
            windows)
                case "${TARGET_ARCH}" in
                    amd64) PIP_PLATFORM="win_amd64" ;;
                    arm64) PIP_PLATFORM="win_arm64" ;;
                esac
                ;;
            linux)
                case "${TARGET_ARCH}" in
                    amd64) PIP_PLATFORM="manylinux2014_x86_64" ;;
                    arm64) PIP_PLATFORM="manylinux2014_aarch64" ;;
                esac
                ;;
        esac

        PY_SHORT=$(echo "$PYTHON_VERSION" | cut -d. -f1-2 | tr -d '.')

        # Download platform-specific binary wheels
        info "Downloading platform-specific wheels (${PIP_PLATFORM}, Python ${PY_SHORT})..."
        python3 -m pip download \
            --dest "${OUTPUT_DIR}/aider/" \
            --platform "$PIP_PLATFORM" \
            --python-version "$PY_SHORT" \
            --only-binary=:all: \
            aider-chat 2>&1 | tail -3 || true

        # Download pure-Python packages separately
        info "Downloading pure-Python packages..."
        PURE_TMP=$(mktemp -d)
        python3 -m pip download \
            --dest "$PURE_TMP" \
            aider-chat 2>&1 | tail -3 || true

        # Copy only pure-Python wheels (none-any) that we don't already have
        for pkg in "$PURE_TMP"/*; do
            [[ -f "$pkg" ]] || continue
            base=$(basename "$pkg")
            if [[ "$base" == *"-none-any.whl" ]]; then
                if [[ ! -f "${OUTPUT_DIR}/aider/${base}" ]]; then
                    cp "$pkg" "${OUTPUT_DIR}/aider/" 2>/dev/null || true
                fi
            fi
        done
        rm -rf "$PURE_TMP"
    fi

    WHEEL_COUNT=$(find "${OUTPUT_DIR}/aider/" -name "*.whl" 2>/dev/null | wc -l)
    SDIST_COUNT=$(find "${OUTPUT_DIR}/aider/" \( -name "*.tar.gz" -o -name "*.zip" \) 2>/dev/null | wc -l)
    ok "Aider packages downloaded (${WHEEL_COUNT} wheels, ${SDIST_COUNT} sdists, $(du -sh "${OUTPUT_DIR}/aider/" | cut -f1))"
    if [[ "$SDIST_COUNT" -gt 0 ]]; then
        warn "Some packages are source distributions (.tar.gz) — the target machine may need a C compiler to install them"
    fi
}

# ─── Step 5: Generate offline install script ─────────────────────────────────

generate_install_script() {
    info "Step 5/5: Generating offline install script..."

    case "${TARGET_OS}" in
        windows)
            generate_windows_installer
            ;;
        linux)
            generate_linux_installer
            ;;
    esac
}

generate_windows_installer() {
    cat > "${OUTPUT_DIR}/install-offline.ps1" << 'PSEOF'
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Offline installer for local AI coding environment (Ollama + Qwen 3.5 + Aider)
.DESCRIPTION
    Run this script from the USB drive / copied bundle directory.
    Must be run as Administrator for Ollama installation.
#>

param(
    [switch]$SkipPython,
    [switch]$SkipOllama,
    [switch]$SkipAider,
    [switch]$SkipModel
)

$ErrorActionPreference = "Stop"
$BundleDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Offline AI Coding Environment Setup"        -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Install Python ──────────────────────────────────────────────────
if (-not $SkipPython) {
    $pyInstaller = Get-ChildItem "$BundleDir\python\python-*.exe" | Select-Object -First 1
    if ($pyInstaller) {
        # Check if Python is already installed
        $existingPython = Get-Command python -ErrorAction SilentlyContinue
        if ($existingPython) {
            $pyVer = & python --version 2>&1
            Write-Host "[OK]   Python already installed ($pyVer)" -ForegroundColor Green
        } else {
            Write-Host "[INFO] Installing Python from $($pyInstaller.Name)..." -ForegroundColor Blue
            # Silent install: add to PATH, install for all users
            Start-Process -Wait -FilePath $pyInstaller.FullName -ArgumentList `
                "/quiet", "InstallAllUsers=1", "PrependPath=1", "Include_pip=1"
            Write-Host "[OK]   Python installed" -ForegroundColor Green
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
        }
    } else {
        Write-Host "[WARN] No Python installer found in bundle/python/" -ForegroundColor Yellow
    }
}

# ── Step 2: Install Ollama ──────────────────────────────────────────────────
if (-not $SkipOllama) {
    $ollamaInstaller = Get-ChildItem "$BundleDir\ollama\OllamaSetup.exe" -ErrorAction SilentlyContinue
    if ($ollamaInstaller) {
        $existingOllama = Get-Command ollama -ErrorAction SilentlyContinue
        if ($existingOllama) {
            Write-Host "[OK]   Ollama already installed" -ForegroundColor Green
        } else {
            Write-Host "[INFO] Installing Ollama..." -ForegroundColor Blue
            Start-Process -Wait -FilePath $ollamaInstaller.FullName -ArgumentList "/silent"
            # Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + `
                        [System.Environment]::GetEnvironmentVariable("Path", "User")
            Write-Host "[OK]   Ollama installed" -ForegroundColor Green
        }
    } else {
        Write-Host "[WARN] No Ollama installer found in bundle/ollama/" -ForegroundColor Yellow
    }
}

# ── Step 3: Load model ─────────────────────────────────────────────────────
if (-not $SkipModel) {
    $modelDir = "$BundleDir\model"
    if (Test-Path $modelDir) {
        $ollamaHome = if ($env:OLLAMA_MODELS) { $env:OLLAMA_MODELS } `
                      else { "$env:USERPROFILE\.ollama\models" }

        Write-Host "[INFO] Copying model files to $ollamaHome ..." -ForegroundColor Blue
        if (-not (Test-Path $ollamaHome)) {
            New-Item -ItemType Directory -Path $ollamaHome -Force | Out-Null
        }
        Copy-Item -Path "$modelDir\*" -Destination $ollamaHome -Recurse -Force
        Write-Host "[OK]   Model files copied" -ForegroundColor Green
    } else {
        Write-Host "[WARN] No model directory found in bundle" -ForegroundColor Yellow
    }
}

# ── Step 4: Install Aider ──────────────────────────────────────────────────
if (-not $SkipAider) {
    $aiderDir = "$BundleDir\aider"
    if (Test-Path $aiderDir) {
        $existingAider = Get-Command aider -ErrorAction SilentlyContinue
        if ($existingAider) {
            Write-Host "[OK]   Aider already installed" -ForegroundColor Green
        } else {
            Write-Host "[INFO] Installing Aider from offline wheels..." -ForegroundColor Blue
            & python -m pip install --no-index --find-links "$aiderDir" aider-chat 2>&1 | `
                Select-Object -Last 3
            Write-Host "[OK]   Aider installed" -ForegroundColor Green
        }
    } else {
        Write-Host "[WARN] No aider wheels found in bundle/aider/" -ForegroundColor Yellow
    }
}

# ── Verify ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[INFO] Verifying installation..." -ForegroundColor Blue

$checks = @(
    @{ Name = "Python";  Cmd = "python --version" },
    @{ Name = "Ollama";  Cmd = "ollama --version" },
    @{ Name = "Aider";   Cmd = "aider --version" }
)

foreach ($check in $checks) {
    try {
        $result = Invoke-Expression $check.Cmd 2>&1 | Select-Object -First 1
        Write-Host "[OK]   $($check.Name): $result" -ForegroundColor Green
    } catch {
        Write-Host "[WARN] $($check.Name): not found in PATH" -ForegroundColor Yellow
    }
}

# Check git config (Aider requires user.name and user.email for auto-commits)
$gitName = git config --global user.name 2>$null
$gitEmail = git config --global user.email 2>$null
if (-not $gitName -or -not $gitEmail) {
    Write-Host "[WARN] Git user.name or user.email is not set. Aider auto-commit will fail." -ForegroundColor Yellow
    Write-Host "[WARN] Run: git config --global user.name 'Your Name'" -ForegroundColor Yellow
    Write-Host "[WARN] Run: git config --global user.email 'your@email.com'" -ForegroundColor Yellow
} else {
    Write-Host "[OK]   Git config: $gitName <$gitEmail>" -ForegroundColor Green
}

# ── Done ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " Installation complete!" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host " Quick start:"
Write-Host ""
Write-Host "   # Start Ollama (open a terminal):"
Write-Host "   ollama serve"
Write-Host ""
Write-Host "   # Open another terminal and launch Aider:"
PSEOF

    # Append the model tag dynamically (not inside the heredoc)
    echo "Write-Host \"   aider --model ollama/${MODEL_TAG}\"" >> "${OUTPUT_DIR}/install-offline.ps1"

    cat >> "${OUTPUT_DIR}/install-offline.ps1" << 'PSEOF'
Write-Host ""
Write-Host "   # Then inside the Aider REPL:"
Write-Host "   #   /ask describe the project structure    (read-only exploration)"
Write-Host "   #   /architect                             (switch to architect mode)"
Write-Host "   #   paste Claude's plan here               (execute the plan)"
Write-Host ""
PSEOF

    ok "Generated install-offline.ps1 (PowerShell)"
}

generate_linux_installer() {
    cat > "${OUTPUT_DIR}/install-offline.sh" << BASHEOF
#!/usr/bin/env bash
#
# install-offline.sh — Offline installer for air-gapped Linux environment
#
# Run this from the USB drive / copied bundle directory.

set -euo pipefail

BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "\${BLUE}[INFO]\${NC} \$*"; }
ok()    { echo -e "\${GREEN}[OK]\${NC}   \$*"; }
warn()  { echo -e "\${YELLOW}[WARN]\${NC} \$*"; }
error() { echo -e "\${RED}[ERROR]\${NC} \$*"; exit 1; }

BUNDLE_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
OLLAMA_BIN_DIR="\${HOME}/.local/bin"
MODEL_TAG="${MODEL_TAG}"

echo ""
echo "============================================"
echo " Offline AI Coding Environment Setup"
echo "============================================"
echo ""

# Step 1: Install Ollama from archive
info "Step 1/3: Installing Ollama..."
OLLAMA_ARCHIVE=\$(find "\${BUNDLE_DIR}/ollama" -name "*.tar.zst" 2>/dev/null | head -1)
if [[ -n "\$OLLAMA_ARCHIVE" ]]; then
    # Modern format: .tar.zst archive with bin/ollama + lib/ollama/
    command -v zstd &>/dev/null || error "zstd is required to extract Ollama archive. Install: sudo apt install zstd"
    OLLAMA_PREFIX="\${HOME}/.local"
    mkdir -p "\${OLLAMA_PREFIX}"
    zstd -d "\$OLLAMA_ARCHIVE" --stdout | tar xf - -C "\${OLLAMA_PREFIX}"
    export PATH="\${OLLAMA_PREFIX}/bin:\${PATH}"
    ok "Ollama installed to \${OLLAMA_PREFIX}/bin/ollama"
elif [[ -f "\${BUNDLE_DIR}/ollama/ollama" ]]; then
    # Legacy format: standalone binary
    mkdir -p "\$OLLAMA_BIN_DIR"
    cp "\${BUNDLE_DIR}/ollama/ollama" "\${OLLAMA_BIN_DIR}/ollama"
    chmod +x "\${OLLAMA_BIN_DIR}/ollama"
    export PATH="\${OLLAMA_BIN_DIR}:\${PATH}"
    ok "Ollama installed to \${OLLAMA_BIN_DIR}/ollama"
else
    error "Ollama binary not found in bundle/ollama/"
fi

# Step 2: Copy model files
info "Step 2/3: Copying model files..."
OLLAMA_MODELS="\${OLLAMA_MODELS:-\${HOME}/.ollama/models}"
if [[ -d "\${BUNDLE_DIR}/model" ]]; then
    mkdir -p "\${OLLAMA_MODELS}"
    cp -r "\${BUNDLE_DIR}/model/"* "\${OLLAMA_MODELS}/"
    ok "Model files copied to \${OLLAMA_MODELS}"
else
    warn "No model files found in bundle/model/"
fi

# Step 3: Install Aider from wheels
info "Step 3/3: Installing Aider..."
if [[ -d "\${BUNDLE_DIR}/aider" ]]; then
    python3 -m pip install --user --no-index --find-links "\${BUNDLE_DIR}/aider/" aider-chat 2>&1 | tail -1
    ok "Aider installed"
else
    warn "No aider wheels found in bundle/aider/"
fi

# Verify
echo ""
info "Verifying..."
command -v ollama &>/dev/null && ok "Ollama: \$(ollama --version 2>&1)" || warn "Ollama not in PATH"
command -v aider &>/dev/null && ok "Aider: \$(aider --version 2>&1 | head -1)" || warn "Aider not in PATH"

# Check git config (Aider requires user.name and user.email for auto-commits)
GIT_NAME=\$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=\$(git config --global user.email 2>/dev/null || true)
if [[ -z "\$GIT_NAME" || -z "\$GIT_EMAIL" ]]; then
    warn "Git user.name or user.email is not set. Aider auto-commit will fail."
    warn "Run: git config --global user.name 'Your Name'"
    warn "Run: git config --global user.email 'your@email.com'"
else
    ok "Git config: \${GIT_NAME} <\${GIT_EMAIL}>"
fi

echo ""
echo "============================================"
echo -e " \${GREEN}Installation complete!\${NC}"
echo "============================================"
echo ""
echo " Quick start:"
echo ""
echo "   ollama serve &"
echo "   aider --model ollama/\${MODEL_TAG}"
echo ""
echo "   # Then inside the Aider REPL:"
echo "   #   /ask describe the project structure"
echo "   #   /architect"
echo ""
BASHEOF

    chmod +x "${OUTPUT_DIR}/install-offline.sh"
    ok "Generated install-offline.sh (Bash)"
}

# ─── Run all steps ────────────────────────────────────────────────────────────

download_ollama
echo ""
download_model
echo ""
download_python
echo ""
download_aider
echo ""
generate_install_script

# ─── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo -e " ${GREEN}Bundle ready!${NC}"
echo "============================================"
echo ""
info "Bundle location: ${OUTPUT_DIR}"
info "Bundle size:     $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo ""
echo " Contents:"
echo ""
for f in "${OUTPUT_DIR}/"*; do
    base=$(basename "$f")
    if [[ -d "$f" ]]; then
        SIZE=$(du -sh "$f" | cut -f1)
        echo "   ${base}/  (${SIZE})"
    else
        SIZE=$(du -h "$f" | cut -f1)
        echo "   ${base}  (${SIZE})"
    fi
done
echo ""
echo " Next steps:"
echo "   1. Copy ${OUTPUT_DIR}/ to a USB drive"
echo "   2. Virus-scan the USB contents per your institution's policy"
echo "   3. On the target machine, run:"
case "${TARGET_OS}" in
    windows)
        echo "      PowerShell (as Admin): .\\install-offline.ps1"
        ;;
    linux)
        echo "      bash install-offline.sh"
        ;;
esac
echo ""
