import SwiftUI

extension Binding {
    /// A `Bool` binding that reads true while the optional holds a value and clears
    /// it back to nil when set false — for driving a sheet / alert / confirmation
    /// dialog off an optional "pending target".
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(
            get: { wrappedValue != nil },
            set: { if !$0 { wrappedValue = nil } })
    }
}
