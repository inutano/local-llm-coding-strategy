# Strategy: AI-Assisted Coding in a Secure Genomic Data Environment

> **[日本語版はこちら (strategy.ja.md)](strategy.ja.md)**

## 1. Background and Goal

We operate in **secure environments** handling sensitive genomic data donated by patients. We have two deployment scenarios with different constraints:

**Scenario A — Secure server (SSH/VPN)**:
- Inbound allowed: software packages can be downloaded into the environment
- Outbound prohibited: no data may be sent outside the network
- Access method: SSH via VPN only (CLI-based workflow)
- No sudo/admin access; no GPU may be available

**Scenario B — Air-gapped hospital environment (Windows 11)**:
- All network traffic blocked (inbound and outbound)
- Software must be brought in via USB or portable storage after institutional virus scanning
- Typically Windows 11 desktops; may or may not have a GPU
- Admin (elevated PowerShell) access may be available for installation only

In both scenarios, cloud-based AI coding assistants (Claude Code via Anthropic API, GitHub Copilot, etc.) cannot be used directly against code or data inside the environment.

**Goal**: Establish a hybrid workflow that combines a local AI coding agent (running inside the secure perimeter) with cloud-based Claude (used outside for planning), ensuring sensitive data never leaves the network while still leveraging the strongest available models for design and architecture decisions.

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

## 4. Hybrid Workflow: Claude (Outside) + Local Agent (Inside)

### 4.1 Core concept

Use each model where it's strongest:

- **Claude (cloud)**: High-level planning, algorithm design, pipeline architecture — tasks requiring the strongest reasoning, where only non-sensitive metadata is needed as input
- **Local agent + Qwen 3.5 (inside secure env)**: Code exploration, code generation, execution, testing — tasks requiring direct access to code and data

The human operator acts as the **data boundary checkpoint**, manually reviewing what information crosses the perimeter.

### 4.2 Workflow diagram

```
Outside (Your Laptop)                  Secure Environment (SSH/VPN)
========================               ============================

Step 0: PREPARE SURVEY
  Ask Claude to generate a
  targeted survey script, or
  use the provided survey.sh
           │
           │  survey script
           ▼
                                       Step 1: EXPLORE & COLLECT
                                         ./survey.sh /path/to/project > report.txt
                                         # or: aider > /ask describe structure
                                         #
                                         # Collects: schemas, file layouts,
                                         # column names, tool versions,
                                         # system specs. Auto-redacts
                                         # potential patient identifiers.
                                                    │
                                        ─ ─ HUMAN REVIEWS report ─ ─
                                                    │
           ┌────────────────────────────────────────┘
           │  metadata (human-reviewed)
           ▼
Step 2: PLAN WITH CLAUDE
  Paste survey report + requirements
  Claude returns:
  - Analysis plan
  - Code architecture
  - Step-by-step instructions
           │
           │  detailed instructions
           ▼
                                       Step 3: EXECUTE LOCALLY
                                         aider > /architect
                                         aider > paste Claude's plan
                                         Qwen 3.5 generates code
                                                    │
                                                    ▼
                                       Step 4: AUTO-TEST & LINT
                                         Aider runs tests/linters
                                         Simple errors: fix locally ──┐
                                         Complex errors: ─────┐      │
                                                    │         │      │
           ┌──────────────────────────────────────────┘      │
           │  error context                                   │
           ▼                                                  │
Step 5: DEBUG WITH CLAUDE              ◀──────────────────────┘
  (repeat from Step 2)

◉ Genomic data NEVER leaves            ◉ Only metadata + plans
  the secure boundary                    cross the boundary
```

### 4.3 What can cross the boundary (and what cannot)

Before starting, establish a clear data classification for what information the operator may bring outside:

