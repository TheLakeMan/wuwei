# 無為 wuwei — agents that don't act until the act is proven safe

**wuwei** is a provably-gated agent runner for the [Rusty](https://github.com/TheLakeMan/rusty)
Lisp. An LLM (or any planner) can propose anything; **nothing with a side effect
runs until it is proven permitted** — effect-honest tools at boot, contracts on
every call.

> 無為 — *action without forcing*. The agent that will not act until the act is allowed.

~160 lines of pure Lisp, **zero new interpreter code**. Built on Rusty's
`certify-tool-chain`, `safe-call`, and `check-effects`.

## Try it in 60 seconds (offline — no LLM)

```bash
# 1. Install the Rusty interpreter once
git clone https://github.com/TheLakeMan/rusty && cd rusty
cargo install --path . --bin rusty --root ~/.local   # needs rustc; puts rusty on PATH
# ensure ~/.local/bin is on PATH

# 2. Clone wuwei and run the sandbox story
git clone https://github.com/TheLakeMan/wuwei && cd wuwei
rusty demo-sandbox.lisp
```

You should see, without any model:

| Moment | Result |
|--------|--------|
| Read-only registry + read-only budget | `certified` |
| Write tool under read-only budget | **refused** at boot |
| Effect-dishonest tool (writes, declares nothing) | **refused** |
| Read a file *inside* the sandbox | `ok` |
| Read `/etc/passwd` | **rejected** before the filesystem is touched |
| Write outside the sandbox | **rejected** |
| Audit of a boot refusal | empty — nothing ran |

That is the **agent sandbox** story: the model is not the authorization.

### Receipt — prove there is no breach (still offline)

```bash
rusty demo-receipt.lisp
```

Writes `fixtures/sandbox-audit.json` (the exact shape `audit-save` / mingjian
`mj-load` use). If a sibling [mingjian](https://github.com/TheLakeMan/mingjian)
checkout exists (`../mingjian`), it scores the audit in-process:

| Check | Result |
|-------|--------|
| `mj-verdict-counts` | 1 ok, 2 rejected |
| `mj-breaches` vs sandbox policy | **empty** — no jailbreak shown |
| Same audit + forged out-of-box `ok` | **smoking gun row** |

Standalone (only mingjian cloned): `cd mingjian && rusty demo-receipt.lisp`
(uses the same rows embedded, or the sibling fixture if present).

Proof suite (same guarantees, bit-identical golden file):

```bash
./run_tests.sh
```

### Optional: live model

Needs an OpenAI-compatible endpoint (default `http://localhost:8080/v1/chat/completions`).
Override with `RUSTY_LLM_URL` / `RUSTY_MODEL` / `RUSTY_LLM_TIMEOUT_SECS`.

```bash
rusty demo-shot.lisp    # one hostile step: watch the gate reject
rusty demo-live.lisp    # longer episode
```

## The problem

A normal tool-using agent does this:

```
LLM says: ACTION read-file /etc/passwd   →   the file is read.
```

The model's word *is* the authorization. Prompt-inject it, or just let it
hallucinate, and it acts. Rusty's own built-in `react-loop` works this way — it
looks up whatever tool the model names and runs it immediately.

## What wuwei does instead

Two proof layers, both refusing by default:

### Layer 1 — static certification, once, at boot (`certify-registry`)

Before the agent makes a *single* LLM call, every tool it could ever call must:

- **have a spec** (`deftool-spec`: param types, declared effects, precondition),
- **be effect-honest** — `check-effects` statically reads the tool's body and
  must find *nothing* beyond the effects it declares (a tool can't quietly
  `shell` while claiming to only read), and
- **fit the effect budget** — its declared effects must be a subset of what
  this agent is allowed to do.

Fail any one and the agent **refuses to start**. A read-only agent handed a
`write-file` tool never boots — no LLM call, no side effect, nothing.

### Layer 2 — per-call gating, every step (`gated-dispatch` → `safe-call`)

Every action the model chooses is routed through `safe-call`, which enforces
**arity + argument types + precondition** *before the tool body runs*. A
violation is caught and returned to the model as an `OBSERVATION[rejected]` — the
tool never fires on bad input, and the loop keeps going with that feedback.

```
                LLM picks ACTION ──► gated-dispatch
                                        │
  certify-registry  (ONCE, at boot)     ├─ tool in the certified registry?  no → rejected
   ├─ every tool has a spec              ├─ safe-call: arity + types + precondition
   ├─ effect-honest (check-effects)      │     violated → rejected (fed back as feedback)
   └─ effects ⊆ budget                   └─ only now does the tool body run
   fail → REFUSE TO START                caught → the runner never crashes
```

The result of a run is **data**: `(done <answer> <audit>)` where `<audit>` is a
list of `(step tool input verdict)` rows you can inspect, log, or checkpoint.

## Audit export — prove what the agent tried

Every run returns its audit as data: `(step tool input verdict)` rows.
`audit-of` extracts them from any result (a boot refusal's audit is honestly
empty — nothing ran), and `audit-save` persists them as a versioned-JSON
model file. That file is exactly what
**[mingjian](https://github.com/TheLakeMan/mingjian)** consumes: `mj-load`
it, run `mj-breaches` (a claimed jailbreak must show an `ok` verdict the
policy forbids — the smoking gun, as data), or `mj-audit->kg!` it for
knowledge-graph queries across runs.

`demo-receipt.lisp` is the copy-paste handoff: persist rows → `mj-breaches`.

**Stream it live.** Set an `*audit-sink*` (see `streaming-audit-file`) and the
runner hands each row to it the instant it is produced — the model file stays
mj-load-valid *after every step*, so mingjian can score a run mid-flight, not
only at exit.

## Hardening helpers

- **Refusal-recovery** — an agent that keeps proposing calls the gate rejects
  would otherwise burn every step to `max-steps`. When the last N rows are all
  rejections the loop halts early with `(halted stuck-refusing <audit>)` instead
  of spinning (`*max-consecutive-refusals*`, default 3; decided by the pure
  predicate `stuck-refusing?`).
- **Proof-writing macro** — `(defguard name p <body>)` registers a reusable
  safety predicate that gates on the resource (first arg) and fits a tool of
  **any arity**, so one guard serves a 1-arg `read-file` and a 2-arg
  `write-file` with no per-arity wrapper. Registered guards are inspectable data
  (`guards`, `guard-of`).

## Files

| file | what |
|------|------|
| `wuwei.lisp` | the gated runner — certification, dispatch, ReAct loop |
| `demo-tools.lisp` | filesystem tools (`deftool` wrappers over core builtins) |
| `gate-test.lisp` / `expected_gate.txt` | the deterministic golden test |
| `demo-sandbox.lisp` | **60s offline sandbox story** (no LLM) |
| `demo-receipt.lisp` | **audit → mingjian battle-test receipt** (no LLM) |
| `fixtures/sandbox-audit.json` | sample audit-save output (regenerated by demo-receipt) |
| `demo-live.lisp` | a live-LLM episode (benign + hostile goals) |
| `demo-shot.lisp` | the one-frame "watch it get rejected" demo |
| `run_tests.sh` | golden-file runner |

## Where wuwei fits

Robotics, untrusted-input agents, anything that touches real systems — see
**[USE_CASES.md](./USE_CASES.md)** for what it's perfect for (and what it isn't).

**Claim (narrow):** the allowlist can't lie — registry is effect-honest and
every call is precondition-checked. **Not claimed:** unjailbreakable AI, or a
replacement for OS isolation (run both).

## License

Copyright (c) 2026 Nicholas Vermeulen. Licensed under the GNU Affero General
Public License v3 or later (**AGPL-3.0-or-later**) — see [LICENSE](./LICENSE).
Commercial licensing is available on inquiry.

☯ *Built on [Rusty](https://github.com/TheLakeMan/rusty). In memory of my brother.*
