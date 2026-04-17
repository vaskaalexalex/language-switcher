import SwiftUI

struct OnboardingView: View {
    let onOpenAccessibility: () -> Void
    let onRecheck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "character.bubble")
                    .font(.system(size: 28))
                Text("LanguageSwitcher needs Accessibility access")
                    .font(.title3).bold()
            }

            Text("To detect the Option hotkey and replace text in other apps, macOS requires Accessibility permission.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Steps:").font(.headline)
                Text("1. Click \"Open Accessibility Settings\".")
                Text("2. Enable the LanguageSwitcher toggle in the list.")
                Text("3. If it's already enabled but the app still says \"not trusted\" (common after a rebuild), toggle it OFF and back ON — or remove it with the − button and re-add it.")
                Text("4. The app will pick up the permission automatically; you don't need to relaunch it.")
            }
            .font(.callout)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button("Recheck", action: onRecheck)
                Button("Open Accessibility Settings") {
                    onOpenAccessibility()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320, alignment: .topLeading)
    }
}
