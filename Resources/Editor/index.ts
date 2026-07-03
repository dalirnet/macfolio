import { $createCodeNode, CodeHighlightNode, CodeNode } from "@lexical/code";
import { registerCodeHighlighting } from "@lexical/code-prism";
import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import {
    $isLinkNode,
    $toggleLink,
    AutoLinkNode,
    LinkNode,
    TOGGLE_LINK_COMMAND,
} from "@lexical/link";
import {
    INSERT_ORDERED_LIST_COMMAND,
    INSERT_UNORDERED_LIST_COMMAND,
    ListItemNode,
    ListNode,
    registerList,
} from "@lexical/list";
import {
    $convertFromMarkdownString,
    $convertToMarkdownString,
    registerMarkdownShortcuts,
    TRANSFORMERS,
} from "@lexical/markdown";
import {
    $createHeadingNode,
    $createQuoteNode,
    HeadingNode,
    QuoteNode,
    registerRichText,
} from "@lexical/rich-text";
import { $setBlocksType } from "@lexical/selection";
import {
    $createTableCellNode,
    $createTableNode,
    $createTableRowNode,
    $isTableCellNode,
    $isTableNode,
    $isTableRowNode,
    INSERT_TABLE_COMMAND,
    TableCellHeaderStates,
    TableCellNode,
    TableNode,
    TableRowNode,
    registerTablePlugin,
    registerTableSelectionObserver,
} from "@lexical/table";
import { $findMatchingParent, mergeRegister } from "@lexical/utils";
import {
    $applyNodeReplacement,
    $createParagraphNode,
    $getNearestNodeFromDOMNode,
    $getRoot,
    $getSelection,
    $isRangeSelection,
    $setSelection,
    COMMAND_PRIORITY_EDITOR,
    COMMAND_PRIORITY_LOW,
    DecoratorNode,
    FORMAT_TEXT_COMMAND,
    SELECTION_CHANGE_COMMAND,
    createEditor,
} from "lexical";

import type {
    ElementTransformer,
    TextMatchTransformer,
    Transformer,
} from "@lexical/markdown";
import type { HeadingTagType } from "@lexical/rich-text";
import type {
    BaseSelection,
    EditorThemeClasses,
    ElementNode,
    LexicalEditor,
    LexicalNode,
    SerializedLexicalNode,
    TextFormatType,
} from "lexical";

// Pre-normalized icon SVGs from Resources/Icons, inlined as raw text at build time.
import boldIcon from "../Icons/bold.svg?raw";
import bulletListIcon from "../Icons/bulletList.svg?raw";
import codeIcon from "../Icons/code.svg?raw";
import codeBlockIcon from "../Icons/codeBlock.svg?raw";
import h1Icon from "../Icons/h1.svg?raw";
import h2Icon from "../Icons/h2.svg?raw";
import h3Icon from "../Icons/h3.svg?raw";
import imageIcon from "../Icons/image.svg?raw";
import italicIcon from "../Icons/italic.svg?raw";
import linkIcon from "../Icons/link.svg?raw";
import orderedListIcon from "../Icons/orderedList.svg?raw";
import quoteIcon from "../Icons/quote.svg?raw";
import tableIcon from "../Icons/table.svg?raw";
import textIcon from "../Icons/text.svg?raw";

import "./index.css";

// --- Host bridge: types, outbound messages, logging ---

// Host API (optional — undefined when opened outside Macfolio).
declare global {
    interface Window {
        macfolioLoad: (markdown: string) => void;
        macfolioSetEditable: (on: boolean) => void;
        // Called back by the Swift host after a native dialog resolves.
        macfolioInsertTable: (rows: number, cols: number) => void;
        macfolioSetLink: (url: string) => void;
        macfolioInsertImage: (src: string, alt: string) => void;
        webkit?: {
            messageHandlers: Record<
                string,
                {
                    postMessage: (body: unknown) => void;
                }
            >;
        };
    }
}

// Post a message to the Swift host (no-op when not hosted in Macfolio).
function post(name: string, body?: unknown): void {
    try {
        window.webkit!.messageHandlers[name].postMessage(body ?? "");
    } catch {}
}

// Forward a log line to the Swift host (see NSLog "[editor.js]" in Console.app).
function log(level: string, ...parts: unknown[]): void {
    const text = parts
        .map((p) => {
            if (p instanceof Error) {
                return `${p.message}\n${p.stack ?? ""}`;
            }

            if (typeof p === "string") {
                return p;
            }

            try {
                return JSON.stringify(p);
            } catch {
                return String(p);
            }
        })
        .join(" ");

    post("log", `[${level}] ${text}`);
}

