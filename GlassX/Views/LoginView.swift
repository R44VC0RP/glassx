import SwiftUI

struct LoginView: View {
    @Environment(AppModel.self) private var model
    @State private var showingSignIn = false
    @State private var webLoading = true

    var body: some View {
        ZStack {
            BackdropGradient()

            VStack(spacing: 22) {
                Text("𝕏")
                    .font(.system(size: 52, weight: .bold))
                    .frame(width: 104, height: 104)
                    .glassEffect(.regular, in: .circle)

                VStack(spacing: 6) {
                    Text("GlassX").font(.system(size: 34, weight: .bold))
                    Text("A native X client for macOS")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.75))
                }

                Button {
                    showingSignIn = true
                } label: {
                    Text("Sign in with X")
                        .font(.headline)
                        .frame(width: 220)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)

                Text("You sign in on x.com inside the app. Your session stays in your Keychain and is only sent to x.com.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(width: 300)
            }
            .padding(44)
            .glassEffect(.regular, in: .rect(cornerRadius: 36))
            .environment(\.colorScheme, .dark)

            if let banner = model.banner {
                VStack {
                    GlassBanner(text: banner) { model.banner = nil }
                    Spacer()
                }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showingSignIn) {
            NavigationStack {
                LoginWebView(onSession: { cookies in
                    showingSignIn = false
                    model.banner = nil
                    model.signIn(with: cookies)
                }, isLoading: $webLoading)
                .frame(width: 520, height: 700)
                .navigationTitle("Sign in to X")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showingSignIn = false } }
                    if webLoading {
                        ToolbarItem(placement: .status) { ProgressView().controlSize(.small) }
                    }
                }
            }
        }
    }
}

/// A soft animated mesh that gives the glass something to refract.
struct BackdropGradient: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = Float(context.date.timeIntervalSinceReferenceDate)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5 + 0.12 * sin(t * 0.4), 0.5 + 0.1 * cos(t * 0.3)], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ],
                colors: [
                    .black, Color(red: 0.05, green: 0.2, blue: 0.45), .black,
                    Color(red: 0.08, green: 0.35, blue: 0.75), .xBlue, Color(red: 0.35, green: 0.15, blue: 0.6),
                    .black, Color(red: 0.1, green: 0.1, blue: 0.3), .black,
                ]
            )
        }
        .ignoresSafeArea()
    }
}
