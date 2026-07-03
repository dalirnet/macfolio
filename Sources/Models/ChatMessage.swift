import Foundation

/// One turn in the co-authoring chat.
struct ChatMessage: Identifiable, Hashable {
    enum Role { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
}
