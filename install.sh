#!/usr/bin/env bash
#
# install.sh — Set up a local AI coding environment in a secure server
#
# Installs: Ollama (model server) + Qwen 3.5 model + Aider (coding assistant)
#
# Usage:
#   ./install.sh              # Auto-detect GPU, install 27B model (default)
#   ./install.sh --model 9b   # Use a specific model size: 0.6b|1.5b|4b|9b|27b|72b
#   ./install.sh --cpu        # Force CPU-only mode (picks 9b model)
#   ./install.sh --skip-model # Install tools only, skip model download
#
# Requires: curl, python3 (3.9+), pip
# Environment: Inbound network allowed, outbound blocked (except approved)

set -euo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────────

MODEL_SIZE="27b"
FORCE_CPU=false
SKIP_MODEL=false
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"

# ─── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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
        --cpu)
            FORCE_CPU=true
            shift
            ;;
        --skip-model)
            SKIP_MODEL=true
            shift
            ;;
        --help|-h)
            head -14 "$0" | tail -10
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

# Validate model size
case "$MODEL_SIZE" in
    0.6b|1.5b|4b|9b|27b|72b) ;;
    *) error "Invalid model size: $MODEL_SIZE. Choose from: 0.6b, 1.5b, 4b, 9b, 27b, 72b" ;;
esac

# ─── Pre-flight checks ────────────────────────────────────────────────────────

info "Running pre-flight checks..."

# Check curl
command -v curl &>/dev/null || error "curl is required but not found"

# Check Python
if command -v python3 &>/dev/null; then
    PYTHON=python3
elif command -v python &>/dev/null; then
    PYTHON=python
else
    error "Python 3.9+ is required but not found"
fi

PY_VERSION=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PY_MAJOR=$($PYTHON -c 'import sys; print(sys.version_info.major)')
PY_MINOR=$($PYTHON -c 'import sys; print(sys.version_info.minor)')
if [[ "$PY_MAJOR" -lt 3 ]] || [[ "$PY_MAJOR" -eq 3 && "$PY_MINOR" -lt 9 ]]; then
    error "Python 3.9+ required, found $PY_VERSION"
fi
ok "Python $PY_VERSION"

# Check pip
$PYTHON -m pip --version &>/dev/null || error "pip is required but not found"
ok "pip available"

# ─── GPU detection ─────────────────────────────────────────────────────────────

detect_gpu() {
    if [[ "$FORCE_CPU" == true ]]; then
        echo "cpu"
        return
    fi

    if command -v nvidia-smi &>/dev/null; then
        GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ')
        GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        TOTAL_GPU_MEM=$((GPU_MEM * GPU_COUNT))
        echo "nvidia:${GPU_NAME}:${GPU_COUNT}:${TOTAL_GPU_MEM}"
    else
        echo "cpu"
    fi
}

GPU_INFO=$(detect_gpu)
if [[ "$GPU_INFO" == "cpu" ]]; then
    warn "No GPU detected (or --cpu specified). Using CPU-only mode."
    RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "unknown")
    info "System RAM: ${RAM_MB}MB"
    # Auto-downgrade model for CPU if user didn't explicitly pick a size
    if [[ "$MODEL_SIZE" == "27b" ]]; then
        MODEL_SIZE="9b"
        warn "Auto-downgraded model to ${MODEL_SIZE} for CPU-only mode (override with --model)"
    fi
else
    IFS=':' read -r GPU_TYPE GPU_NAME GPU_COUNT TOTAL_GPU_MEM <<< "$GPU_INFO"
    ok "GPU: ${GPU_NAME} x${GPU_COUNT} (${TOTAL_GPU_MEM}MB total VRAM)"

    # Suggest model size based on VRAM
    SUGGESTED_SIZE="$MODEL_SIZE"
    if [[ "$TOTAL_GPU_MEM" -lt 8000 ]]; then
        SUGGESTED_SIZE="4b"
    elif [[ "$TOTAL_GPU_MEM" -lt 16000 ]]; then
        SUGGESTED_SIZE="9b"
    elif [[ "$TOTAL_GPU_MEM" -lt 32000 ]]; then
        SUGGESTED_SIZE="27b"
    elif [[ "$TOTAL_GPU_MEM" -lt 80000 ]]; then
        SUGGESTED_SIZE="72b"
    fi

    if [[ "$SUGGESTED_SIZE" != "$MODEL_SIZE" ]]; then
        warn "With ${TOTAL_GPU_MEM}MB VRAM, recommended model is ${SUGGESTED_SIZE} (requested: ${MODEL_SIZE})"
        read -rp "Continue with ${MODEL_SIZE} anyway? [y/N] " yn
        case "$yn" in
            [Yy]*) ;;
            *) MODEL_SIZE="$SUGGESTED_SIZE"; info "Using ${MODEL_SIZE} instead" ;;
        esac
    fi
