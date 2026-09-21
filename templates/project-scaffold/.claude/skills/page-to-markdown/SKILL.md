---
name: page-to-markdown
description: Fetch a web page and return clean, LLM-ready Markdown using only native tools — no external binary to install. Tries WebFetch first (built-in, zero setup); escalates to claude-in-chrome browser automation when the page needs real JS rendering or blocks simple fetches (anti-scraping/bot detection). Use whenever asked to convert a URL into Markdown, pull external reference content, or save a page for later reading. Not for library/framework documentation (use context7) or investigative black-box analysis (use the external-observer agent).
metadata:
  maintained_by: native-sdd (internal — authored in-repo, not vendored from a third party)
  version: "1.0.0"
---

# Page → Markdown (native-only)

Fetch a URL and return clean Markdown, escalating cost only when the cheap path fails — **without
installing anything external** (no Go binary, no browser download). The whole capability is
composed from tools already native to Claude Code.

**Explicit trigger:** [`/page-to-markdown`](../../commands/page-to-markdown.md). The command is only the trigger — this file stays the single source of the procedure. The `external-observer` agent gets this skill preloaded via its `skills:` frontmatter field.

## When to use

- "Busca essa página e me devolve em Markdown"
- Need the text of a URL to read/analyze/save
- `WebFetch` failed (blocked, empty, needs JS, paywall/captcha)

Don't use this skill for:
- Library/framework/SDK/CLI documentation → `context7` (see [`docs-first.md`](../../rules/docs-first.md))
- Formal black-box investigation (validate/map a target, network/headers/evidence) → the
  `external-observer` agent
- Comparing decision variants → `decision-preview`

## Workflow — two stages, escalate only on failure

1. **`WebFetch` first, always** (free, built-in, already does HTML→Markdown + a prompt over the
   content). Covers the large majority of pages.
   - Succeeded → done, return the content/Markdown asked for.
   - Failed / came back empty or clearly incomplete (client-side paywall, "enable JavaScript",
     captcha, `403`/`429`) → go to stage 2.

2. **Fallback: `claude-in-chrome`** (the user's real browser — nothing to install, no external
   binary):
   - `ToolSearch` once for the tools you'll need: `tabs_context_mcp`, `navigate`,
     `tabs_create_mcp`, `get_page_text` (or `read_page`).
   - `tabs_create_mcp` (new tab) → `navigate` to the URL → `get_page_text` (rendered text, already
     stripped of script/style) or `read_page` (structure, if you need DOM/links).
   - Format the extracted text as Markdown (headings → `#`, lists, etc. — minimal structure; don't
     invent hierarchy the page doesn't have).
   - **Close the tab** (`tabs_close_mcp`) when done, unless the user is going to keep browsing there.

3. **Save to file** (if asked): `Write` directly — no extra CLI needed.

## Why we don't need the third-party `md-fetch` binary

The real value of the third-party `md-fetch` CLI is "headless browser that bypasses
anti-scraping". `claude-in-chrome` already delivers that — and arguably better: it's the **user's
actual browser** (real session/cookies/fingerprint), not an anonymous headless Chrome that many
WAFs also block. `WebFetch` already covers HTML→Markdown for the common case. There's no gap here
that justifies installing a Go binary.

**What this doesn't cover:** a server/API mode for parallel batch-fetching N URLs at once (that's
what `md-fetch serve` is for). If that ever becomes a real need, the third-party supplement
`md-fetch-cli` (`/supplements docs`) stays in the repertoire for exactly that case — YAGNI until
then.

## What NOT to do

- Don't skip stage 1 (`WebFetch`) "just to be safe" — it's free; only escalate on an actual failure.
- Don't leave Chrome tabs open after you're done.
- Don't hand-roll HTML parsing — `get_page_text`/`read_page` already return clean text.
- Don't use this for library/framework docs (`context7`) or formal read-only investigation
  (`external-observer`).
