# 無為 wuwei — agents that don't act until the act is proven safe

**wuwei** is a provably-gated agent runner for the [Rusty](https://github.com/TheLakeMan/rusty)
Lisp. An LLM (or any planner) can propose anything; **nothing with a side effect
runs until it is proven permitted** — effect-honest tools at boot, contracts on
every call.

> 無為 — *action without forcing*. The agent that will not act until the act is allowed.

~160 lines of pure Lisp, **zero new interpreter code**. Built on Rusty's
`certify-tool-chain`, `safe-call`, and `check-effects`.

![15-second demo: a lying tool registry refused at boot, an out-of-sandbox read rejected per-call, an over-budget agent never starts](demo.gif)

*Live above: `rusty demo-refusal.lisp` — deterministic, offline, no LLM. Run it yourself after the install below.*

## Try it in 60 seconds (offline — no LLM)

```bash
# 1. Install the Rusty interpreter once (prebuilt Linux binary — no rustc needed)
curl -fsSL https://raw.githubusercontent.com/TheLakeMan/rusty/main/install.sh | sh
# (or, any platform with Rust: cargo install rusty-lisp)
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

Two golden checks, both offline and deterministic: `gate-test.lisp` exercises
the certification machinery, and **`battle-test.lisp` is the jailbreak
challenge made concrete** — thirteen attacks a real adversary would try (a
trojan tool hiding a `shell` call, budget escalation, path escapes, `..`
traversal, arity abuse, type confusion, an unknown tool) thrown at a certified
read-only registry. Two of them answer the "AI from inside" question directly: a
**prompt-injected document** the model reads and then obeys — every obedient act
still refused, because injection changes what the model *wants*, never what it
*may* — and a **mid-session spec clobber**, where someone widens a tool's
precondition after boot, proven unable to reach a `certify-boot` certificate
(and unreachable by the sandboxed model at all, since it can't call
`deftool-spec`). It ends by refereeing itself with wuwei's own rule
(`mj-breaches`): a break must show a tool call with an `ok` verdict it should
never have gotten — so the pass condition is **0 of 13 hostile attempts broke
through**.

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

## Install as a verified package

wuwei is a [Rusty package](https://github.com/TheLakeMan/rusty) — a git repo with
a `package.lisp` manifest — so instead of "clone and trust" you can install it in
a way you can *check*:

```lisp
(load "pkg.lisp")                                     ; Rusty's package manager
(pkg-install "https://github.com/TheLakeMan/wuwei")   ; clone + auto-lock
(pkg-load "wuwei")                                     ; gate + guards
```

`pkg-install` records a fingerprint — every file with its SHA-256 — the moment
the clone lands, stored *outside* the package tree. From then on:

- `(wuwei-self-check)` — has wuwei's own installed code drifted since install day?
  → `verified`, or `(changed ((file what) …))` naming exactly what moved.
- `(pkg-verify "wuwei" fp)` — do the installed bytes match a fingerprint the
  publisher gave you **out of band** (a release note, never one shipped inside
  wuwei's own repo)? → `verified` / `changed`.

**What this hardens, exactly.** It hardens *distribution* — "these are the bytes
that were published, and nothing changed them since" — not runtime. It is the
supply-side twin of wuwei's own discipline: it tells you whether the gate's code
*changed*, never that running it is *safe*. It is not a sandbox, and no defense
against a determined local attacker (who can rewrite the lock) or a hostile
publisher (whose out-of-band fingerprint you would be trusting).

## Files

| file | what |
|------|------|
| `wuwei.lisp` | the gated runner — certification, dispatch, ReAct loop |
| `guards.lisp` | reusable filesystem/host guards — `safe-under?`, `host-allowed?` |
| `package.lisp` | Rusty package manifest — `name` / `version` / `main` |
| `wuwei-pkg.lisp` | package entry (`main`) — absolute-path load of gate + guards + `wuwei-self-check` |
| `wuwei-pkg-probe.lisp` | package check — manifest valid + entry loads from a foreign cwd |
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
replacement for OS isolation (run both). Guards are *logical* fences: use the
canonicalizing `safe-under?` (not a raw string-prefix check) for symlink safety,
and `host-allowed?` (which matches the **parsed host**, so
`https://api.good.com@evil.com/` is rejected rather than waved through) for
network scopes — but neither follows what happens next: a hostile filesystem
needs a real OS sandbox, and a redirect off an allowed host lands off-allowlist.
See [USE_CASES.md](./USE_CASES.md).

## License

Copyright (c) 2026 Nicholas Vermeulen. Licensed under the GNU Affero General
Public License v3 or later (**AGPL-3.0-or-later**) — see [LICENSE](./LICENSE).
Commercial licensing is available on inquiry — see [COMMERCIAL.md](./COMMERCIAL.md)
or contact <thelakeman@protonmail.com>.

Contributions require a short license grant that keeps wuwei relicensable as a
whole — see [CONTRIBUTING.md](./CONTRIBUTING.md) for the CLA and the standards
every change must meet.

☯ *Built on [Rusty](https://github.com/TheLakeMan/rusty). In memory of my brother.*