// Surface anything that would otherwise die silently inside the WebView.
window.addEventListener("error", (e) => {
    log("error", e.message, `${e.filename}:${e.lineno}:${e.colno}`, e.error);
});

window.addEventListener("unhandledrejection", (e) => {
    log("unhandledrejection", e.reason);
});

const consoleError = console.error.bind(console);
console.error = (...args: unknown[]) => {
    log("console.error", ...args);
    consoleError(...args);
};

const consoleWarn = console.warn.bind(console);
console.warn = (...args: unknown[]) => {
    log("console.warn", ...args);
    consoleWarn(...args);
};

// --- Theme ---

// Maps Lexical node types to Macfolio CSS classes (styled in index.css).
// Direction is handled natively by Lexical (dir="auto" on top-level blocks),
// so there are no ltr/rtl theme classes here — the browser resolves bidi.
const theme: EditorThemeClasses = {
    paragraph: "mf-p",
    quote: "mf-quote",
    heading: {
        h1: "mf-h1",
        h2: "mf-h2",
        h3: "mf-h3",
    },
    list: {
        ul: "mf-ul",
        ol: "mf-ol",
        listitem: "mf-li",
        nested: {
            listitem: "mf-nested-li",
        },
    },
    link: "mf-link",
    text: {
        bold: "mf-bold",
        italic: "mf-italic",
        strikethrough: "mf-strike",
        code: "mf-inline-code",
    },
    code: "mf-code-block",
    table: "mf-table",
    tableRow: "mf-tr",
    tableCell: "mf-td",
    tableCellHeader: "mf-th",
    // Prism token classes for code-block syntax highlighting.
    codeHighlight: {
        atrule: "mf-tok-attr",
        attr: "mf-tok-attr",
        boolean: "mf-tok-const",
        builtin: "mf-tok-builtin",
        cdata: "mf-tok-comment",
        char: "mf-tok-string",
        class: "mf-tok-class",
        "class-name": "mf-tok-class",
        comment: "mf-tok-comment",
        constant: "mf-tok-const",
        deleted: "mf-tok-deleted",
        doctype: "mf-tok-comment",
        entity: "mf-tok-op",
        function: "mf-tok-fn",
        important: "mf-tok-keyword",
        inserted: "mf-tok-inserted",
        keyword: "mf-tok-keyword",
        namespace: "mf-tok-builtin",
        number: "mf-tok-const",
        operator: "mf-tok-op",
        prolog: "mf-tok-comment",
        property: "mf-tok-attr",
        punctuation: "mf-tok-punct",
        regex: "mf-tok-string",
        selector: "mf-tok-string",
        string: "mf-tok-string",
        symbol: "mf-tok-const",
        tag: "mf-tok-keyword",
        url: "mf-tok-op",
        variable: "mf-tok-var",
    },
};

// --- Custom nodes (vanilla DecoratorNodes) ---

// Divider — renders <hr>.
class HorizontalRuleNode extends DecoratorNode<null> {
    static getType(): string {
        return "horizontalrule";
    }

    static clone(node: HorizontalRuleNode): HorizontalRuleNode {
        return new HorizontalRuleNode(node.__key);
    }

    static importJSON(): HorizontalRuleNode {
        return $createHorizontalRuleNode();
    }

    exportJSON(): SerializedLexicalNode {
        return { type: "horizontalrule", version: 1 };
    }

    createDOM(): HTMLElement {
        const hr = document.createElement("hr");
        hr.className = "mf-hr";
        return hr;
    }

    getTextContent(): string {
        return "\n";
    }

    isInline(): boolean {
        return false;
    }

    updateDOM(): boolean {
        return false;
    }

    decorate(): null {
        return null;
    }
}

function $createHorizontalRuleNode(): HorizontalRuleNode {
    return $applyNodeReplacement(new HorizontalRuleNode());
}

function $isHorizontalRuleNode(
    node: LexicalNode | null | undefined,
): node is HorizontalRuleNode {
    return node instanceof HorizontalRuleNode;
}

// Markdown keeps plain (usually relative) paths; project files can't load over
// file:// from the app bundle, so relative paths render through the host's
// `mfmedia://` scheme handler while absolute/remote/data URLs pass through.
function mediaUrl(src: string): string {
    if (/^(https?:|data:|mfmedia:)/i.test(src)) {
        return src;
    }
    return `mfmedia:///${encodeURI(src)}`;
}