| Category | Safe to bring out | NEVER bring out |
|----------|------------------|-----------------|
| **File structure** | Directory tree (`tree -L 2`), file formats and extensions (VCF, BAM, FASTQ, CSV) | File paths containing study/patient identifiers |
| **Data schema** | Generic column/field names (`chrom`, `pos`, `ref`, `alt`), schema definitions, data types | Column names that reveal patient conditions |
| **Data content** | Row/record counts, file sizes | Actual values — sequences, variants, phenotypes, even a single row |
| **Identifiers** | Public reference genome IDs (e.g., GRCh38) | Patient identifiers, sample IDs linked to patients |
| **Code** | Scripts, pipelines, configs (after review\*) | Hardcoded patient/study IDs, embedded sample data in test fixtures, comments referencing patients |
| **Software/config** | Software versions, tool configurations | Access credentials, API keys, internal hostnames |
| **Error output** | Error messages (after sanitizing) | Error messages containing data snippets or patient info |

\*Before bringing code out, review for: hardcoded paths with study/patient IDs, embedded sample data in test fixtures, comments referencing patients.

**Rule of thumb**: If it is derived from or linkable to individual patients, it must not leave the boundary. If you'd be uncomfortable posting it publicly, don't bring it out.

### 4.4 Role of each model in this workflow

| Step | Model | Why this model |
|------|-------|----------------|
| **0. Prepare survey** | Cloud Claude | Claude can generate a targeted survey script for the specific project, or the user runs the provided `survey.sh` |
| **1. Explore** | `survey.sh` + optionally Local Qwen 3.5 (via Aider `/ask`) | `survey.sh` collects system specs, file structure, schemas, and software inventory with built-in redaction. Aider `/ask` can supplement with project-specific exploration |
| **2. Plan** | Cloud Claude | Best reasoning for architecture and algorithm design; only sees metadata |
| **3. Execute** | Local Qwen 3.5 (via Aider `/architect` + `/code`) | Follows detailed instructions; needs file access to write code |
| **4. Test** | No model needed | Automated linting, unit tests, integration tests |
| **5. Debug** | Cloud Claude | Complex debugging benefits from strong reasoning; error context is typically safe to share |

**Key insight**: The local model doesn't need to be as capable as Claude. Since Claude provides detailed, step-by-step instructions, the local model's job is essentially "code generation from a detailed spec" — a much easier task than open-ended design. Even Qwen3.5-9B may suffice for step 3.

### 4.5 Optimizing the round-trip

The main cost of this workflow is the human round-trip between environments. To minimize iterations:

1. **Start with `survey.sh`**: Run `./survey.sh /path/to/project > report.txt` to automatically collect system specs, file structure, schemas, and software inventory — with built-in redaction of potential identifiers. For project-specific questions, supplement with Aider `/ask` or ask Claude (Step 0) to generate a targeted survey script
2. **Ask Claude for complete plans**: Request step-by-step instructions with code snippets, not vague guidance
3. **Use Aider's auto-test**: Configure linting and test suites so the local agent catches errors without a round-trip
4. **Batch changes**: Group related changes into a single plan rather than making one round-trip per small change
5. **Build up a local CLAUDE.md**: Accumulate project context in a local instructions file so future Claude sessions start with full context

---

## 5. Deployment Architecture

### 5.1 Scenario A — Secure server (SSH/VPN)

