# What wuwei is perfect for

wuwei matters wherever an LLM agent can cause **real effects** and you need a
*proof* — not a hope — that it stays inside its bounds. The stronger the
consequences of a wrong action, the more the gate earns its place.

## Ideal fits

### 🤖 Robotics & physical control
The highest-stakes case: an actuator command that shouldn't fire has real-world
consequences. wuwei gates every tool/actuator call through a precondition
(bounds, allowed states) **before it executes**, and refuses to run any
controller whose tools exceed their declared effects. It composes directly with
[Rusty's `robot.lisp`](https://github.com/TheLakeMan/rusty), which *inductively
proves* a controller safe over every reachable state — so you get both halves:
the controller is proven safe, **and** every LLM-proposed command is
contract-checked against actuator limits before it moves anything. An LLM can
plan; it can never drive the motor past its bounds.

### 📥 Untrusted-input agents (prompt-injection exposure)
Agents that read email, web pages, PDFs, tickets, or user messages are attacker
territory — the input *is* the injection. wuwei neutralizes the
[lethal trifecta](https://simonwillison.net/tags/prompt-injection/) (private
data + untrusted input + an exfiltration path): the exfil tool call is rejected
at the gate before it fires, no matter what the injected text talked the model
into.

### 🖥️ Agents that touch real systems
Filesystem, shell, network, cloud APIs, databases. Give the agent a tight effect
budget and per-tool preconditions (path sandboxes, allow-listed hosts, read-only
scopes), and any call outside them is rejected — proven, not filtered.

### 🏢 Multi-tenant / customer-facing agents
Each tenant gets a registry certified to *their* effect boundary. A tool that
could reach another tenant's data fails certification, so the agent can't boot
mis-scoped in the first place.

### 📋 Regulated / audited environments
Every run returns an **audit trail** — `(step tool input verdict)` rows, as plain
data you can log, diff, or checkpoint. "Prove what the agent tried to do" is a
value you already have, not a forensic reconstruction.

### 🧩 Composing third-party / untrusted tools
Pulling tools from multiple sources? `certify-tool-chain` statically verifies
each one is honest about its effects and that dependencies resolve in order,
*before* the agent trusts any of them. The allowlist can't lie.

## What wuwei is *not*

- **Not a sandbox or OS-isolation replacement.** It's a proof gate, not a jail —
  run it *alongside* real isolation for defense in depth. The gate decides what's
  permitted; the sandbox contains what goes wrong anyway.
- **Not content moderation.** It doesn't judge what the model *says*, only what
  it's allowed to *do*. The model can propose anything; the effect is what's
  gated.
- **Only as strong as the specs you write.** The guarantee is "no effect outside
  the declared budget and preconditions." Loose preconditions = loose bounds.
  wuwei makes the boundary *provable and honest*; you still have to draw it.
- **A path precondition is a logical fence, not a symlink-proof jail.** A guard
  that checks a path *string* (e.g. "starts with `/box/`") is defeated by a
  symlink inside the box pointing out — the OS follows it and the effect lands
  outside. A **canonicalizing** guard (`safe-under?`, which resolves the real
  path and rejects symlinked leaves — see `guards.lisp`) closes every *planted*
  symlink, but a live adversary racing the check (TOCTOU) is a kernel problem,
  not a Lisp one. For a hostile *filesystem*, compose wuwei's gate with real
  OS confinement (a container, `bwrap`, namespaces). The gate decides what's
  permitted; the kernel contains what races anyway.
- **A host allowlist is a logical fence too, and it stops at the request.** The
  same defect appears one layer out: `https://api.good.com@evil.com/` *starts
  with* the allowed origin and goes to evil.com — everything before an `@` is a
  label, not a destination. `host-allowed?` (`guards.lisp`) matches on the
  **parsed host**, never the URL string. What it does **not** do: follow the
  request. An allowed host that answers `302 -> https://evil.com/` lands
  off-allowlist, and the gate cannot see it — the redirect happens inside the
  HTTP client, after the check said yes. Disable redirects in the tool (`curl`
  without `-L`) or re-gate every hop. DNS isn't fenced either: an allowed *name*
  that resolves to an attacker's address still passes, because the name is what
  is checked. Ports aren't fenced, and IDN/punycode homographs are out of scope.
  Same lesson as the symlink: the fence is logical; the network is the kernel's
  problem.
- **Certify at boot, and the gate runs the spec you certified.** `*tool-specs*`
  is global and keyed by tool name, and `deftool-spec` *replaces* the entry for
  that name — so a registry certified at boot can silently end up enforcing a
  spec it never certified. Two tenants sharing a tool name is enough: the second
  registration wins for **both**, so tenant A is refused its own box and reads
  tenant B's. `multi-tenant-test.lisp` proves it.
  **`certify-boot` closes it**: the certificate pins each tool's spec, and
  `gated-dispatch` enforces *that* one, so a later registration cannot reach a
  tenant that already booted. Detecting the change was never possible — a
  precondition is a code value, and code values are never `equal?` to anything
  (SPEC §equality), so the pinned spec can't even be compared with the live one.
  Holding it is the only honest answer. (Needs Rusty ≥ 0.48.0. Passing a bare
  registry still works and reads specs live — the pre-certificate behaviour.)
  Budgets compose the same way and are a **boot** check: a registry that exceeds
  its tenant's budget never certifies, so that tenant never starts.
- **Deliberately single-endpoint and cooperative** (it inherits Rusty's Rc-based
  runtime) — a safety layer for one agent process, not a distributed orchestrator.

## The one-line test

If a wrong action would cost you something you can't undo — a leaked secret, a
deleted file, a motor that moved — wuwei is for you. If the worst case is a
slightly-off answer, you probably don't need it.
