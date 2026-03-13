# Strategy: AI-Assisted Coding in a Secure Genomic Data Environment

## 1. Background and Goal

We operate in a **secure, network-isolated environment** handling sensitive genomic data donated by patients. Regulatory and institutional policy **prohibits sending any data outside the network**. This means cloud-based AI coding assistants (Claude Code via Anthropic API, GitHub Copilot, etc.) cannot be used as-is.

**Goal**: Deploy a local, self-hosted AI coding assistant that runs entirely within the secure perimeter, enabling developers and bioinformaticians to benefit from LLM-assisted coding without any data leaving the network.

**Candidate local model**: Qwen 3.5 (open-weight, Apache 2.0 license).

---

## 2. Assessment: Claude Code with Local LLM Backend

### 2.1 Can Claude Code use a local model?

**Officially: No.** Claude Code is designed exclusively for Anthropic's Claude models. It depends on:

- Anthropic's Messages API protocol (different from OpenAI's chat completions)
- Claude-specific features: tool use schema, extended thinking, prompt caching, structured outputs
- Hard-coded model ID validation (accepts only `claude-opus-*`, `claude-sonnet-*`, `claude-haiku-*`)

### 2.2 Community workarounds exist, but with caveats

| Approach | How it works | Maturity | Risk |
|----------|-------------|----------|------|
| **Ollama v0.14+** native Anthropic API | Ollama now speaks Anthropic Messages API natively. Set `ANTHROPIC_BASE_URL=http://localhost:11434` | Improving rapidly | Medium — feature parity gaps remain |
| **local-claude-code** | Community installer that rewires Claude Code to talk to any LLM server | Community-maintained | High — breaks on Claude Code updates |
| **LiteLLM proxy** | Translates between API formats, sits between Claude Code and local model | Mature proxy | Medium — extra moving part |

### 2.3 Known limitations when using non-Claude models

| Feature | Impact with local models |
|---------|------------------------|
| **Tool use (function calling)** | Core to Claude Code's agent loop. Qwen 3.5 supports tool calling, but schema differences may cause failures |
| **Extended thinking** | Claude-specific; will not work |
| **Prompt caching** | Claude-specific; will not work (higher latency expected) |
| **Context compaction** | Claude-specific automatic summarization; local models may hit context limits |
| **Vision / PDF reading** | Qwen 3.5 supports vision natively, but Claude Code's image handling may not map correctly |
| **Streaming** | Generally works, but edge cases with tool-use streaming |
| **Reliability of agent loop** | Claude Code's prompts are optimized for Claude's behavior. Other models may loop, hallucinate tool calls, or fail to recover from errors |

### 2.4 Verdict on Claude Code + Qwen 3.5

**Not recommended as primary strategy.** While technically possible via Ollama v0.14+ or local-claude-code, the experience will be degraded and fragile:

- The agent loop (gather context → take action → verify) is prompt-engineered for Claude models
- Tool calling schema mismatches cause silent failures
- No support from Anthropic; breakage on every Claude Code update
- Debugging issues in a secure environment with no internet access compounds the problem

This approach may be worth **experimenting with** but should not be relied upon for production use.

---

## 3. Recommended Strategy: Purpose-Built Local-First Tools

Instead of forcing Claude Code to work with local models, use tools **designed from the ground up** for local/air-gapped operation with model flexibility.

### 3.1 Recommended tool stack

#### Primary: Aider

- **Repository**: https://github.com/paul-gauthier/aider
- **License**: Apache 2.0
- **Why**: Mature, battle-tested terminal-based AI coding assistant. Works with any model via Ollama, including Qwen 3.5. Auto-creates Git commits. Maps entire codebases. Active community.
- **Local model support**: First-class. Ollama, llama.cpp, vLLM, LM Studio all supported.
- **Air-gapped**: Yes — no network calls needed once model is loaded locally.

#### Alternative: OpenCode

- **Repository**: https://github.com/opencode-ai/opencode
- **License**: MIT
- **Why**: Has an explicit **"Air-gapped Mode"** designed for regulated industries. Native terminal UI with LSP support. Multi-session. 75+ LLM provider support.
- **Local model support**: First-class Ollama integration.
- **Air-gapped**: Explicitly designed for it.

#### Alternative: Goose CLI

- **Why**: Full local control, offline-first design, persistent sessions. No cloud dependencies.
- **Air-gapped**: Yes — operates entirely on local machine.