fi

MODEL_TAG="qwen3.5:${MODEL_SIZE}"
echo ""
info "Configuration:"
info "  Model:  ${MODEL_TAG}"
info "  Ollama: http://${OLLAMA_HOST}:${OLLAMA_PORT}"
echo ""

# ─── Step 1: Install Ollama ───────────────────────────────────────────────────

install_ollama() {
    info "Step 1/3: Installing Ollama..."

    if command -v ollama &>/dev/null; then
        OLLAMA_VERSION=$(ollama --version 2>&1 | grep -oP '[\d.]+' | head -1)
        ok "Ollama already installed (version ${OLLAMA_VERSION})"
        return 0
    fi

    # Install to ~/.local/bin (no sudo required)
    OLLAMA_BIN_DIR="${HOME}/.local/bin"
    mkdir -p "$OLLAMA_BIN_DIR"

    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64)  ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac

    OLLAMA_URL="https://ollama.com/download/ollama-linux-${ARCH}"
    info "Downloading Ollama binary to ${OLLAMA_BIN_DIR}/ollama ..."
    curl -fsSL "$OLLAMA_URL" -o "${OLLAMA_BIN_DIR}/ollama"
    chmod +x "${OLLAMA_BIN_DIR}/ollama"

    # Ensure ~/.local/bin is in PATH for this session
    if ! echo "$PATH" | tr ':' '\n' | grep -qx "$OLLAMA_BIN_DIR"; then
        export PATH="${OLLAMA_BIN_DIR}:${PATH}"
        warn "${OLLAMA_BIN_DIR} is not in your PATH. Added for this session."
        warn "Add to your shell profile: export PATH=\"${OLLAMA_BIN_DIR}:\$PATH\""
    fi

    command -v ollama &>/dev/null || error "Ollama installation failed"
    OLLAMA_VERSION=$(ollama --version 2>&1 | grep -oP '[\d.]+' | head -1)
    ok "Ollama installed (version ${OLLAMA_VERSION}) at ${OLLAMA_BIN_DIR}/ollama"
}

# ─── Step 2: Pull model ───────────────────────────────────────────────────────

pull_model() {
    if [[ "$SKIP_MODEL" == true ]]; then
        warn "Step 2/3: Skipping model download (--skip-model)"
        return 0
    fi

    info "Step 2/3: Pulling ${MODEL_TAG}... (this may take a while)"

    # Ensure ollama is serving
    if ! curl -sf "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" &>/dev/null; then
        info "Starting Ollama server..."
        ollama serve &>/dev/null &
        OLLAMA_PID=$!

        # Wait for server to be ready
        for i in $(seq 1 30); do
            if curl -sf "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" &>/dev/null; then
                break
            fi
            if [[ $i -eq 30 ]]; then
                error "Ollama server failed to start within 30 seconds"
            fi
            sleep 1
        done
        ok "Ollama server started (PID: ${OLLAMA_PID})"
    else
        ok "Ollama server already running"
    fi

    # Check if model is already downloaded
    if ollama list 2>/dev/null | grep -q "qwen3.5:${MODEL_SIZE}"; then
        ok "Model ${MODEL_TAG} already downloaded"
        return 0
    fi

    ollama pull "$MODEL_TAG"
    ok "Model ${MODEL_TAG} downloaded"
}

# ─── Step 3: Install Aider ────────────────────────────────────────────────────

