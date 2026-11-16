import SwiftUI

@main
struct PierApp: App {
    @State private var jit: JITSession
    @State private var pod: PodModel
    @Environment(\.scenePhase) private var phase

    init() {
        AppLog.begin()
        let jit = JITSession()
        jit.start()
        _jit = State(initialValue: jit)
        _pod = State(initialValue: PodModel())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(jit)
                .environment(pod)
                .onChange(of: phase) {
                    if phase == .active { jit.cameToFront() }
                }
        }
    }
}
