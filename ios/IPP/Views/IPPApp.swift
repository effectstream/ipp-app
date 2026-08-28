import SwiftUI

@main
struct IPPApp: App {
    @StateObject private var env = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            SessionGate()
                .environmentObject(env)
                .environmentObject(env.schemaService)
                .environmentObject(env.session)
                .tint(.ippTeal)
                .preferredColorScheme(.light)
                .task {
                    // Find the backend before anything asks it a question: on
                    // device the bundled localhost URL is nobody, and the LAN
                    // host has to be discovered first (Phase 5C).
                    await env.resolveBackend()
                    await env.schemaService.refresh()
                }
        }
    }
}

// Re-renders whenever the SessionService publishes - so logging in, entering
// as viewer, and tapping Salir all flip between LoginView and HomeView
// without any extra plumbing.
private struct SessionGate: View {
    @EnvironmentObject private var session: SessionService

    var body: some View {
        if session.isAuthenticated {
            HomeView()
        } else {
            LoginView()
        }
    }
}