interface SerializedImageNode extends SerializedLexicalNode {
    src: string;
    alt: string;
}

// Image — renders <img>, source resolved through mediaUrl.
class ImageNode extends DecoratorNode<null> {
    __src: string;
    __alt: string;

    static getType(): string {
        return "image";
    }

    static clone(node: ImageNode): ImageNode {
        return new ImageNode(node.__src, node.__alt, node.__key);
    }

    static importJSON(json: SerializedLexicalNode): ImageNode {
        const { src, alt } = json as SerializedImageNode;
        return $createImageNode(src, alt);
    }

    constructor(src: string, alt: string, key?: string) {
        super(key);
        this.__src = src;
        this.__alt = alt;
    }

    exportJSON(): SerializedImageNode {
        return { type: "image", version: 1, src: this.__src, alt: this.__alt };
    }

    getSrc(): string {
        return this.__src;
    }

    getAlt(): string {
        return this.__alt;
    }

    createDOM(): HTMLElement {
        const span = document.createElement("span");
        span.className = "mf-image";
        const img = document.createElement("img");
        img.src = mediaUrl(this.__src);
        img.alt = this.__alt;
        span.appendChild(img);
        return span;
    }

    updateDOM(): boolean {
        return false;
    }

    getTextContent(): string {
        return this.__alt;
    }

    isInline(): boolean {
        return true;
    }

    decorate(): null {
        return null;
    }
}

function $createImageNode(src: string, alt: string): ImageNode {
    return $applyNodeReplacement(new ImageNode(src, alt));
}

function $isImageNode(
    node: LexicalNode | null | undefined,
): node is ImageNode {
    return node instanceof ImageNode;
}

// --- Markdown transformers (divider + GFM table) and the full transformer set ---

// Divider: `---` / `***` / `___` on its own line.
const HR_TRANSFORMER: ElementTransformer = {
    dependencies: [HorizontalRuleNode],
    export(node) {
        if ($isHorizontalRuleNode(node)) {
            return "---";
        }
        return null;
    },
    regExp: /^(---|\*\*\*|___)\s?$/,
    replace(parentNode, _children, _match, isImport) {
        const line = $createHorizontalRuleNode();
        if (isImport || parentNode.getNextSibling() != null) {
            parentNode.replace(line);
        } else {
            parentNode.insertBefore(line);
        }
        line.selectNext();
    },
    // Convert on Enter too, not only a trailing space — so `---`⏎ becomes a
    // divider live instead of surviving as text until the file is reopened.
    triggerOnEnter: true,
    type: "element",
};

const TABLE_ROW_REG_EXP = /^\|(.+)\|\s*$/;
const TABLE_ROW_DIVIDER_REG_EXP = /^(\|\s*:?-{1,}:?\s*)+\|\s*$/;

// Split a `| a | b |` line into trimmed cell strings.
function splitTableRow(line: string): string[] {
    return line
        .trim()
        .replace(/^\|/, "")
        .replace(/\|$/, "")
        .split("|")
        .map((cell) => {
            return cell.trim();
        });
}

// Build a table cell, parsing its (inline) Markdown content into a paragraph.
function $createTableCell(text: string, isHeader: boolean): TableCellNode {
    let headerState = TableCellHeaderStates.NO_STATUS;
    if (isHeader) {
        headerState = TableCellHeaderStates.ROW;
    }

    const cell = $createTableCellNode(headerState);
    $convertFromMarkdownString(
        text.replace(/\\n/g, "\n"),
        MARKDOWN_TRANSFORMERS,
        cell,
    );
    return cell;
}

