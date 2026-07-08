import {
    $createCodeNode,
    $isCodeNode,
    CodeHighlightNode,
    CodeNode,
} from "@lexical/code";
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
    $createNodeSelection,
    $createParagraphNode,
    $createRangeSelection,
    $getNearestNodeFromDOMNode,
    $getRoot,
    $getSelection,
    $isNodeSelection,
    $isParagraphNode,
    $isRangeSelection,
    $setSelection,
    CAN_REDO_COMMAND,
    CAN_UNDO_COMMAND,
    COMMAND_PRIORITY_EDITOR,
    COMMAND_PRIORITY_LOW,
    DecoratorNode,
    FORMAT_TEXT_COMMAND,
    REDO_COMMAND,
    SELECTION_CHANGE_COMMAND,
    UNDO_COMMAND,
    createEditor,
} from "lexical";

import type { ElementTransformer, Transformer } from "@lexical/markdown";
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
import redoIcon from "../Icons/redo.svg?raw";
import tableIcon from "../Icons/table.svg?raw";
import undoIcon from "../Icons/undo.svg?raw";

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
        macfolioSetImage: (src: string, alt: string) => void;
        macfolioInsertCodeBlock: (language: string) => void;
        macfolioFind: (query: string) => void;
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

// Divider — a horizontal rule, rendered as a div (see createDOM).
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
        // A div, not <hr> — WebKit renders <hr> height inconsistently.
        const line = document.createElement("div");
        line.className = "mf-hr";
        return line;
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
        const figure = document.createElement("figure");
        figure.className = "mf-image";
        const img = document.createElement("img");
        img.src = mediaUrl(this.__src);
        img.alt = this.__alt;
        figure.appendChild(img);
        // Alt, when set, reads as a centered caption below the image.
        if (this.__alt) {
            const caption = document.createElement("figcaption");
            caption.className = "mf-image-alt";
            caption.textContent = this.__alt;
            figure.appendChild(caption);
        }
        return figure;
    }

    updateDOM(): boolean {
        return false;
    }

    getTextContent(): string {
        return this.__alt;
    }

    isInline(): boolean {
        // Block-level: an image owns its line, so no caret can sit beside it and
        // no text can be typed alongside it.
        return false;
    }

    decorate(): null {
        return null;
    }
}

function $createImageNode(src: string, alt: string): ImageNode {
    return $applyNodeReplacement(new ImageNode(src, alt));
}

function $isImageNode(node: LexicalNode | null | undefined): node is ImageNode {
    return node instanceof ImageNode;
}

// The caret captured when the editor loses focus (e.g. clicking a sidebar image,
// or opening the native code-language picker), restored before the host callback
// inserts so the change lands where the cursor was.
let savedSelection: BaseSelection | null = null;

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

// Grow/shrink an existing table to `rows`×`cols`, keeping existing cell content.
function resizeTable(table: TableNode, rows: number, cols: number): void {
    const rowNodes = table.getChildren().filter($isTableRowNode);
    // Match each existing row's column count.
    rowNodes.forEach((row, r) => {
        const cells = row.getChildren().filter($isTableCellNode);
        for (let c = cells.length; c < cols; c++) {
            row.append($createTableCell("", r === 0));
        }
        for (let c = cells.length - 1; c >= cols; c--) {
            cells[c].remove();
        }
    });
    // Add missing rows / remove extra ones.
    for (let r = rowNodes.length; r < rows; r++) {
        const row = $createTableRowNode();
        for (let c = 0; c < cols; c++) {
            row.append($createTableCell("", false));
        }
        table.append(row);
    }
    for (let r = rowNodes.length - 1; r >= rows; r--) {
        rowNodes[r].remove();
    }
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

// Image: a whole line of `![alt](src)` becomes a block-level image node.
const IMAGE_TRANSFORMER: ElementTransformer = {
    dependencies: [ImageNode],
    export(node) {
        if (!$isImageNode(node)) {
            return null;
        }
        return `![${node.getAlt()}](${node.getSrc()})`;
    },
    regExp: /^!\[([^\]]*)\]\(([^)]+)\)\s?$/,
    replace(parentNode, _children, match, isImport) {
        const [, alt, src] = match;
        const image = $createImageNode(src, alt);
        if (isImport || parentNode.getNextSibling() != null) {
            parentNode.replace(image);
        } else {
            parentNode.insertBefore(image);
        }
        image.selectNext();
    },
    triggerOnEnter: true,
    type: "element",
};

