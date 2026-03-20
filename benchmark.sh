#!/usr/bin/env bash
#
# benchmark.sh — Compare local model sizes on representative coding tasks
#
# Runs a set of coding prompts against each specified model size via Ollama
# and reports response quality and latency. Use this to find the minimum
# viable model size for the hybrid workflow (Step 3: instruction-following).
#
# Usage:
#   ./benchmark.sh                         # Default: test 9b and 27b
#   ./benchmark.sh --models 4b,9b,27b      # Specify sizes to compare
#   ./benchmark.sh --custom "your prompt"  # Add a custom prompt
#
# Requires: ollama (running), curl
# Note: Models must be pre-pulled (ollama pull qwen3.5:<size>)

set -euo pipefail

# ─── Defaults ──────────────────────────────────────────────────────────────────

MODELS="9b,27b"
CUSTOM_PROMPT=""
OLLAMA_HOST="${OLLAMA_HOST:-127.0.0.1}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_URL="http://${OLLAMA_HOST}:${OLLAMA_PORT}"
RESULTS_DIR="./benchmark-results"

# ─── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case $1 in
        --models)
            [[ $# -ge 2 ]] || error "--models requires a comma-separated list (e.g., 9b,27b)"
            MODELS="$2"
            shift 2
            ;;
        --custom)
            [[ $# -ge 2 ]] || error "--custom requires a prompt string"
            CUSTOM_PROMPT="$2"
            shift 2
            ;;
        --help|-h)
            head -16 "$0" | tail -12
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage."
            ;;
    esac
done

IFS=',' read -ra MODEL_SIZES <<< "$MODELS"

# ─── Pre-flight ────────────────────────────────────────────────────────────────

command -v curl &>/dev/null || error "curl is required"
curl -sf "${OLLAMA_URL}/api/tags" &>/dev/null || error "Ollama is not running at ${OLLAMA_URL}"

# Check which models are available
AVAILABLE_MODELS=()
for size in "${MODEL_SIZES[@]}"; do
    if ollama list 2>/dev/null | grep -q "qwen3.5:${size}"; then
        AVAILABLE_MODELS+=("$size")
    else
        warn "qwen3.5:${size} not pulled — skipping (run: ollama pull qwen3.5:${size})"
    fi
done

[[ ${#AVAILABLE_MODELS[@]} -gt 0 ]] || error "No requested models are available"

mkdir -p "$RESULTS_DIR"

# ─── Test prompts ──────────────────────────────────────────────────────────────
# These simulate Step 3 of the hybrid workflow: following detailed instructions
# from Claude to generate code. They are bioinformatics-flavored but generic.

declare -a PROMPT_NAMES
declare -a PROMPTS

PROMPT_NAMES+=("parse_vcf")
PROMPTS+=("Write a Python function called parse_vcf that reads a VCF file and returns a list of dictionaries. Each dictionary should have keys: chrom, pos, ref, alt, qual. Skip lines starting with #. Include type hints and a docstring.")

PROMPT_NAMES+=("fastq_stats")
PROMPTS+=("Write a Python function called fastq_stats that takes a FASTQ file path and returns a dictionary with: total_reads (int), mean_length (float), mean_quality (float). Use the formula: quality = -10 * log10(error_probability) where error_probability is derived from ASCII-33 Phred scores. Do not use external libraries.")

PROMPT_NAMES+=("snakemake_rule")
PROMPTS+=("Write a Snakemake rule called 'align_reads' that: 1) takes input files {sample}.R1.fastq.gz and {sample}.R2.fastq.gz, 2) produces output {sample}.sorted.bam, 3) uses 8 threads, 4) runs bwa mem piped to samtools sort. Include a log directive.")

PROMPT_NAMES+=("refactor")
PROMPTS+=("Refactor this Python code to use pathlib instead of os.path, add error handling for missing files, and add type hints:

import os
def get_samples(data_dir):
    samples = []
    for f in os.listdir(data_dir):
        if f.endswith('.fastq.gz'):
            name = f.replace('.R1.fastq.gz', '').replace('.R2.fastq.gz', '')
            if name not in samples:
                samples.append(name)
    return sorted(samples)")

PROMPT_NAMES+=("unit_test")
PROMPTS+=("Write pytest unit tests for a function with this signature:

def filter_variants(variants: list[dict], min_qual: float = 30.0, chrom: str | None = None) -> list[dict]

Each variant dict has keys: chrom, pos, ref, alt, qual. Test: filtering by quality, filtering by chromosome, combining both filters, empty input, and edge case where qual equals min_qual exactly.")

if [[ -n "$CUSTOM_PROMPT" ]]; then
    PROMPT_NAMES+=("custom")
    PROMPTS+=("$CUSTOM_PROMPT")
fi

NUM_PROMPTS=${#PROMPTS[@]}

# ─── Run benchmarks ───────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Model Benchmark"
echo "============================================"
echo ""
info "Models:  ${AVAILABLE_MODELS[*]}"
info "Prompts: ${NUM_PROMPTS}"
info "Output:  ${RESULTS_DIR}/"
echo ""

# CSV header
SUMMARY_FILE="${RESULTS_DIR}/summary.csv"
echo "model,prompt,time_seconds,response_length,tokens_per_second" > "$SUMMARY_FILE"

for size in "${AVAILABLE_MODELS[@]}"; do
    MODEL_TAG="qwen3.5:${size}"
    echo ""
    echo -e "${CYAN}━━━ Model: ${MODEL_TAG} ━━━${NC}"

    # Warm up: ensure model is loaded into memory
    info "Warming up ${MODEL_TAG}..."
    curl -sf "${OLLAMA_URL}/api/generate" \
        -d "{\"model\":\"${MODEL_TAG}\",\"prompt\":\"hi\",\"stream\":false}" \
        > /dev/null 2>&1 || true

    for i in $(seq 0 $((NUM_PROMPTS - 1))); do
        PNAME="${PROMPT_NAMES[$i]}"
        PROMPT="${PROMPTS[$i]}"

        info "  [${PNAME}] Running..."

        OUTPUT_FILE="${RESULTS_DIR}/${size}_${PNAME}.txt"
        RESPONSE_FILE=$(mktemp)

        # Time the request
        START_TIME=$(date +%s%N)

        HTTP_CODE=$(curl -sf -w "%{http_code}" -o "$RESPONSE_FILE" \
            "${OLLAMA_URL}/api/generate" \
            -d "$(python3 -c "
import json, sys
print(json.dumps({
    'model': '${MODEL_TAG}',
    'prompt': sys.argv[1],
    'stream': False,
    'options': {'temperature': 0.1, 'num_predict': 2048}
}))
" "$PROMPT")" 2>/dev/null) || HTTP_CODE="000"

        END_TIME=$(date +%s%N)
        ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))
        ELAPSED_S=$(python3 -c "print(f'{${ELAPSED_MS}/1000:.1f}')")

        if [[ "$HTTP_CODE" == "200" ]]; then
            # Extract response text and metrics
            RESPONSE_TEXT=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
print(data.get('response', ''))
" "$RESPONSE_FILE" 2>/dev/null) || RESPONSE_TEXT=""

            RESPONSE_LEN=${#RESPONSE_TEXT}

            # Extract tokens/second from Ollama metrics
            TPS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
eval_count = data.get('eval_count', 0)
eval_duration = data.get('eval_duration', 1)
tps = eval_count / (eval_duration / 1e9) if eval_duration > 0 else 0
print(f'{tps:.1f}')
" "$RESPONSE_FILE" 2>/dev/null) || TPS="0"

            # Save full response
            echo "$RESPONSE_TEXT" > "$OUTPUT_FILE"

            # Append to CSV
            echo "${size},${PNAME},${ELAPSED_S},${RESPONSE_LEN},${TPS}" >> "$SUMMARY_FILE"

            ok "  [${PNAME}] ${ELAPSED_S}s | ${RESPONSE_LEN} chars | ${TPS} tok/s"
        else
            warn "  [${PNAME}] Failed (HTTP ${HTTP_CODE})"
            echo "${size},${PNAME},${ELAPSED_S},0,0" >> "$SUMMARY_FILE"
        fi

        rm -f "$RESPONSE_FILE"
    done
done

# ─── Summary table ─────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo " Results Summary"
echo "============================================"
echo ""

# Print a comparison table
python3 -c "
import csv, sys
from collections import defaultdict

with open(sys.argv[1]) as f:
    rows = list(csv.DictReader(f))

if not rows:
    print('No results.')
    sys.exit(0)

models = sorted(set(r['model'] for r in rows))
prompts = sorted(set(r['prompt'] for r in rows))

# Header
header = f\"{'prompt':<15}\"
for m in models:
    header += f\" | {m:>20}\"
print(header)
print('-' * len(header))

# Per-prompt rows
for p in prompts:
    line = f'{p:<15}'
    for m in models:
        match = [r for r in rows if r['model'] == m and r['prompt'] == p]
        if match:
            r = match[0]
            line += f\" | {r['time_seconds']:>6}s {r['tokens_per_second']:>6} t/s\"
        else:
            line += f\" | {'—':>20}\"
    print(line)

# Averages
print('-' * len(header))
line = f\"{'AVERAGE':<15}\"
for m in models:
    m_rows = [r for r in rows if r['model'] == m and float(r['time_seconds']) > 0]
    if m_rows:
        avg_time = sum(float(r['time_seconds']) for r in m_rows) / len(m_rows)
        avg_tps = sum(float(r['tokens_per_second']) for r in m_rows) / len(m_rows)
        line += f\" | {avg_time:>6.1f}s {avg_tps:>6.1f} t/s\"
    else:
        line += f\" | {'—':>20}\"
print(line)
" "$SUMMARY_FILE"

echo ""
info "Full responses saved to ${RESULTS_DIR}/"
info "CSV data: ${SUMMARY_FILE}"
echo ""
echo " Review the generated code in ${RESULTS_DIR}/<size>_<prompt>.txt"
echo " to judge quality, not just speed. A model that produces correct code"
echo " in 30s is better than one that produces wrong code in 5s."
echo ""
