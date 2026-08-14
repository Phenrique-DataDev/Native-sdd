---
name: decision-preview
description: Generate a single self-contained Artifact that compares 2-4 variants of an as-yet-undecided design choice side by side, grounded in real project data, and closes with an explicit choice question. Use when a decision has multiple viable options and getting it wrong after implementing would be costly to redo — a UI copy choice, a terminal/CLI output design, a schema layout, a component variant, an architecture option. Not for explaining or reviewing something already decided (use visual-explainer for that) or for a single mockup with no comparison (use artifact-design directly).
metadata:
  maintained_by: native-sdd (internal — not a third-party marketplace skill)
  version: "1.0.0"
---

# Decision Preview

Generate **one** Artifact that lets someone **choose before building**, instead of implementing
the first option that comes to mind. The output is always the same shape regardless of domain:
**N variants side by side, each grounded in real project data, each annotated, closing with an
explicit choice.**

## When to use

Use this skill when:
- The decision has **2–4 viable options**, none obviously correct.
- Getting it wrong is **expensive to redo** after implementation (not a one-line revert).
- The difference between options is **easier to show than to describe**.

Don't use this skill for:
- Explaining or reviewing something **already decided** (a diff, a finished plan, an existing
  architecture) — that's `visual-explainer`, if installed.
- A **single** mockup with nothing to compare — that's `artifact-design` directly.
- More than ~4 options — narrow it down first; a wall of variants defeats the point.

See [`../../rules/artifact-first.md`](../../rules/artifact-first.md) for the posture that decides
*when* to reach for this skill in the first place.

## Workflow

1. **Load `artifact-design`** first — it carries the design calibration (aesthetic direction,
   anti-slop rules, accessibility) this skill builds on. Don't re-derive that guidance here.
2. **Name the variants** — 2 to 4, each a genuinely distinct answer to the same question (not
   minor tweaks of one idea, unless the tweak *is* the decision).
3. **Ground every variant in real data.** Read the actual theme tokens / copy / schema / code the
   project already has. **Never** fabricate placeholder content (no lorem ipsum, no invented
   colors, no hypothetical data) — if the real input is missing, ask for it before generating.
   Anything unavoidably hypothetical must be labeled `[hipotético]` inline.
4. **Read `./templates/base.html`** before writing — don't reimplement its layout from memory each
   time. Adapt the variant-card structure and the closing choice section to the content at hand;
   the example content in it is illustrative only, replace it.
5. **Annotate each variant** — a short line on what it optimizes for / trades off, not just the
   raw rendering. The annotation is what turns "here are 3 things" into "here's how to decide".
6. **Close with an explicit choice**, not a vague "let me know what you think":
   - Interactive session → publish the Artifact, then ask via `AskUserQuestion` referencing it.
   - Non-interactive (background agent/workflow) → the HTML's own "Escolha" section must stand on
     its own for async review — don't rely solely on the chat-turn question.
7. **Publish via the `Artifact` tool.** One artifact, all variants — not one artifact per variant.
   Follow the tool's own constraints: no `<!DOCTYPE>`/`<html>`/`<head>`/`<body>` tags (the wrapper
   adds those), self-contained CSS/JS, theme-aware for both light and dark.

## Anti-patterns (explicitly forbidden)

- Filling a variant with generic/placeholder content because the real grounding wasn't at hand.
- More than ~4 variants in one page — split the decision instead.
- Rendering variants without an annotation (just N boxes, no "why").
- Ending without a concrete choice mechanism (no question, no "Escolha" section).
- Rebuilding what `visual-explainer` already does (diff review, plan review, slide decks,
  architecture explainers) — if the task is "explain/review something decided", route there
  instead.
- Reusing this skill for a single mockup — if there's nothing to compare, `artifact-design` alone
  is enough.

## Template

`./templates/base.html` is a self-contained, theme-aware (light/dark) skeleton with:
- A header slot for the decision being made (1 sentence — what's being decided and why).
- A responsive variant grid (2–4 cards), each with a content slot + an annotation slot.
- A closing "Escolha" section with the explicit question and the options to pick from.

It has no external dependencies (inline CSS only, CSP-safe) — read it, then adapt the slots to the
actual content; don't ship it unmodified, and don't carry its example content into the real output.
