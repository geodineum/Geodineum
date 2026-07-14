# README Style

The standard every Geodineum repository's `README.md` follows. It exists so that
a person skimming for 60 seconds and an agent building against the code both find
the same things in the same places — and so that nothing in a README can quietly
become a lie.

Applies to every public component repo. `CONTRACT.md` / `CONTRACT.scn.md` /
docblocks have their own jobs (see *Division of labour* below); this document
governs only the README.

---

## Four principles

**1. Honest — falsifiable or durable, nothing else.**
Every line is either something a reader can verify at a glance, or a property
that will not change per-commit or per-machine. That is the whole test. It
excludes marketing superlatives, benchmark/performance numbers (they fluctuate
per system), and drift-prone precision (line counts, LOC totals, `file:line`
citations, exact tallies). State **guarantees** — stateless, deterministic,
one canonical contract — not adjectives.

**2. Lean — no duplication.**
A README is a map, not an encyclopedia. It points into the other docs; it never
re-hosts them. The moment a method signature or a wire field is copied into the
README, it has two homes and will diverge.

**3. Clean — one structure everywhere, one idea per section.**
Same section order in every repo, so anyone lands knowing where to look. Each
section carries a single idea with room to breathe. Do not compress three ideas
into a dense paragraph; give each its own space.

**4. Explicit public surface.**
For anything built *with*, the most valuable sentence is: *this is the supported,
stable API; everything else is internal and may change.* Draw that line. Let
per-symbol detail live in docblocks, surfaced as a generated index — never
hand-copied.

---

## Division of labour

The README is one layer of a system. Each artifact has exactly one job; overlap
is the defect.

| Artifact | Single job | Reader |
|---|---|---|
| `README.md` | Orient: what it is, what's callable, how to start, who's behind it | human, first |
| `CONTRACT.md` | The precise integration / wire contract | human integrator |
| `CONTRACT.scn.md` | Prime an agent quickly | LLM |
| docblocks | Per-symbol truth: signature, params, returns | whoever is in the code |

If per-method signatures belong anywhere, it is docblocks. The README's *Public
build surface* section links to them (or to a generated index), and stops there.

---

## Section order

Every README has these sections, in this order. Sections 1–7 are the
component-specific content; **8–11 are identical across every repo** (copy them
verbatim from *Mandatory blocks* below).

1. **Title + one line** — the name, then one plain sentence of what it is. No
   adjectives. Author and version on one line beneath.
2. **What it is** — 2–4 sentences: its role in the ecosystem and what kind of
   thing it is (Rust daemon / WordPress child theme / PHP client). Properties,
   not selling.
3. **Public build surface** — the supported, stable API: what you instantiate or
   call, and what is internal. Link to the per-symbol index / docblocks. Do not
   inline signatures.
4. **Capabilities** — short factual bullets of what it does.
5. **Contract** — one line and a link to `CONTRACT.md` (`CONTRACT.scn.md` for
   agents). Do not re-list fields or commands.
6. **Quick start** — the one minimal example that must always run.
7. **Limits worth knowing** *(optional)* — real constraints, one plain sentence
   each. No performance numbers.
8. **★ Collaborate** — how to contribute.
9. **★ Author & support** — author and donation addresses.
10. **★ Disclaimer** — "as is", own risk.
11. **★ License** — dual MIT / Apache.

Sections 8–11 are the repository's social contract, and they are the same social
contract the website presents. Keep them identical everywhere.

---

## Sub-documents (per-component guides)

Some repos have more public surface than one README should hold — a framework
may ship a guide per manager/module under `docs/README_<NAME>.md`, with the top
README carrying a **roster** that links to each. Sub-documents follow a lean
sub-template (what it is · **usage** — how to obtain it plus one short,
runnable end-to-end example · public API → the generated index · behaviour &
limits · link to the `CONTRACT.md` section) and obey two rules:

- **They link up, they do not duplicate.** Signatures live in the generated
  index; prose lives in `CONTRACT.md`; the sub-doc orients and links.
- **They carry the Disclaimer.** Any document can be opened on its own, so every
  sub-doc ends with the verbatim **Disclaimer** block (section 10) plus a
  one-line author/support credit linking to the repo README's *Author & support*.
  The full donation table stays in the repo README — one home; sub-docs link to
  it.

---

## Forbidden in a README

- Marketing language and superlatives ("fast", "powerful", "enterprise-grade").
- Performance or benchmark numbers — they are per-system and rot immediately.
- Drift-prone precision: LOC totals, line-count claims, `file:line` citations,
  exact tallies that change on the next commit. Name the file; not the line.
- Duplicated content already owned by `CONTRACT.md`, `COMMAND_SCHEMA.md`, or
  docblocks. Link instead.
- A second copy of the version. Version lives in exactly one place — the manifest
  (`Cargo.toml` / `composer.json` / `style.css`). Pull it or omit it.
- Roadmaps, changelogs, use-case galleries, Pro/premium catalogues.

---

## Two anti-drift rules

- **The public-API index is generated, not written.** Extract it from
  docblocks/signatures with a small tool so it is accurate on day one and
  regenerable. A hand-maintained method list is the next drift sweep.
- **Code wins.** If the README disagrees with the running system, the system is
  authoritative — fix the README.

---

## Mandatory blocks

Copy these verbatim into every repo. Only the bracketed component noun changes.

### ★ Collaborate

```markdown
## Collaborate

Contributions are welcome. Open issues and pick up work on the ecosystem board
at [geodineum.com](https://geodineum.com); issues tagged `good-first-issue` are
a good place to start.

- Fork, branch, and open a pull request against `main`.
- Any change to a wire contract must update **both** `CONTRACT.md` and
  `CONTRACT.scn.md` in the same commit.
- A change to a signed extension must be re-signed in the same commit.
```

### ★ Author & support

```markdown
## Author & support

Built by **Niels Erik Toren**.

If you want to support the work:

| Currency | Address |
|---|---|
| Bitcoin (BTC) | `bc1qwf78fjgapt2gcts4mwf3gnfkclvqgtlg4gpu4d` |
| Ethereum (ETH) | `0xf38b517Dd2005d93E0BDc1e9807665074c5eC731` / `nierto.eth` |
| Monero (XMR) | `8BPaSoq1pEJH4LgbGNQ92kFJA3oi2frE4igHvdP9Lz2giwhFo2VnNvGT8XABYasjtoVY2Qb3LVHv6CP3qwcJ8UnyRtjWRZ5` |
```

### ★ Disclaimer

```markdown
## Disclaimer

This software is provided **"as is"**, without warranty of any kind, express or
implied. Use of this software is entirely at your own risk. In no event shall the
author or contributors be held liable for any damages arising from the use or
inability to use this software.
```

### ★ License

```markdown
## License

Licensed under either of

* [Apache License, Version 2.0](LICENSE-APACHE)
* [MIT License](LICENSE-MIT)

at your option.
```

---

## Author's checklist

Before a README ships, every line passes one of two tests — a reader can verify
it at a glance, or it will not change per-commit or per-machine. If a line passes
neither, cut it or move it to the artifact that owns it.

- [ ] Sections present and in order (1–11).
- [ ] Public build surface names the supported API and the internal boundary.
- [ ] No performance numbers, no LOC/line counts, no `file:line` citations.
- [ ] No content duplicated from `CONTRACT.md` / `COMMAND_SCHEMA.md` / docblocks.
- [ ] Version appears once (the manifest), or not at all.
- [ ] Blocks 8–11 identical to this standard.
- [ ] Every sub-document (per-component guide) carries the Disclaimer + an author/support link.