### 3.2 Model selection: Qwen 3.5

Qwen 3.5 is a strong choice for this use case:

| Property | Value |
|----------|-------|
| **License** | Apache 2.0 (commercial use allowed) |
| **Architecture** | 397B params, 17B active per token (Mixture of Experts) |
| **Context window** | 262K tokens (extensible to 1M) |
| **Code benchmarks** | SWE-bench Verified 72.4 (27B model matches GPT-5 mini) |
| **Tool use** | BFCL-V4 72.2 (outperforms GPT-5 mini by 30%) |
| **Sizes available** | 0.6B, 1.5B, 4B, 9B, 27B, 72B, 122B-A10B, 397B-A17B |

**Recommended sizes by hardware**:

| Hardware | Recommended model | Quantization |
|----------|-------------------|-------------|
| Single RTX 4090 (24GB) | Qwen3.5-27B | Q4_K_M |
| 2x RTX 4090 (48GB) | Qwen3.5-72B | Q4_K_M |
| 4x A100 (320GB) or equivalent | Qwen3.5-397B-A17B | FP16/BF16 |
| CPU-only (128GB+ RAM) | Qwen3.5-9B | Q4_K_M |

Also consider **Qwen3-Coder-Next** — a coding-specialized variant with enhanced long-horizon reasoning and tool usage.

### 3.3 Model serving: Ollama or vLLM

| | Ollama | vLLM |
|---|--------|------|
| **Best for** | Single-machine, quick setup | Multi-GPU clusters, high throughput |
| **Setup complexity** | Low (single binary) | Medium (Python, CUDA deps) |
| **Anthropic API compat** | Yes (v0.14+) | Yes (native support) |
| **Quantization** | GGUF (Q4, Q5, Q8) | AWQ, GPTQ, FP16 |
| **Multi-user** | Limited | Built for it |
| **Air-gap friendly** | Yes — pre-download models | Yes — pre-download models |

**Recommendation**: Start with **Ollama** for simplicity. Move to **vLLM** if you need multi-user serving or higher throughput.

---

## 4. Deployment Architecture

```
┌─────────────────────────────────────────────────────────┐
│                  Secure Network Boundary                │
│                                                         │
│  ┌──────────────┐     ┌──────────────────────────────┐  │
│  │  Developer    │     │  Model Server                │  │
│  │  Workstation  │     │  (Ollama or vLLM)            │  │
│  │              │     │                              │  │
│  │  ┌─────────┐ │     │  ┌────────────────────────┐  │  │
│  │  │ Aider / │ │────▶│  │ Qwen 3.5 (27B/72B)    │  │  │
│  │  │ OpenCode│ │ API │  │ loaded in GPU memory   │  │  │
│  │  └─────────┘ │     │  └────────────────────────┘  │  │
│  │              │     │                              │  │
│  │  ┌─────────┐ │     │  GPU: RTX 4090 / A100       │  │
│  │  │ Code /  │ │     └──────────────────────────────┘  │
│  │  │ Data    │ │                                       │
│  │  └─────────┘ │     ┌──────────────────────────────┐  │
│  └──────────────┘     │  Optional: Claude Code       │  │
│                       │  (experimental, via Ollama    │  │
│                       │   Anthropic API compat)       │  │
│                       └──────────────────────────────┘  │
│                                                         │
│  ◉ No data leaves this boundary                         │
└─────────────────────────────────────────────────────────┘
```

---

## 5. Implementation Plan

### Phase 1: Infrastructure Setup (Week 1-2)

1. **Provision GPU server** within the secure network
   - Minimum: 1x RTX 4090 (24GB) for Qwen3.5-27B
   - Recommended: 2x RTX 4090 or 1x A100-80GB for Qwen3.5-72B
2. **Install Ollama** (air-gap install: download binary + model files externally, transfer via approved media)
   ```bash
   # On internet-connected machine:
   curl -fsSL https://ollama.com/install.sh -o ollama-install.sh
   ollama pull qwen3.5:27b    # downloads GGUF model files
   # Transfer ollama binary + ~/.ollama/models/ to secure environment
   ```
3. **Verify model serving** within secure network
   ```bash
   ollama serve &
   ollama run qwen3.5:27b "Write a Python function to parse a FASTQ file"
   ```

### Phase 2: Coding Tool Setup (Week 2-3)

