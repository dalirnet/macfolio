# Macfolio

**Mac** + **Folio** — a leaf of a book

Write books and articles with Claude Code as your co-author — on your Mac, in your language.

Macfolio is a native macOS authoring studio built on top of the Claude Code CLI. It drives Claude
Code to draft and revise your manuscript's chapters as plain Markdown files in a folder you own — no
new login, no web panel, right-to-left first.

## How it works

- **No new auth.** Macfolio shells out to your already-installed, already-logged-in `claude` binary,
  inheriting your Claude Code credentials. There is no sign-in screen.
- **Your book is a folder.** A book is just a folder of `.md` files under `~/Documents/Macfolio` —
  one file per chapter, flat, no hidden structure. The agent creates and edits those files; you own
  them.
- **One tree, one editor, a chat footer.** The sidebar is a books › chapters tree (right-click a
  chapter to copy its Markdown, rename, or delete it; new chapters are added per book and sort
  alphabetically). The center is a Lexical WYSIWYG editor — headings, lists, quotes, code blocks,
  tables, links, and images, with Markdown typing shortcuts. The chat with the co-author docks at the
  bottom and streams its progress as a live checklist.
- **Per-book session.** Each book keeps one persistent Claude Code session, so the co-author has your
  whole manuscript in context.
- **Pick your model.** Choose Opus, Sonnet, or Haiku and the agent's permission mode in Settings.
- **Automatic RTL.** Direction is per paragraph (`dir="auto"`) — Persian goes right-to-left, English
  and code left-to-right, mixed freely. No language setting. The bundled **IRANSansX** font (en + fa)
  is used throughout.
- **Local only.** Nothing appears in the Claude web panel; your manuscript stays on disk.

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
