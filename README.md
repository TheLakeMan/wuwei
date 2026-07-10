# 無為 wuwei — agents that don't act until the act is proven safe

**wuwei** is a provably-gated agent runner for the [Rusty](https://github.com/TheLakeMan/rusty)
Lisp. It is a ReAct loop (LLM reasons → picks a tool → observes result) with a
hard **proof gate** in front of every side effect. An LLM can propose anything;
nothing runs until it has been *proven permitted*.

> 無為 — *action without forcing*. The agent that will not act until the act is allowed.

The whole thing is ~160 lines of pure Lisp with **zero new interpreter code** —
it sits entirely on checkers Rusty already ships (`certify-tool-chain`,
`safe-call`, `check-effects`).

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

## Quick start

wuwei needs the `rusty` interpreter on your PATH:

```bash
git clone https://github.com/TheLakeMan/rusty && cd rusty
cargo install --path . --bin rusty --root ~/.local   # puts `rusty` on PATH
```

Then, in this repo:

```bash
./run_tests.sh          # the deterministic proof-gate suite (no LLM)
```

To watch a real model drive the gate (needs a running `llama-server`-compatible
endpoint at `localhost:8080`; override with `RUSTY_LLM_URL`):

```bash
rusty demo-live.lisp
```

## The guarantee, made concrete

`gate-test.lisp` proves all of this on every run, with no LLM (fully
reproducible — it's the golden test):

| check | result |
|-------|--------|
| read-only registry under read-only budget | `certified` |
| registry containing `write-file` under read-only budget | **refused: effect-budget-exceeded** |
| a tool that writes but declares no effects | **refused: undeclared-effects** |
| in-sandbox read | `ok` |
| **read `/etc/passwd`** | **rejected: precondition violated** |
| call a tool not in the registry | **rejected: no such tool** |
| wrong number of arguments | **rejected: arity** |
| out-of-sandbox write | **rejected: precondition violated** |

The sandbox agent is *structurally incapable* of reading outside its sandbox,
and that's checked at the gate before any filesystem access — not enforced by
hoping the model behaves.

## Files

| file | what |
|------|------|
| `wuwei.lisp` | the gated runner — certification, dispatch, ReAct loop |
| `demo-tools.lisp` | filesystem tools (`deftool` wrappers over core builtins) |
| `gate-test.lisp` / `expected_gate.txt` | the deterministic golden test |
| `demo-live.lisp` | a live-LLM episode (benign + hostile goals) |
| `demo-shot.lisp` | the one-frame "watch it get rejected" demo |
| `run_tests.sh` | golden-file runner |

## Where wuwei fits

Robotics, untrusted-input agents, anything that touches real systems — see
**[USE_CASES.md](./USE_CASES.md)** for what it's perfect for (and what it isn't).

## License

Copyright (c) 2026 Nicholas Vermeulen. Licensed under the GNU Affero General
Public License v3 or later (**AGPL-3.0-or-later**) — see [LICENSE](./LICENSE).
Commercial licensing is available on inquiry.

☯ *Built on [Rusty](https://github.com/TheLakeMan/rusty). In memory of my brother.*
