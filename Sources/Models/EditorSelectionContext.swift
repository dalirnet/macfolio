/// The caret's context in the editor, forwarded so an AI prompt can act on "the
/// selection" or "this line". `blockText` is the paragraph/line the caret sits in.
/// Lives in the model layer (not the AppKit editor) so both platforms' chat can
/// pass it to the agent.
struct EditorSelectionContext: Equatable {
    var selectedText = ""
    var blockText = ""
}