// GFM tables. Import consumes the whole `|...|` block at once (via
// handleImportAfterStartMatch); export always emits a header divider after the
// first row so the result re-parses as a valid GFM table.
const TABLE_TRANSFORMER: Transformer = {
    dependencies: [TableNode, TableRowNode, TableCellNode],
    export(node, exportChildren) {
        if (!$isTableNode(node)) {
            return null;
        }

        const out: string[] = [];
        let first = true;
        for (const row of node.getChildren()) {
            if (!$isTableRowNode(row)) {
                continue;
            }

            const cells: string[] = [];
            for (const cell of row.getChildren()) {
                if ($isTableCellNode(cell)) {
                    cells.push(
                        exportChildren(cell).replace(/\n/g, "\\n").trim(),
                    );
                }
            }

            out.push(`| ${cells.join(" | ")} |`);
            if (first) {
                const divider = cells.map(() => {
                    return "---";
                });
                out.push(`| ${divider.join(" | ")} |`);
                first = false;
            }
        }
        return out.join("\n");
    },
    regExpStart: TABLE_ROW_REG_EXP,
    regExpEnd: { optional: true, regExp: /^\s*$/ },
    handleImportAfterStartMatch({ lines, rootNode, startLineIndex }) {
        let i = startLineIndex;
        const rowLines: string[] = [];
        for (; i < lines.length; i++) {
            if (!TABLE_ROW_REG_EXP.test(lines[i])) {
                break;
            }
            rowLines.push(lines[i]);
        }
        if (rowLines.length === 0) {
            return null;
        }

        const parsed: string[][] = [];
        let headerIndex = -1;
        let maxCells = 0;
        for (const line of rowLines) {
            if (TABLE_ROW_DIVIDER_REG_EXP.test(line)) {
                headerIndex = parsed.length - 1; // the row just above the divider
                continue;
            }
            const cells = splitTableRow(line);
            maxCells = Math.max(maxCells, cells.length);
            parsed.push(cells);
        }

        const table = $createTableNode();
        parsed.forEach((cells, rowIndex) => {
            const row = $createTableRowNode();
            table.append(row);
            for (let c = 0; c < maxCells; c++) {
                row.append(
                    $createTableCell(cells[c] ?? "", rowIndex === headerIndex),
                );
            }
        });
        rootNode.append(table);

        return [true, i - 1];
    },
    replace() {
        return false;
    },
    type: "multiline-element",
};

// Image: `![alt](src)`. Tried before the default LINK so the `!` prefix wins.
const IMAGE_TRANSFORMER: TextMatchTransformer = {
    dependencies: [ImageNode],
    export(node) {
        if (!$isImageNode(node)) {
            return null;
        }
        return `![${node.getAlt()}](${node.getSrc()})`;
    },
    importRegExp: /!\[([^\]]*)\]\(([^)]+)\)/,
    regExp: /!\[([^\]]*)\]\(([^)]+)\)$/,
    replace(textNode, match) {
        const [, alt, src] = match;
        textNode.replace($createImageNode(src, alt));
    },
    trigger: ")",
    type: "text-match",
};

// Single source of truth for Markdown <-> editor conversion, used by both the
// load/save round-trip and the live typing shortcuts (`# `, `- `, ``` ``` ```, …).
// Custom transformers come first so they win over the defaults (e.g. `|...|`).
const MARKDOWN_TRANSFORMERS: Array<Transformer> = [
    TABLE_TRANSFORMER,
    HR_TRANSFORMER,
    IMAGE_TRANSFORMER,
    ...TRANSFORMERS,
];

// --- Block types offered by the sticky top toolbar ---

// One block the toolbar can turn the current block into (or insert).
interface BlockItem {
    icon: string;
    label: string;
    run: (editor: LexicalEditor) => void;
}

// Convert the current block(s) into `factory`'s node type.
function setBlock(editor: LexicalEditor, factory: () => ElementNode): void {
    editor.update(() => {
        const selection = $getSelection();
        if ($isRangeSelection(selection)) {
            $setBlocksType(selection, factory);
        }
    });
}

// Turn the current block into a heading of the given level.
function heading(tag: HeadingTagType): (editor: LexicalEditor) => void {
    return (editor) => {
        setBlock(editor, () => {
            return $createHeadingNode(tag);
        });
    };
}

// Grouped for the toolbar; a thin separator is drawn between groups.
const BLOCK_GROUPS: BlockItem[][] = [
    [
        {
            icon: textIcon,
            label: "Paragraph",
            run(editor) {
                setBlock(editor, () => {
                    return $createParagraphNode();
                });
            },
        },
        { icon: h1Icon, label: "Heading 1", run: heading("h1") },
        { icon: h2Icon, label: "Heading 2", run: heading("h2") },
        { icon: h3Icon, label: "Heading 3", run: heading("h3") },
    ],
    [
        {
            icon: bulletListIcon,
            label: "Bullet List",
            run(editor) {
                editor.dispatchCommand(
                    INSERT_UNORDERED_LIST_COMMAND,
                    undefined,
                );
            },
        },
        {
            icon: orderedListIcon,
            label: "Numbered List",
            run(editor) {
                editor.dispatchCommand(INSERT_ORDERED_LIST_COMMAND, undefined);
            },
        },
    ],
    [
        {
            icon: quoteIcon,
            label: "Quote",
            run(editor) {
                setBlock(editor, () => {
                    return $createQuoteNode();
                });
            },
        },
        {
            icon: codeBlockIcon,
            label: "Code Block",
            run(editor) {
                setBlock(editor, () => {
                    return $createCodeNode();
                });
            },
        },
        {
            icon: tableIcon,
            label: "Table",
            // Ask the host for a native rows/cols dialog (see macfolioInsertTable).
            run() {
                post("table");
            },
        },
        {
            icon: imageIcon,
            label: "Image",
            // Ask the host for the project image picker (see macfolioInsertImage).
            run() {
                post("image");
            },
        },
    ],
];