1. **Install Aider** (pip install, can be done offline with pre-downloaded wheels)
   ```bash
   # On internet-connected machine:
   pip download aider-chat -d ./aider-wheels/
   # Transfer to secure env:
   pip install --no-index --find-links=./aider-wheels/ aider-chat
   ```
2. **Configure Aider to use local Ollama**
   ```bash
   aider --model ollama/qwen3.5:27b
   ```
3. **Test with representative bioinformatics tasks**:
   - Parse VCF/BAM/FASTQ files
   - Write Nextflow/Snakemake pipelines
   - Generate unit tests for analysis scripts
   - Refactor existing R/Python analysis code

### Phase 3: Optional Claude Code Experiment (Week 3-4)

1. **Set up Claude Code with Ollama** (experimental)
   ```bash
   export ANTHROPIC_BASE_URL=http://localhost:11434
   export ANTHROPIC_API_KEY=fake-key
   claude
   ```
2. **Evaluate**: Does the agent loop work? Do tool calls succeed? Compare quality vs Aider.
3. **Decision gate**: If Claude Code works acceptably, offer it as an alternative. If not, standardize on Aider/OpenCode.

### Phase 4: Team Rollout (Week 4-6)

1. **Document setup procedures** for the secure environment
2. **Create shared model server** if multiple developers need access (consider vLLM)
3. **Establish usage guidelines**: what data can be included in prompts (even locally, apply data minimization principles)
4. **Collect feedback** and iterate on model size / tool choice

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Qwen 3.5 quality insufficient for complex bioinformatics code | Medium | High | Start with 72B model; fall back to Qwen3-Coder-Next; benchmark on real tasks before rollout |
| Claude Code breaks with local models on update | High | Medium | Don't depend on it — use Aider/OpenCode as primary |
| GPU hardware unavailable in secure env | Low | High | CPU fallback with smaller model (9B); request GPU procurement early |
| Model hallucinations in analysis code | Medium | High | All LLM-generated code must be reviewed; never auto-execute on patient data |
| Sensitive data in model context window | Low | Low | Data stays local, but establish prompt hygiene guidelines |
| Ollama/vLLM vulnerabilities | Low | Medium | Pin versions; apply security patches via approved update process |

---

## 7. Recommendations Summary

1. **Do NOT rely on Claude Code + local models** as the primary solution. The integration is unofficial, fragile, and the experience is degraded. Use it as an optional experiment only.

2. **Use Aider or OpenCode** as the primary AI coding assistant. These tools are designed for local/air-gapped operation with arbitrary models.

3. **Use Qwen 3.5** as the local model. It has excellent code generation and tool-use benchmarks, Apache 2.0 license, and multiple size options. The 27B model is the sweet spot for single-GPU setups.

4. **Use Ollama** for model serving (simple single-user) or **vLLM** for multi-user deployments.

5. **Maintain strict code review discipline**. Local LLMs are helpful but not infallible — all generated code touching patient data must be human-reviewed.

---

## Appendix: Sources

- [Qwen 3.5 Developer Guide (NxCode)](https://www.nxcode.io/resources/news/qwen-3-5-developer-guide-api-visual-agents-2026)
- [Qwen 3.5 Architecture and Benchmarks (Medium)](https://medium.com/data-science-in-your-pocket/qwen-3-5-explained-architecture-upgrades-over-qwen-3-benchmarks-and-real-world-use-cases-af38b01e9888)
- [Qwen3.5-27B on HuggingFace](https://huggingface.co/Qwen/Qwen3.5-27B)
- [Qwen3-Coder-Next on HuggingFace](https://huggingface.co/Qwen/Qwen3-Coder-Next)
- [Claude Code Alternatives (DigitalOcean)](https://www.digitalocean.com/resources/articles/claude-code-alternatives)
- [OpenCode vs Claude Code (DataCamp)](https://www.datacamp.com/blog/opencode-vs-claude-code)
- [local-claude-code (GitHub)](https://github.com/marcomprado/local-claude-code)
- [Ollama Claude Code Integration](https://docs.ollama.com/integrations/claude-code)
- [vLLM Claude Code Integration](https://docs.vllm.ai/en/latest/serving/integrations/claude_code/)
- [Using Claude Code with Ollama (DataCamp Tutorial)](https://www.datacamp.com/tutorial/using-claude-code-with-ollama-local-models)
- [Claude Code LLM Gateway Documentation](https://code.claude.com/docs/en/llm-gateway.md)