install_aider() {
    info "Step 3/3: Installing Aider..."

    if command -v aider &>/dev/null; then
        AIDER_VERSION=$(aider --version 2>&1 | head -1)
        ok "Aider already installed (${AIDER_VERSION})"
        return 0
    fi

    # Use --user only if not in a virtual environment
    PIP_FLAGS=""
    if [[ -z "${VIRTUAL_ENV:-}" ]] && [[ -z "${CONDA_DEFAULT_ENV:-}" ]]; then
        PIP_FLAGS="--user"
    fi

    $PYTHON -m pip install $PIP_FLAGS aider-chat 2>&1 | tail -1
    ok "Aider installed"

    # Verify aider is in PATH
    if ! command -v aider &>/dev/null; then
        # Try common user bin locations
        for CANDIDATE in \
            "${HOME}/.local/bin" \
            "$($PYTHON -c 'import sysconfig; print(sysconfig.get_path("scripts", "posix_user"))' 2>/dev/null)"; do
            if [[ -n "$CANDIDATE" && -f "${CANDIDATE}/aider" ]]; then
                warn "Aider installed at ${CANDIDATE}/aider but not in PATH"
                warn "Add to your shell profile: export PATH=\"${CANDIDATE}:\$PATH\""
                break
            fi
        done
    fi
}

# ─── Run installation ─────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Local AI Coding Environment Setup"
echo "============================================"
echo ""

install_ollama
echo ""
pull_model
echo ""
install_aider

# ─── Smoke test ────────────────────────────────────────────────────────────────

echo ""
info "Running smoke test..."

# Verify Ollama is serving
if curl -sf "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    ok "Ollama server responding"
else
    warn "Ollama server not running. Start it with: ollama serve"
fi

# Verify model is available
if [[ "$SKIP_MODEL" != true ]] && ollama list 2>/dev/null | grep -q "qwen3.5:${MODEL_SIZE}"; then
    ok "Model ${MODEL_TAG} available"
fi

# Verify Aider
if command -v aider &>/dev/null; then
    ok "Aider available"
fi

# Check git config (Aider requires user.name and user.email for auto-commits)
GIT_NAME=$(git config --global user.name 2>/dev/null || true)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || true)
if [[ -z "$GIT_NAME" || -z "$GIT_EMAIL" ]]; then
    warn "Git user.name or user.email is not set. Aider auto-commit will fail."
    warn "Run the following to fix:"
    warn "  git config --global user.name \"Your Name\""
    warn "  git config --global user.email \"your@email.com\""
else
    ok "Git config: ${GIT_NAME} <${GIT_EMAIL}>"
fi

# Integration test: verify Aider can talk to Ollama and get a response
if [[ "$SKIP_MODEL" != true ]] && command -v aider &>/dev/null && \
   curl -sf "http://${OLLAMA_HOST}:${OLLAMA_PORT}/api/tags" &>/dev/null; then
    info "Running integration test (Aider → Ollama)..."
    TEST_DIR=$(mktemp -d)
    pushd "$TEST_DIR" > /dev/null
    git init -q && git config user.name "test" && git config user.email "test@test"
    RESPONSE=$(timeout 120 aider --model "ollama/${MODEL_TAG}" \
        --no-auto-commits --yes --message "Say hello in one word" 2>&1 | tail -5) || true
    popd > /dev/null
    rm -rf "$TEST_DIR"
    if [[ -n "$RESPONSE" && ! "$RESPONSE" =~ "error" && ! "$RESPONSE" =~ "Error" ]]; then
        ok "Integration test passed — Aider connected to Ollama successfully"
    else
        warn "Integration test: Aider may not be communicating with Ollama correctly"
        warn "Response: ${RESPONSE}"
        warn "Try manually: aider --model ollama/${MODEL_TAG}"
    fi
fi

# ─── Done ──────────────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo -e " ${GREEN}Installation complete!${NC}"
echo "============================================"
echo ""
echo " Quick start:"
echo ""
echo "   # Start Ollama server (if not running):"
echo "   ollama serve &"
echo ""
echo "   # Launch Aider with local model:"
echo "   aider --model ollama/${MODEL_TAG}"
echo ""
echo "   # Then inside the Aider REPL:"
echo "   #   /ask describe the project structure    (read-only exploration)"
echo "   #   /architect                             (switch to architect mode)"
echo "   #   paste Claude's plan here               (execute the plan)"
echo ""
echo " For more details, see strategy.md"
echo ""