// Sticky top toolbar that inserts / converts blocks. Buttons act on the current
// selection (falling back to the document end when nothing is focused yet).
function registerBlockToolbar(
    editor: LexicalEditor,
    container: HTMLElement,
): () => void {
    // Never let a toolbar press move the caret / clear the selection.
    container.addEventListener("mousedown", (e) => {
        e.preventDefault();
    });

    BLOCK_GROUPS.forEach((group, index) => {
        if (index > 0) {
            const sep = document.createElement("span");
            sep.className = "mf-block-sep";
            container.appendChild(sep);
        }

        for (const item of group) {
            const btn = document.createElement("button");
            btn.type = "button";
            btn.className = "mf-block-btn";
            btn.title = item.label;
            btn.innerHTML = item.icon;
            btn.addEventListener("click", (e) => {
                e.preventDefault();
                if (!editor.isEditable()) {
                    return;
                }
                editor.update(() => {
                    if ($getSelection() == null) {
                        $getRoot().selectEnd();
                    }
                });
                item.run(editor);
                editor.focus();
            });
            container.appendChild(btn);
        }
    });

    const cleanup = editor.registerEditableListener((editable) => {
        container.classList.toggle("mf-block-toolbar--disabled", !editable);
    });

    return () => {
        cleanup();
        container.innerHTML = "";
    };
}

// --- Selection toolbar (bold / italic / inline-code / link) ---

// A format button plus the predicate that decides whether it reads as "active".
interface FormatButton {
    el: HTMLButtonElement;
    isActive: () => boolean;
}

// Build one <button> with an inlined SVG icon and a click handler.
function toolbarButton(
    icon: string,
    title: string,
    onClick: () => void,
): HTMLButtonElement {
    const el = document.createElement("button");
    el.type = "button";
    el.className = "mf-toolbar-item";
    el.title = title;
    el.innerHTML = icon;
    el.addEventListener("click", (e) => {
        e.preventDefault();
        onClick();
    });
    return el;
}