```
┌──────────────────────────────────────────────────────────┐
│                  Secure Network Boundary                 │
│                                                          │
│  ┌──────────────┐      ┌──────────────────────────────┐  │
│  │  SSH Session  │      │  Model Server                │  │
│  │  (Developer)  │      │  (Ollama)                    │  │
│  │               │      │                              │  │
│  │  ┌──────────┐ │      │  ┌────────────────────────┐  │  │
│  │  │ Aider    │ │─────▶│  │ Qwen 3.5 (9B-72B)     │  │  │
│  │  │          │ │ API  │  │ loaded in GPU memory   │  │  │
│  │  └──────────┘ │      │  └────────────────────────┘  │  │
│  │               │      │                              │  │
│  │  ┌──────────┐ │      │  GPU: RTX 4090 / A100       │  │
│  │  │ Code &   │ │      └──────────────────────────────┘  │
│  │  │ Data     │ │                                        │
│  │  └──────────┘ │  Inbound OK ▼    ▲ Outbound BLOCKED   │
│  └──────────────┘                                        │
│                                                          │
│  ◉ Genomic data never leaves this boundary               │
└──────────────────────────────────────────────────────────┘
         │ metadata (human-reviewed)        ▲ plans
         ▼                                  │
┌──────────────────────────────────────────────────────────┐
│  Outside (Developer's Laptop)                            │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Claude (cloud API or claude.ai)                 │    │
│  │  - Receives: file schemas, directory layouts,    │    │
│  │    code structure, error messages                │    │
│  │  - Returns: analysis plans, code architecture,   │    │
│  │    step-by-step implementation instructions      │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

### 5.2 Scenario B — Air-gapped hospital (USB transfer)

```
┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┐
  Internet-Connected PC (preparation)
│                                                          │
  1. Run download.sh
│    ├── Ollama installer (.exe / binary)                   │
     ├── Qwen 3.5 model blobs
│    ├── Python installer (.exe)                            │
     ├── Aider wheels (pip packages)
│    └── Generated install-offline script                   │
│                                                          │
└ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┬ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘
                      │  USB / portable storage
                      │  (virus-scanned per policy)
                      ▼
┌──────────────────────────────────────────────────────────┐
│           Hospital Network (fully air-gapped)            │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Windows 11 Desktop                              │    │
│  │                                                  │    │
│  │  install-offline.ps1 installs:                   │    │
│  │  ┌────────────┐  ┌───────────┐  ┌────────────┐  │    │
│  │  │ Python 3.x │  │ Ollama    │  │ Aider      │  │    │
│  │  └────────────┘  └─────┬─────┘  └──────┬─────┘  │    │
│  │                        │   localhost    │        │    │
│  │                   ┌────┴────────────────┘        │    │
│  │                   ▼                              │    │
│  │  ┌────────────────────────────────────────────┐  │    │
│  │  │ Qwen 3.5 (9B, CPU or GPU)                 │  │    │
│  │  │ Model blobs copied from USB               │  │    │
│  │  └────────────────────────────────────────────┘  │    │
│  └──────────────────────────────────────────────────┘    │
│                                                          │
│  ◉ No network — all inbound/outbound blocked             │
│  ◉ Genomic data never leaves this boundary               │
└──────────────────────────────────────────────────────────┘
         │ metadata (human carries out)     ▲ plans
         ▼                                  │