// Single source of truth for Markdown <-> editor conversion, used by both the
// load/save round-trip and the live typing shortcuts (`# `, `- `, ``` ``` ```, etc.).
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
    // True when the caret's block is this type — highlights the button (read only).
    active?: () => boolean;
}

// The caret's top-level block, or null when the selection isn't a caret. Read only.
function $caretTopLevel(): LexicalNode | null {
    const selection = $getSelection();
    return $isRangeSelection(selection)
        ? selection.anchor.getNode().getTopLevelElement()
        : null;
}

// Whether the caret sits inside a table (read only).
function $inTable(): boolean {
    const selection = $getSelection();
    return (
        $isRangeSelection(selection) &&
        $isTableNode(
            $findMatchingParent(selection.anchor.getNode(), $isTableNode),
        )
    );
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

// Grouped for the toolbar (a thin separator is drawn between groups), ordered by
// popularity: the right group sits at the toolbar's right edge, so the most-used
// blocks (headings, then lists) go last and the least-used (quote / code / table)
// go first.
const BLOCK_GROUPS: BlockItem[][] = [
    [
        {
            icon: codeBlockIcon,
            label: "Code Block",
            // Ask the host for the language picker, preselecting the caret's code
            // block language so it can be changed (see macfolioInsertCodeBlock).
            run(editor) {
                let current = "";
                editor.getEditorState().read(() => {
                    const block = $caretTopLevel();
                    if ($isCodeNode(block)) {
                        current = block.getLanguage() ?? "";
                    }
                });
                post("code", current);
            },
            active: () => $isCodeNode($caretTopLevel()),
        },
        {
            icon: tableIcon,
            label: "Table",
            // Ask the host for the rows/cols dialog, prefilled from the caret's
            // table so it can be resized (see macfolioInsertTable).
            run(editor) {
                let dims: { rows: number; cols: number } | null = null;
                editor.getEditorState().read(() => {
                    const selection = $getSelection();
                    if (!$isRangeSelection(selection)) {
                        return;
                    }
                    const table = $findMatchingParent(
                        selection.anchor.getNode(),
                        $isTableNode,
                    );
                    if ($isTableNode(table)) {
                        const rowNodes = table
                            .getChildren()
                            .filter($isTableRowNode);
                        dims = {
                            rows: rowNodes.length,
                            cols:
                                rowNodes[0]
                                    ?.getChildren()
                                    .filter($isTableCellNode).length ?? 0,
                        };
                    }
                });
                post("table", dims);
            },
            active: $inTable,
        },
        {
            icon: imageIcon,
            label: "Image",
            // Ask the host for the image picker + alt field, prefilled when an
            // image is selected so it can be changed (see macfolioSetImage).
            run(editor) {
                let data: { src: string; alt: string } | null = null;
                editor.getEditorState().read(() => {
                    const selection = $getSelection();
                    const node = $isNodeSelection(selection)
                        ? selection.getNodes().find($isImageNode)
                        : null;
                    if ($isImageNode(node)) {
                        data = { src: node.getSrc(), alt: node.getAlt() };
                    }
                });
                post("image", data);
            },
            active: () => {
                const selection = $getSelection();
                return (
                    $isNodeSelection(selection) &&
                    selection.getNodes().some($isImageNode)
                );
            },
        },
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
        {
            icon: quoteIcon,
            label: "Quote",
            run(editor) {
                setBlock(editor, () => {
                    return $createQuoteNode();
                });
            },
        },
    ],
    [
        { icon: h3Icon, label: "Heading 3", run: heading("h3") },
        { icon: h2Icon, label: "Heading 2", run: heading("h2") },
        { icon: h1Icon, label: "Heading 1", run: heading("h1") },
    ],
];

// Sticky top toolbar: a left group of document actions (undo / redo / copy the
// Markdown) and a right group that inserts / converts blocks. Block buttons act on
// the current selection (falling back to the document end when nothing is focused).
function registerBlockToolbar(
    editor: LexicalEditor,
    container: HTMLElement,
): () => void {
    // Never let a toolbar press move the caret / clear the selection.
    container.addEventListener("mousedown", (e) => {
        e.preventDefault();
    });

    function iconButton(
        icon: string,
        label: string,
        onClick: () => void,
    ): HTMLButtonElement {
        const btn = document.createElement("button");
        btn.type = "button";
        btn.className = "mf-block-btn";
        btn.title = label;
        btn.innerHTML = icon;
        btn.addEventListener("click", (e) => {
            e.preventDefault();
            onClick();
        });
        return btn;
    }

    const separator = (): HTMLSpanElement => {
        const sep = document.createElement("span");
        sep.className = "mf-block-sep";
        return sep;
    };

    const left = document.createElement("div");
    left.className = "mf-toolbar-side";

    const undoBtn = iconButton(undoIcon, "Undo", () => {
        editor.dispatchCommand(UNDO_COMMAND, undefined);
        editor.focus();
    });
    const redoBtn = iconButton(redoIcon, "Redo", () => {
        editor.dispatchCommand(REDO_COMMAND, undefined);
        editor.focus();
    });
    undoBtn.disabled = true;
    redoBtn.disabled = true;
    left.append(undoBtn, redoBtn);

    const right = document.createElement("div");
    right.className = "mf-toolbar-side";

    // Buttons that light up (primary) when the caret sits in their block type.
    const actives: Array<{ btn: HTMLButtonElement; active: () => boolean }> =
        [];
    BLOCK_GROUPS.forEach((group, index) => {
        if (index > 0) {
            right.appendChild(separator());
        }
        for (const item of group) {
            const btn = iconButton(item.icon, item.label, () => {
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
            right.appendChild(btn);
            if (item.active) {
                actives.push({ btn, active: item.active });
            }
        }
    });

    container.append(left, right);

    const unregister = mergeRegister(
        editor.registerEditableListener((editable) => {
            container.classList.toggle("mf-block-toolbar--disabled", !editable);
        }),
        editor.registerCommand(
            CAN_UNDO_COMMAND,
            (payload) => {
                undoBtn.disabled = !payload;
                return false;
            },
            COMMAND_PRIORITY_LOW,
        ),
        editor.registerCommand(
            CAN_REDO_COMMAND,
            (payload) => {
                redoBtn.disabled = !payload;
                return false;
            },
            COMMAND_PRIORITY_LOW,
        ),
        editor.registerUpdateListener(() => {
            editor.getEditorState().read(() => {
                for (const { btn, active } of actives) {
                    btn.classList.toggle("mf-block-btn--active", active());
                }
            });
        }),
    );

    return () => {
        unregister();
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
    '<svg viewBox="0 0 24 24" fill="currentColor">' +
    '<g transform="translate(4.15 2.98) scale(0.83)"><path d="' +
    "M6.5625 18.6035C6.93359 18.6035 7.17773 18.3691 7.16797 18.0273L6.86523 7.57812C6.85547 7.23633 6.61133 7.01172 6.25977 7.01172C5.88867 7.01172 5.64453 7.24609 5.6543 7.58789L5.94727 18.0273C5.95703 18.3789 6.20117 18.6035 6.5625 18.6035ZM9.45312 18.6035C9.82422 18.6035 10.0879 18.3691 10.0879 18.0273L10.0879 7.58789C10.0879 7.24609 9.82422 7.01172 9.45312 7.01172C9.08203 7.01172 8.82812 7.24609 8.82812 7.58789L8.82812 18.0273C8.82812 18.3691 9.08203 18.6035 9.45312 18.6035ZM12.3535 18.6035C12.7051 18.6035 12.9492 18.3789 12.959 18.0273L13.252 7.58789C13.2617 7.24609 13.0176 7.01172 12.6465 7.01172C12.2949 7.01172 12.0508 7.23633 12.041 7.58789L11.748 18.0273C11.7383 18.3691 11.9824 18.6035 12.3535 18.6035ZM5.16602 4.46289L6.71875 4.46289L6.71875 2.37305C6.71875 1.81641 7.10938 1.45508 7.69531 1.45508L11.1914 1.45508C11.7773 1.45508 12.168 1.81641 12.168 2.37305L12.168 4.46289L13.7207 4.46289L13.7207 2.27539C13.7207 0.859375 12.8027 0 11.2988 0L7.58789 0C6.08398 0 5.16602 0.859375 5.16602 2.27539ZM0.732422 5.24414L18.1836 5.24414C18.584 5.24414 18.9062 4.90234 18.9062 4.50195C18.9062 4.10156 18.584 3.76953 18.1836 3.76953L0.732422 3.76953C0.341797 3.76953 0 4.10156 0 4.50195C0 4.91211 0.341797 5.24414 0.732422 5.24414ZM4.98047 21.748L13.9355 21.748C15.332 21.748 16.2695 20.8398 16.3379 19.4434L17.0215 5.05859L15.4492 5.05859L14.7949 19.2773C14.7754 19.8633 14.3555 20.2734 13.7793 20.2734L5.11719 20.2734C4.56055 20.2734 4.14062 19.8535 4.11133 19.2773L3.41797 5.05859L1.88477 5.05859L2.57812 19.4531C2.64648 20.8496 3.56445 21.748 4.98047 21.748Z" +
    '"/></g></svg>';

// Marks the focused block: a "×" in its start-side gutter (click to delete it)
// and a full-height accent bar in the opposite gutter (the AI's "this block").
// Both follow the caret/selection, not the mouse. The bar persists when focus
// leaves for the prompt field — only the delete button hides. Returns a teardown.
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

    // A full-height bar in the block's *end* gutter (opposite the remove button)
    // marking the focused block — the one an AI prompt treats as "this block". It
    // stays put when focus leaves the editor for the prompt field (only the delete
    // button hides on blur), so you can see what the prompt will act on.
    const bar = document.createElement("div");
    bar.className = "mf-block-bar";
    document.body.appendChild(bar);

    let target: HTMLElement | null = null;

    // No focused block: hide both.
    function hide(): void {
        button.classList.remove("mf-remove-btn--visible");
        bar.classList.remove("mf-block-bar--visible");
        target = null;
    }

    // On blur, hide only the delete button; keep the bar on the last block so it
    // stays visible while the user types in the prompt field.
    function hideButton(): void {
        button.classList.remove("mf-remove-btn--visible");
    }

    // Sit in the block's side gutter (start side for LTR, end for RTL), vertically
    // centered — never over the block.
    function positionFor(el: HTMLElement): void {
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
    }

    // The bar spans the block's full height in the end-side gutter — the opposite
    // side from the remove button (right for LTR, left for RTL). Anchored to the
    // text column's edge (from the editor root), not the block's own width, so
    // shrink-to-fit blocks (images, tables) get the bar in the same side gutter as
    // text instead of hugging their edge.
    function positionBar(el: HTMLElement): void {
        const gap = 6;
        const width = 3;
        const rect = el.getBoundingClientRect();
        const column = editorEl!.getBoundingClientRect();
        const style = window.getComputedStyle(editorEl!);
        const padLeft = parseFloat(style.paddingLeft) || 0;
        const padRight = parseFloat(style.paddingRight) || 0;
        const rtl = window.getComputedStyle(el).direction === "rtl";
        const left = rtl
            ? column.left + padLeft - gap - width
            : column.right - padRight + gap;
        bar.style.top = `${Math.round(rect.top)}px`;
        bar.style.height = `${Math.round(rect.height)}px`;
        bar.style.left = `${Math.round(left)}px`;
    }

    // DOM element of the top-level block holding the current selection (works for
    // text blocks via the caret and for decorators — image / divider — selected
    // as a node).
    function focusedBlockEl(): HTMLElement | null {
        return editor.getEditorState().read(() => {
            const selection = $getSelection();
            const node = $isRangeSelection(selection)
                ? selection.anchor.getNode()
                : (selection?.getNodes()[0] ?? null);
            if (!node) {
                return null;
            }
            // A caret inside a table targets the whole table, not the cell.
            const table = $findMatchingParent(node, $isTableNode);
            const top =
                ($isTableNode(table) ? table : node.getTopLevelElement()) ??
                node;
            // The auto-enforced trailing empty paragraph isn't removable — deleting
            // it would just be re-added.
            if (
                $isParagraphNode(top) &&
                top.getTextContentSize() === 0 &&
                top.getNextSibling() === null
            ) {
                return null;
            }
            return editor.getElementByKey(top.getKey());
        });
    }

    function refresh(): void {
        const el = editor.isEditable() ? focusedBlockEl() : null;
        if (el) {
            target = el;
            positionFor(el);
            positionBar(el);
            button.classList.add("mf-remove-btn--visible");
            bar.classList.add("mf-block-bar--visible");
        } else {
            hide();
        }
    }

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
        editor.focus();
    };

    const reposition = () => {
        if (target) {
            positionFor(target);
            positionBar(target);
        }
    };

    button.addEventListener("click", onClick);
    editorEl.addEventListener("blur", hideButton);
    editorEl.addEventListener("focus", refresh);
    scrollEl.addEventListener("scroll", reposition, true);
    const unregisterUpdate = editor.registerUpdateListener(() => {
        refresh();
    });

    return () => {
        unregisterUpdate();
        editorEl.removeEventListener("blur", hideButton);
        editorEl.removeEventListener("focus", refresh);
        scrollEl.removeEventListener("scroll", reposition, true);
        button.remove();
        bar.remove();
    };
}

// --- Block decorator selection ---

// Clicking a block decorator (image or divider) selects it as a node, so it reads
// as selected — the toolbar icon lights up, the remove button appears, and no text
// caret sits on it.
function registerDecoratorSelection(editor: LexicalEditor): () => void {
    const root = editor.getRootElement();
    if (!root) {
        return () => {};
    }

    const onClick = (e: MouseEvent) => {
        const el = (e.target as HTMLElement).closest(".mf-image, .mf-hr");
        if (!el) {
            return;
        }
        editor.update(() => {
            const node = $getNearestNodeFromDOMNode(el);
            if ($isImageNode(node) || $isHorizontalRuleNode(node)) {
                const selection = $createNodeSelection();
                selection.add(node.getKey());
                $setSelection(selection);
            }
        });
    };
    root.addEventListener("click", onClick);
    return () => root.removeEventListener("click", onClick);
}

// --- Table click guard ---

// The cell nearest a point, for redirecting stray clicks into the table.
function nearestCell(
    tableEl: HTMLElement,
    x: number,
    y: number,
): HTMLElement | null {
    let best: HTMLElement | null = null;
    let bestDist = Infinity;
    tableEl.querySelectorAll<HTMLElement>(".mf-td, .mf-th").forEach((cell) => {
        const r = cell.getBoundingClientRect();
        const dx = Math.max(r.left - x, 0, x - r.right);
        const dy = Math.max(r.top - y, 0, y - r.bottom);
        const dist = dx * dx + dy * dy;
        if (dist < bestDist) {
            bestDist = dist;
            best = cell;
        }
    });
    return best;
}

// A click on a table's chrome or the empty space beside it drops the caret before
// the table (where typing spawns a stray paragraph). Redirect such clicks into the
// nearest cell so text only goes inside cells.
function registerTableClickGuard(editor: LexicalEditor): () => void {
    const root = editor.getRootElement();
    if (!root) {
        return () => {};
    }

    const onMouseDown = (e: MouseEvent) => {
        const target = e.target as HTMLElement;
        if (target.closest(".mf-td, .mf-th")) {
            return; // a real cell click — leave it alone
        }
        for (const tableEl of root.querySelectorAll<HTMLElement>(".mf-table")) {
            const rect = tableEl.getBoundingClientRect();
            if (e.clientY < rect.top || e.clientY > rect.bottom) {
                continue;
            }
            e.preventDefault();
            const cellEl = nearestCell(tableEl, e.clientX, e.clientY);
            editor.update(() => {
                const cell = cellEl ? $getNearestNodeFromDOMNode(cellEl) : null;
                if ($isTableCellNode(cell)) {
                    cell.selectEnd();
                }
            });
            editor.focus();
            return;
        }
    };
    root.addEventListener("mousedown", onMouseDown);
    return () => root.removeEventListener("mousedown", onMouseDown);
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

// Remember the caret when focus leaves the editor (clicking a sidebar image, or
// the native code-language picker) so the host callback lands where the cursor was.
rootElement.addEventListener("blur", () => {
    editor.getEditorState().read(() => {
        const selection = $getSelection();
        if (selection) {
            savedSelection = selection.clone();
        }
    });
});

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
    registerDecoratorSelection(editor),
    registerTableClickGuard(editor),
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

// Guarantee the document ends with a paragraph (and so is never empty), so there
// is always an empty block to type into after a table / image / divider / code
// block. Must run inside an editor update.
function ensureTrailingParagraph(): void {
    const root = $getRoot();
    const last = root.getLastChild();
    if (last === null || !$isParagraphNode(last)) {
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

// Re-assert the trailing paragraph after block edits (e.g. inserting a table or
// deleting the last block). The append converges — once the last node is a
// paragraph the inner update makes no change and doesn't re-fire.
editor.registerUpdateListener(({ dirtyElements }) => {
    if (loading || dirtyElements.size === 0) {
        return;
    }
    editor.update(() => {
        ensureTrailingParagraph();
    });
});

// --- Selection context ---
// Report the caret's block ("this line") and any selected text to the host, so an
// AI prompt like "expand the selection" or "remove this line" has something
// concrete to act on. Skip non-range selections (e.g. when focus leaves the
// editor to the prompt field) so the last in-editor selection is preserved.

let lastSelectionReport = "";

function reportSelection(): void {
    editor.getEditorState().read(() => {
        const selection = $getSelection();
        if (!$isRangeSelection(selection)) {
            return;
        }
        const selectedText = selection.getTextContent();
        const block = selection.anchor.getNode().getTopLevelElement();
        const blockText = block ? block.getTextContent() : "";
        const payload = JSON.stringify({ selectedText, blockText });
        if (payload !== lastSelectionReport) {
            lastSelectionReport = payload;
            post("selection", { selectedText, blockText });
        }
    });
}

editor.registerUpdateListener(() => {
    reportSelection();
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
            ensureTrailingParagraph();
            // Start the caret in the last (trailing) paragraph, ready to write.
            $getRoot().selectEnd();
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

// Resize the caret's table to the dialog's dimensions, or insert a new one.
window.macfolioInsertTable = (rows, cols) => {
    let resized = false;
    editor.update(() => {
        if (savedSelection) {
            $setSelection(savedSelection.clone());
        }
        const selection = $getSelection();
        const table = $isRangeSelection(selection)
            ? $findMatchingParent(selection.anchor.getNode(), $isTableNode)
            : null;
        if ($isTableNode(table)) {
            resizeTable(table, rows, cols);
            resized = true;
        } else if ($getSelection() == null) {
            $getRoot().selectEnd();
        }
    });
    savedSelection = null;
    if (resized) {
        return;
    }
    editor.dispatchCommand(INSERT_TABLE_COMMAND, {
        columns: String(cols),
        rows: String(rows),
        includeHeaders: { rows: true, columns: false },
    });
};

// Swap a selected image's source/alt, or insert one into the caret's empty
// paragraph (so images land in a deliberate empty block, never mid-text). Paths
// are relative to the .md file.
window.macfolioSetImage = (src, alt) => {
    editor.update(() => {
        if (savedSelection) {
            $setSelection(savedSelection.clone());
        }
        const selection = $getSelection();
        // Editing the selected image.
        if ($isNodeSelection(selection)) {
            const node = selection.getNodes().find($isImageNode);
            if ($isImageNode(node)) {
                node.replace($createImageNode(src, alt));
                return;
            }
        }
        // Inserting into an empty paragraph.
        if (!$isRangeSelection(selection) || !selection.isCollapsed()) {
            return;
        }
        const block = selection.anchor.getNode().getTopLevelElement();
        if (!$isParagraphNode(block) || block.getTextContentSize() !== 0) {
            return;
        }
        const image = $createImageNode(src, alt);
        block.replace(image);
        const nodeSelection = $createNodeSelection();
        nodeSelection.add(image.getKey());
        $setSelection(nodeSelection);
    });
    savedSelection = null;
};

// Set the language of the caret's code block, or turn its block into a new code
// block in the picked language (empty language = plain).
window.macfolioInsertCodeBlock = (language) => {
    editor.update(() => {
        if (savedSelection) {
            $setSelection(savedSelection.clone());
        }
        let selection = $getSelection();
        const block = $isRangeSelection(selection)
            ? selection.anchor.getNode().getTopLevelElement()
            : null;
        if ($isCodeNode(block)) {
            block.setLanguage(language || "");
            return;
        }
        if (!$isRangeSelection(selection)) {
            $getRoot().selectEnd();
            selection = $getSelection();
        }
        if ($isRangeSelection(selection)) {
            $setBlocksType(selection, () =>
                $createCodeNode(language || undefined),
            );
        }
    });
    savedSelection = null;
};

// Jump to the first occurrence of `query` (case-insensitive): select it and
// scroll its block into view. Used by the host's ⌘F search to open a result on
// its match. No-op when the text isn't in the body (e.g. a title-only match).
window.macfolioFind = (query) => {
    const needle = (query ?? "").trim().toLowerCase();
    if (!needle) {
        return;
    }
    let blockKey: string | null = null;
    editor.update(() => {
        for (const node of $getRoot().getAllTextNodes()) {
            const index = node.getTextContent().toLowerCase().indexOf(needle);
            if (index === -1) {
                continue;
            }
            const selection = $createRangeSelection();
            selection.anchor.set(node.getKey(), index, "text");
            selection.focus.set(node.getKey(), index + needle.length, "text");
            $setSelection(selection);
            blockKey = node.getTopLevelElement()?.getKey() ?? node.getKey();
            break;
        }
    });
    if (!blockKey) {
        return;
    }
    // Reveal it: focus so the selection renders, then centre its element.
    editor.focus();
    editor
        .getElementByKey(blockKey)
        ?.scrollIntoView({ block: "center", behavior: "smooth" });
};

// --- Start ---

// Suppress the native context menu — it fights the selection toolbar popover.
document.addEventListener("contextmenu", (e) => {
    e.preventDefault();
});

// Start with an empty document, then signal readiness to Swift.
editor.update(
    () => {
        ensureTrailingParagraph();
    },
    {
        tag: "history-merge",
    },
);

post("ready");