// Floating selection toolbar. Shows above a non-empty range selection (a
// WYSIWYG selection popover). Returns a teardown that unregisters and cleans up.
function registerToolbar(editor: LexicalEditor): () => void {
    const root = document.createElement("div");
    root.className = "mf-toolbar";
    // Never let a toolbar press move the caret / clear the selection.
    root.addEventListener("mousedown", (e) => {
        e.preventDefault();
    });

    // The range to linkify, captured before the native link dialog takes focus.
    let savedSelection: BaseSelection | null = null;

    function format(type: TextFormatType): void {
        editor.dispatchCommand(FORMAT_TEXT_COMMAND, type);
    }

    const buttons: FormatButton[] = [
        {
            el: toolbarButton(boldIcon, "Bold", () => {
                format("bold");
            }),
            isActive() {
                return hasFormat("bold");
            },
        },
        {
            el: toolbarButton(italicIcon, "Italic", () => {
                format("italic");
            }),
            isActive() {
                return hasFormat("italic");
            },
        },
        {
            el: toolbarButton(codeIcon, "Code", () => {
                format("code");
            }),
            isActive() {
                return hasFormat("code");
            },
        },
    ];

    for (const b of buttons) {
        root.appendChild(b.el);
    }

    const divider = document.createElement("span");
    divider.className = "mf-toolbar-divider";
    root.appendChild(divider);

    const linkButton = toolbarButton(linkIcon, "Link", () => {
        toggleLink();
    });
    root.appendChild(linkButton);

    document.body.appendChild(root);

    // --- selection helpers (called only inside an editor read) ---

    function hasFormat(type: TextFormatType): boolean {
        const selection = $getSelection();
        return $isRangeSelection(selection) && selection.hasFormat(type);
    }

    // The LinkNode wrapping the current selection, if any (read context only).
    function currentLink(): LinkNode | null {
        const selection = $getSelection();
        if (!$isRangeSelection(selection)) {
            return null;
        }
        const node = selection.getNodes()[0];
        if (!node) {
            return null;
        }
        if ($isLinkNode(node)) {
            return node;
        }
        const parent = $findMatchingParent(node, $isLinkNode);
        return $isLinkNode(parent) ? parent : null;
    }

    // Capture the selection, then ask the host for a URL (WKWebView blocks
    // window.prompt). macfolioSetLink restores it and applies / clears the link.
    function toggleLink(): void {
        let current = "";
        editor.getEditorState().read(() => {
            const selection = $getSelection();
            if ($isRangeSelection(selection)) {
                savedSelection = selection.clone();
            }
            current = currentLink()?.getURL() ?? "";
        });
        post("link", current);
    }

    window.macfolioSetLink = (url) => {
        editor.update(() => {
            if (savedSelection) {
                $setSelection(savedSelection.clone());
            }
        });

        const trimmed = (url ?? "").trim();
        if (trimmed) {
            editor.dispatchCommand(TOGGLE_LINK_COMMAND, trimmed);
        } else {
            editor.dispatchCommand(TOGGLE_LINK_COMMAND, null);
        }
    };

    // --- visibility + positioning ---

    function hide(): void {
        root.classList.remove("mf-toolbar--visible");
    }

    function position(): void {
        const domSelection = window.getSelection();
        if (!domSelection || domSelection.rangeCount === 0) {
            hide();
            return;
        }

        const rect = domSelection.getRangeAt(0).getBoundingClientRect();
        if (rect.width === 0 && rect.height === 0) {
            hide();
            return;
        }

        root.classList.add("mf-toolbar--visible");

        const margin = 8;
        const width = root.offsetWidth;
        const height = root.offsetHeight;

        let top = rect.top - height - margin;
        if (top < margin) {
            top = rect.bottom + margin; // flip below when clipped at the top
        }

        let left = rect.left + rect.width / 2 - width / 2;
        left = Math.max(
            margin,
            Math.min(left, window.innerWidth - width - margin),
        );

        root.style.top = `${Math.round(top)}px`;
        root.style.left = `${Math.round(left)}px`;
    }

    function update(): void {
        const selection = $getSelection();
        if (
            !$isRangeSelection(selection) ||
            selection.isCollapsed() ||
            selection.getTextContent() === "" ||
            !editor.isEditable()
        ) {
            hide();
            return;
        }

        for (const b of buttons) {
            b.el.classList.toggle("mf-active", b.isActive());
        }
        linkButton.classList.toggle("mf-active", currentLink() !== null);

        position();
    }

    function scrollHide(): void {
        hide();
    }

    // The editor lives in a scroll container (#app); reposition on scroll.
    window.addEventListener("scroll", scrollHide, true);

    const cleanup = mergeRegister(
        editor.registerCommand(
            SELECTION_CHANGE_COMMAND,
            () => {
                update();
                return false;
            },
            COMMAND_PRIORITY_LOW,
        ),
        // Catch format toggles (which don't move the selection) and doc edits.
        editor.registerUpdateListener(({ editorState }) => {
            editorState.read(() => {
                update();
            });
        }),
    );

    return () => {
        cleanup();
        window.removeEventListener("scroll", scrollHide, true);
        root.remove();
    };
}

// --- Table direction (RTL) ---

const RTL_CHARS = /[֐-ࣿיִ-﷿ﹰ-﻿]/;
const LTR_CHARS = /[A-Za-zÀ-ʸ]/;

// Direction of the first strong character (mirrors dir="auto"), but applied
// explicitly so a table's column order actually flips when its content is RTL.
function firstStrongDirection(text: string): "ltr" | "rtl" {
    for (const ch of text) {
        if (LTR_CHARS.test(ch)) {
            return "ltr";
        }
        if (RTL_CHARS.test(ch)) {
            return "rtl";
        }
    }
    return "ltr";
}

// Keep each table's dir in sync with its content so RTL text reorders columns.
function registerTableDirection(editor: LexicalEditor): () => void {
    return editor.registerNodeTransform(TableNode, (table) => {
        const dir = firstStrongDirection(table.getTextContent());
        if (table.getDirection() !== dir) {
            table.setDirection(dir);
        }
    });
}

// --- Remove button (per block) ---

const REMOVE_ICON =
    '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
    'stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"/></svg>';