┌──────────────────────────────────────────────────────────┐
│  Outside (Developer's Laptop / separate PC)              │
│                                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  Claude (cloud API or claude.ai)                 │    │
│  │  Same hybrid workflow — human is the data ferry  │    │
│  └──────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

### 5.3 Maintenance and updates

The toolchain (Ollama, Aider, Qwen 3.5) will need periodic updates for bug fixes, security patches, and model improvements.

**Scenario A** (inbound network available):

```bash
# Update Ollama binary
curl -fsSL "https://ollama.com/download/ollama-linux-amd64" -o ~/.local/bin/ollama

# Update model (pulls only changed layers)
ollama pull qwen3.5:27b

# Update Aider
pip install --upgrade aider-chat    # or: pip install --user --upgrade aider-chat
```

**Scenario B** (air-gapped — re-run the bundle process):

1. On the internet-connected PC, re-run `./download.sh` with the same options — it will download the latest versions
2. Copy the new bundle to USB, virus-scan per policy
3. On the hospital machine, re-run `install-offline.ps1` (or `.sh`) — it will overwrite the previous installation

**Version pinning**: To ensure reproducibility, record installed versions after setup:

```bash
ollama --version                    # Ollama version
ollama list                         # Model tags and sizes
pip show aider-chat | grep Version  # Aider version
python3 --version                   # Python version
```

Store this output alongside project documentation so you can reproduce the exact environment if needed.

---

## 6. Implementation Plan

Two deployment scenarios are supported. Choose the matching path:

- **Scenario A** — Secure server with inbound network access (SSH/VPN). Use `install.sh`.
- **Scenario B** — Air-gapped hospital environment (no network, Windows 11). Use `download.sh` on an external PC, bring the bundle in via USB.

### Phase 1: Infrastructure Setup (Week 1-2)

1. **Provision a machine** within the secure environment
   - With GPU: RTX 4090 (24GB) for Qwen3.5-27B, or 2x RTX 4090 / A100-80GB for 72B
   - Without GPU: CPU-only with Qwen3.5-9B (slower but functional)
   - Note: sudo/admin access is **not** required for Scenario A (install.sh installs to `~/.local/bin`)
2. **Install the toolchain**

   **Scenario A** (secure server, inbound allowed):
   ```bash
   # install.sh downloads Ollama binary to ~/.local/bin (no sudo),
   # pulls the model, and installs Aider via pip:
   ./install.sh                    # Auto-detect GPU, default 27B model
   ./install.sh --model 9b --cpu   # CPU-only with smaller model
   ```

   **Scenario B** (air-gapped hospital, no network):
   ```bash
   # Step 1: On an internet-connected PC, download everything:
   ./download.sh                          # Default: Windows 11, 9b model
   ./download.sh --model 27b             # Larger model if GPU available
   ./download.sh --os linux              # Target Linux instead

   # Step 2: Copy the output directory to USB, virus-scan per institutional policy

   # Step 3: On the hospital machine, run the offline installer:
   # Windows (PowerShell as Admin):
   .\install-offline.ps1
   # Linux:
   bash install-offline.sh
   ```
3. **Verify model serving**
   ```bash
   ollama serve &
   ollama run qwen3.5:9b "Write a Python function to parse a FASTQ file"
   ```

### Phase 2: Hybrid Workflow Validation (Week 2-3)

1. **Launch Aider with local Ollama**
   ```bash
   aider --model ollama/qwen3.5:9b
   ```
2. **Test the hybrid workflow end-to-end** with a representative task:
   - Inside: Launch Aider, type `/ask describe the project structure and data schemas` in the Aider REPL
   - Outside: Paste the output to Claude, ask for an analysis plan
   - Inside: In Aider, type `/architect` to switch mode, then paste Claude's plan
   - Verify: Run tests, check generated code

### Phase 3: Workflow Refinement (Week 3-4)

1. **Establish the data boundary checklist** (Section 4.3) and get institutional approval
2. **Create a project CLAUDE.md** inside the secure env with persistent project context (use [templates/CLAUDE.md](templates/CLAUDE.md) as a starting point)
3. **Benchmark local model sizes**: Run `./benchmark.sh --models 9b,27b,72b` to compare latency and code quality across sizes (see [benchmark.sh](benchmark.sh))
4. **Optionally experiment with Claude Code + Ollama** as an alternative to Aider

### Phase 4: Team Rollout (Week 4-6)

1. **Document the hybrid workflow** for other team members
2. **Create shared model server** if multiple developers need access:
   - Switch from Ollama to **vLLM** for concurrent request handling and better GPU utilization
   - Install: `pip install vllm` (requires CUDA toolkit)
   - Serve: `vllm serve Qwen/Qwen3.5-27B --host 0.0.0.0 --port 8000`
   - Each developer points Aider at the shared server: `aider --model openai/qwen3.5 --api-base http://<server>:8000/v1`
   - See [vLLM documentation](https://docs.vllm.ai/) for multi-GPU, quantization, and scaling options
3. **Establish usage guidelines**: data boundary checklist, prompt hygiene, code review requirements
4. **Collect feedback** and iterate on model size / tool choice

---

## 7. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Operator accidentally brings sensitive data outside the boundary | Medium | **Critical** | Establish and enforce the data boundary checklist (Section 4.3); institutional review and approval of the checklist before starting |
| Round-trip latency slows development | High | Medium | Be thorough in context collection; ask Claude for complete plans; use Aider auto-test to resolve simple errors locally |
| Qwen 3.5 quality insufficient for instruction-following code generation | Low | Medium | In the hybrid workflow the local model only follows detailed instructions, not open-ended design — a much easier task. Benchmark 9B/27B/72B to find minimum viable size |
| Claude Code breaks with local models on update | High | Low | Don't depend on it — Aider is the primary tool |
| GPU hardware unavailable in secure env | Low | High | CPU fallback with Qwen3.5-9B (slower but functional); request GPU procurement early |
| Model hallucinations in generated code | Medium | High | All LLM-generated code must be reviewed; never auto-execute on patient data; auto-test catches many errors |
| Metadata leakage through error messages | Medium | Medium | Review error output before sharing with Claude; strip file paths, sample IDs, data snippets |
| Ollama/vLLM vulnerabilities | Low | Medium | Pin versions; update via inbound download when patches are available |
| **Scenario B**: USB transfer corruption or incomplete copy | Medium | High | Verify file checksums after copy; download.sh could generate a manifest with SHA-256 hashes; re-copy if model fails to load |
| **Scenario B**: Virus scanner quarantines model blobs | Medium | Medium | Large binary files (multi-GB GGUF blobs) may trigger heuristic detection; pre-clear with IT security team; whitelist the Ollama models directory |
| **Scenario B**: Windows path length or execution policy issues | Low | Medium | PowerShell execution policy may block install-offline.ps1 — run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`; keep file paths short to avoid 260-char limit |
| **Scenario B**: No package manager for dependency resolution | Low | Low | download.sh bundles all pip wheels; if additional Python packages are needed later, re-run download.sh with updated requirements |

---

## 8. Recommendations Summary

1. **Adopt the hybrid workflow**: Use Claude (cloud) for planning and design with non-sensitive metadata; use a local agent + Qwen 3.5 for code generation and execution inside the secure environment.

2. **Use Aider** as the primary local coding agent. Its `/ask` mode is ideal for Step 1 (exploration), `/architect` for Step 3 (instruction-following code generation), and auto-test/lint catches errors without round-trips.

3. **Use Qwen 3.5** as the local model. Since it only needs to follow detailed instructions (not do open-ended design), even the 9B-27B sizes may suffice. Benchmark before committing to hardware.

4. **Establish and get institutional approval for the data boundary checklist** (Section 4.3) before starting. This is the most important governance step.

5. **Use Ollama** for model serving — inbound downloads are permitted, so installation is straightforward.

6. **Maintain strict code review discipline**. All LLM-generated code touching patient data must be human-reviewed, regardless of which model generated it.

---

## Appendix A: Aider vs OpenCode for This Use Case

| | **Aider** (recommended) | **OpenCode** (alternative) |
|---|---|---|
| **Install in secure env** | `pip install aider-chat` | Single Go binary |
| **Git integration** | Auto-commits every AI edit — full audit trail | Manual commits |
| **Exploration mode** | `/ask` — summarize code without editing | Interactive TUI |
| **Instruction-following mode** | `/architect` — ideal for executing Claude's plans | Custom agents with per-task prompts |
| **Auto-test/lint** | Built-in — runs after every edit, self-fixes | Manual |
| **Maturity** | 3 years, battle-tested | ~10 months, fast-growing |
| **Offline/air-gapped** | Works, not a design focus | Explicit air-gapped mode (in progress) |

**Verdict**: Aider's `/ask` → `/architect` flow maps directly to our hybrid workflow steps. Auto-commit gives auditability for regulated data. OpenCode is a viable alternative if TUI experience or custom agents are priorities.

---

## Appendix B: Sources

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
