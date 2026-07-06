# Macfolio

**Mac** + **Folio** — a leaf of a book

**Write books and articles with Claude Code as your co-author — on your Mac, in your language.**

Macfolio is a native macOS authoring studio built on top of the Claude Code CLI. It turns your
already-installed `claude` binary into a co-writer that drafts and revises your manuscript's chapters
as plain Markdown files in a folder you own — no new login, no web panel, right-to-left first.

![Macfolio](screenshot.png)

Right-to-left first — Persian and English mix freely, per paragraph:

![Right-to-left editing in Macfolio](screenshot-rtl.png)

## Why Macfolio

- **No new account, no new subscription.** It rides on the Claude Code you already have. Open the app
  and start writing — there is no sign-in screen.
- **Your book is just a folder.** Every chapter is a `.md` file under `~/Documents/Macfolio`. Plain
  text you can grep, back up, version with git, or open in any other editor. Nothing is locked in a
  database or a cloud.
- **Truly right-to-left.** Direction is decided per paragraph — Persian flows right-to-left, English
  and code left-to-right, mixed in the same document without a single language setting.
- **A real WYSIWYG editor, not a chat window.** You write in a polished editor; the co-author works
  alongside you in the same file.

## Features

### Write

- **Lexical WYSIWYG editor** — headings, **bold**/*italic*, bullet and numbered lists, quotes, fenced
  code blocks, tables, links, and images, all rendered inline as you type.
- **Markdown typing shortcuts** — `#`, `-`, `>`, `` ``` ``, and friends transform on the fly, so your
  hands never leave the keyboard.
- **Automatic RTL** via `dir="auto"` on every paragraph, with the bundled **Dana** font (Persian +
  English) for a consistent look across any Mac.

### Co-author

- **A co-writer that edits in place.** Ask for a new chapter, a rewrite, a tighter paragraph — the
  agent creates and edits the Markdown files directly, and the editor updates live.
- **Knows where your cursor is.** Your open chapter, your selection, and the current line are passed
  to the agent, so “expand this”, “rewrite the selection”, or “remove this line” just work.
- **Progress you can watch.** The chat footer streams the co-author's work as a live checklist, and
  shows the **token usage** for each turn right under the reply.
- **Per-book memory.** Each book keeps its own persistent Claude Code session, so the co-author has
  your whole manuscript in context — switch books and the conversation follows.
- **Start fresh anytime.** One click resets the session, clearing prior context for a clean slate.

### Organize

- **Books › chapters sidebar.** A clean tree of every book and its chapters. Right-click a chapter to
  copy its Markdown, rename, or delete it; add new chapters per book.
- **Media at a glance.** Images inside a book (e.g. an `images/` folder) are listed alongside its
  chapters.

### Fits right in

- **Native and lightweight.** A universal SwiftUI/AppKit app — no Electron.
- **Follows your Mac.** Honors the macOS system accent color and light/dark appearance.
- **Local only.** Nothing appears in the Claude web panel; your manuscript stays on disk.

## Models & control

Pick the model and how much freedom the co-author has, in **Settings**:

- **Model** — Claude **Opus 4.8**, **Sonnet 5**, or **Haiku 4.5**.
- **Permission mode** — **Bypass** (no prompts, the default), **Accept Edits**, or **Plan**.

## Build

    make run                                              # build the app and launch it
    make release                                          # universal release build
    make format                                           # swift-format the sources

`make run` builds the Lexical (Notion-style) WYSIWYG editor bundle into `build/editor/` (via Vite,
installing npm deps on first run) and embeds it in the app. If npm is unavailable, the manuscript
pane falls back to a read-only preview, so the app still runs — you just can't edit in place yet.

## Requirements

- macOS 13+
- [Claude Code CLI](https://docs.claude.com/en/docs/claude-code/setup) installed and authenticated
- Node.js 18+ (only to build the editor bundle)
