# Contributing to wuwei

wuwei is a provably-gated agent runner built on [Rusty](https://github.com/TheLakeMan/rusty).
This document covers the **legal terms** under which contributions are accepted
and the **technical standards** every change must meet. Both exist for the same
reason: wuwei's whole value is a narrow, checkable claim about what an agent is
permitted to execute, and neither its licensing nor that claim can rest on sand.

---

## Contributor License Agreement (CLA)

wuwei is offered under a **dual license**: the [GNU Affero General Public License
v3 or later](./LICENSE) for the community, and a separate commercial license for
those whose use the AGPL doesn't fit (see [COMMERCIAL.md](./COMMERCIAL.md)). That
dual model only works if a single party holds the right to relicense the **entire**
codebase — so contributions require the grant below.

**By submitting a contribution** (a pull request, patch, or any other change) to
this project, you agree that:

1. **You own the rights** to the contribution, or have permission to submit it
   under these terms, and it is your original work (or you've clearly identified
   any third-party material and its license).
2. **You grant Nicholas Vermeulen** a perpetual, worldwide, non-exclusive,
   royalty-free, irrevocable license to use, reproduce, modify, distribute, and
   **relicense** your contribution, including as part of wuwei under **both** the
   AGPL-3.0-or-later **and** any commercial license terms now or later offered.
3. **You retain copyright** to your contribution — this grant is a license, not an
   assignment. Your name stays on your work.
4. Your contribution is provided **"as is"**, without warranty of any kind.

Without this grant, a single merged change under AGPL-only terms would permanently
fragment the licensing of the file it touched.

---

## Technical standards

wuwei's value is that its gate is *proven*, not asserted. A change that weakens
that discipline weakens the whole project:

- **Narrow claims only.** wuwei's claim is exact: *the model can propose anything;
  it can execute only what the gate proves permitted, and no output widens that
  permission.* Never "unjailbreakable" or "safe" — the attack surface is the guard
  predicates, and saying so is the honesty that keeps the fence real. A claim's
  own caveat marks where it's already known false; state it, don't hide it.
- **Tests-first, real before/after.** A clean run is not evidence. Every new gate
  behaviour or guard needs a golden-test row (`./run_tests.sh`), and every fix
  must reproduce the hole first. A guard that fails *open* is a bug; a guard that
  fails *closed* is the design.
- **Built on Rusty, no new engine.** wuwei is pure Lisp over Rusty's verification
  primitives (`check-effects`, `safe-call-with-spec`, `certify-boot`). Don't add a
  dependency that isn't Rusty; don't reimplement a checker Rusty already provides.
- **Match the surrounding code** — its idiom, naming, and the refuse-by-default
  posture. New capability is opt-in and gated, never implied.

---

## How to submit

1. Open an issue first for anything non-trivial.
2. Keep pull requests focused: one concern per PR.
3. Run `./run_tests.sh` and make sure the suite passes before submitting.
4. By opening the PR, you agree to the CLA above.

Questions about contributing or licensing: **thelakeman@protonmail.com**.

☯ *Built on [Rusty](https://github.com/TheLakeMan/rusty). In memory of my brother.*