// A "×" in the side gutter of the hovered block; clicking it deletes that block.
// Returns a teardown.
function registerBlockRemove(
    editor: LexicalEditor,
    scrollEl: HTMLElement,
): () => void {
    const editorEl = editor.getRootElement();
    if (!editorEl) {
        return () => {};
    }

    const button = document.createElement("button");
    button.type = "button";
    button.className = "mf-remove-btn";
    button.title = "Remove";
    button.innerHTML = REMOVE_ICON;
    button.addEventListener("mousedown", (e) => {
        e.preventDefault();
    });
    document.body.appendChild(button);

    const SHOW_DELAY = 280;

    let target: HTMLElement | null = null;
    let showTimer: ReturnType<typeof setTimeout> | undefined;
    let hideTimer: ReturnType<typeof setTimeout> | undefined;

    function cancelShow(): void {
        clearTimeout(showTimer);
    }

    function cancelHide(): void {
        clearTimeout(hideTimer);
    }

    function hide(): void {
        cancelShow();
        cancelHide();
        button.classList.remove("mf-remove-btn--visible");
        target = null;
    }

    // Debounced so a small gap between the block and the button doesn't flicker.
    function scheduleHide(): void {
        cancelShow();
        cancelHide();
        hideTimer = setTimeout(() => {
            hide();
        }, 220);
    }

    // Show after a short settle so the button doesn't blink in as the cursor
    // sweeps across blocks. Once visible, following a new block is immediate.
    function scheduleShow(el: HTMLElement): void {
        cancelHide();
        if (el === target) {
            return;
        }
        if (target) {
            showFor(el);
            return;
        }
        cancelShow();
        showTimer = setTimeout(() => {
            showFor(el);
        }, SHOW_DELAY);
    }

    // The top-level block (direct child of the editor root) enclosing `node`.
    function blockFrom(node: EventTarget | null): HTMLElement | null {
        let el = node as HTMLElement | null;
        while (el && el !== editorEl) {
            if (el.parentElement === editorEl) {
                return el;
            }
            el = el.parentElement;
        }
        return null;
    }

    function showFor(el: HTMLElement): void {
        cancelShow();
        cancelHide();
        if (el === target) {
            return; // already pointing at this block — don't re-position/flicker
        }
        target = el;

        // Sit in the side gutter (never over the block): start side for LTR,
        // end side for RTL. Vertically centered on the block.
        const size = 22;
        const gap = 8;
        const rect = el.getBoundingClientRect();
        const rtl = window.getComputedStyle(el).direction === "rtl";
        let left = rect.left - gap - size;
        if (rtl) {
            left = rect.right + gap;
        }
        const top = rect.top + (rect.height - size) / 2;

        button.style.top = `${Math.round(top)}px`;
        button.style.left = `${Math.round(left)}px`;
        button.classList.add("mf-remove-btn--visible");
    }

    const onMouseMove = (e: MouseEvent) => {
        if (!editor.isEditable()) {
            hide();
            return;
        }
        const el = blockFrom(e.target);
        if (el) {
            scheduleShow(el);
        } else {
            scheduleHide();
        }
    };

    const onClick = () => {
        const el = target;
        if (!el) {
            return;
        }
        editor.update(() => {
            $getNearestNodeFromDOMNode(el)?.remove();
            const root = $getRoot();
            if (root.getChildrenSize() === 0) {
                root.append($createParagraphNode());
            }
        });
        hide();
        editor.focus();
    };

    const onScroll = () => {
        hide();
    };

    // Keep the button alive while the pointer is on it (it overlaps the block).
    button.addEventListener("mouseenter", cancelHide);
    button.addEventListener("mouseleave", scheduleHide);
    button.addEventListener("click", onClick);
    scrollEl.addEventListener("mousemove", onMouseMove);
    scrollEl.addEventListener("mouseleave", scheduleHide);
    scrollEl.addEventListener("scroll", onScroll, true);

    return () => {
        cancelShow();
        cancelHide();
        scrollEl.removeEventListener("mousemove", onMouseMove);
        scrollEl.removeEventListener("mouseleave", scheduleHide);
        scrollEl.removeEventListener("scroll", onScroll, true);
        button.remove();
    };
}

// --- Editor bootstrap + host bridge wiring ---

// Wire TOGGLE_LINK_COMMAND to $toggleLink. (@lexical/link's registerLink is
// coupled to the extension/signals system, so we register the handler directly.)
function registerLinkCommand(editor: LexicalEditor): () => void {
    return editor.registerCommand(
        TOGGLE_LINK_COMMAND,
        (payload) => {
            if (payload === null) {
                $toggleLink(null);
            } else if (typeof payload === "string") {
                $toggleLink(payload);
            } else {
                const { url, ...attributes } = payload;
                $toggleLink(url, attributes);
            }
            return true;
        },
        COMMAND_PRIORITY_EDITOR,
    );
}

