import SwiftUI

@main
struct MyAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window — PinPhoto lives in the menu bar.
        Settings { EmptyView() }
    }
}
