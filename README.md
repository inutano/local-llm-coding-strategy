# Local LLM Coding Strategy for Secure Genomic Data Environments

## Problem

We need AI-assisted coding in a secure environment that handles sensitive genomic patient data. The environment prohibits outbound network traffic, so cloud-based tools (Claude Code, GitHub Copilot) cannot directly access code or data inside the perimeter. Access is SSH-only via VPN; inbound downloads are permitted.

## What we investigated

### Can Claude Code work with local models?

We assessed using Claude Code with a local LLM backend (Qwen 3.5 via Ollama). **Conclusion: not recommended as a primary approach.** Claude Code is tightly coupled to Anthropic's Claude models — its agent loop, tool calling, extended thinking, and prompt caching are all Claude-specific. Community workarounds exist (Ollama v0.14+ Anthropic API compatibility, local-claude-code project, LiteLLM proxy) but the experience is fragile and unsupported.

### What should we use instead?

We evaluated local-first coding assistants designed for arbitrary model backends:

- **Aider** (recommended) — Mature (3yr), auto-commits every AI edit (audit trail), `/ask` mode for exploration, `/architect` mode for instruction-following code generation, auto-test/lint after edits
- **OpenCode** (alternative) — Richer TUI, single Go binary (easy to transfer), explicit air-gapped mode, custom agent system

### What local model?

**Qwen 3.5** — Apache 2.0 license, 397B params (17B active via MoE), SWE-bench 72.4 (27B matches GPT-5 mini), strong tool-use benchmarks. Available in sizes from 0.6B to 397B.

## Solution: Hybrid workflow

Rather than running everything locally with a weaker model, we use a **hybrid approach** that plays to each model's strengths:

```
Secure Environment (SSH)              Outside (Laptop)
========================              =================

1. EXPLORE with local agent    ──>    2. PLAN with Claude
   (Aider /ask + Qwen 3.5)              (paste metadata, get plan)
   Collect: schemas, file
   layouts, code structure

3. EXECUTE with local agent    <──    Claude returns step-by-step
   (Aider /architect + Qwen 3.5)     instructions

4. AUTO-TEST locally
   Simple errors: fix locally
   Complex errors: ──────────  ──>    5. DEBUG with Claude
```

The human operator acts as the **data boundary checkpoint** — only non-sensitive metadata (file schemas, directory layouts, code structure, error messages) crosses the perimeter. Genomic data never leaves.

## Repository contents

| File | Description |
|------|-------------|
| [strategy.md](strategy.md) | Full strategy document: assessments, architecture, data boundary checklist, implementation plan, risk assessment |
| [install.sh](install.sh) | Installation script: sets up Ollama + Qwen 3.5 + Aider with GPU auto-detection |

## Quick start

```bash
# On the secure server:
./install.sh                          # Auto-detect GPU, install 27B model
./install.sh --model 9b               # Or pick a specific size
./install.sh --cpu                    # CPU-only fallback

# Start coding:
ollama serve &
aider --model ollama/qwen3.5:27b     # Launch Aider with local model
```

## Key decisions

| Decision | Rationale |
|----------|-----------|
| Hybrid workflow over fully-local | Claude's reasoning is far superior for planning/architecture; local model only needs to follow detailed instructions |
| Aider over Claude Code | Designed for arbitrary models; auto-git-commit gives audit trail; `/ask` + `/architect` modes map directly to the workflow |
| Qwen 3.5 over other local models | Best open-weight code + tool-use benchmarks; Apache 2.0; flexible sizing |
| Ollama over vLLM | Simpler for single-user setup; native Anthropic API compat; easy install |
| Human as boundary checkpoint | Institutional requirement; prevents accidental data leakage; no automated data transfer across the perimeter |