const editor = createEditor({
    namespace: "macfolio",
    theme,
    editable: true,
    // Direction is native: Lexical stamps dir="auto" on top-level blocks, so the
    // browser resolves bidi per paragraph (Persian → RTL, English/code → LTR).
    nodes: [
        HeadingNode,
        QuoteNode,
        ListNode,
        ListItemNode,
        CodeNode,
        CodeHighlightNode,
        LinkNode,
        AutoLinkNode,
        HorizontalRuleNode,
        ImageNode,
        TableNode,
        TableRowNode,
        TableCellNode,
    ],
    onError(error) {
        log("lexical", error);
    },
});

const appElement = document.getElementById("app") as HTMLElement;
const rootElement = document.getElementById("editor") as HTMLElement;
const placeholder = document.getElementById("placeholder") as HTMLElement;
const blockToolbar = document.getElementById("block-toolbar") as HTMLElement;

editor.setRootElement(rootElement);

mergeRegister(
    registerRichText(editor),
    registerHistory(editor, createEmptyHistoryState(), 300),
    registerList(editor),
    registerLinkCommand(editor),
    registerCodeHighlighting(editor),
    registerTablePlugin(editor),
    registerTableSelectionObserver(editor),
    registerTableDirection(editor),
    registerMarkdownShortcuts(editor, MARKDOWN_TRANSFORMERS),
    registerBlockToolbar(editor, blockToolbar),
    registerToolbar(editor),
    registerBlockRemove(editor, appElement),
);

// Placeholder visibility — shown only for a truly empty document.
editor.registerTextContentListener((text) => {
    placeholder.style.display = text === "" ? "block" : "none";
});

// Read the current document back as Markdown (must run inside an editor read).
function currentMarkdown(): string {
    return editor.getEditorState().read(() => {
        return $convertToMarkdownString(MARKDOWN_TRANSFORMERS);
    });
}

// Guarantee the document always has at least one editable block.
function ensureParagraph(): void {
    const root = $getRoot();
    if (root.getChildrenSize() === 0) {
        root.append($createParagraphNode());
    }
}

// --- save (debounced) ---

let saveTimer: ReturnType<typeof setTimeout> | undefined;
let loading = false;

function scheduleSave(): void {
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
        post("save", currentMarkdown());
    }, 400);
}

editor.registerUpdateListener(({ dirtyElements, dirtyLeaves }) => {
    // Ignore pure selection changes and our own programmatic loads.
    if (loading || (dirtyElements.size === 0 && dirtyLeaves.size === 0)) {
        return;
    }

    scheduleSave();
});

// --- Host bridge: inbound calls from the host ---
// (macfolioSetLink is registered by the selection toolbar, which owns the
// selection it needs to restore.)

window.macfolioLoad = (markdown) => {
    loading = true;
    clearTimeout(saveTimer);
    editor.update(
        () => {
            $convertFromMarkdownString(markdown ?? "", MARKDOWN_TRANSFORMERS);
            ensureParagraph();
        },
        { tag: "history-merge" },
    );
    loading = false;
};

window.macfolioSetEditable = (on) => {
    // Flush the latest text before locking so the agent reads current edits.
    if (!on) {
        clearTimeout(saveTimer);
        post("save", currentMarkdown());
    }

    editor.setEditable(on);
};

// Insert a table at the caret with the dimensions from the host's dialog.
window.macfolioInsertTable = (rows, cols) => {
    editor.update(() => {
        if ($getSelection() == null) {
            $getRoot().selectEnd();
        }
    });
    editor.dispatchCommand(INSERT_TABLE_COMMAND, {
        columns: String(cols),
        rows: String(rows),
        includeHeaders: { rows: true, columns: false },
    });
};

// Insert an image (path relative to the .md file) picked in the host dialog.
window.macfolioInsertImage = (src, alt) => {
    editor.update(() => {
        let selection = $getSelection();
        if (selection == null) {
            $getRoot().selectEnd();
            selection = $getSelection();
        }
        if ($isRangeSelection(selection)) {
            selection.insertNodes([$createImageNode(src, alt)]);
        }
    });
};

// --- Start ---

// Suppress the native context menu — it fights the selection toolbar popover.
document.addEventListener("contextmenu", (e) => {
    e.preventDefault();
});

// Start with an empty document, then signal readiness to Swift.
editor.update(
    () => {
        ensureParagraph();
    },
    {
        tag: "history-merge",
    },
);

post("ready");
