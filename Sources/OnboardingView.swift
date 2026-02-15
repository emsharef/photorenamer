import SwiftUI
import AppKit

struct OnboardingView: View {
    @Binding var hasSeenOnboarding: Bool

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // App icon + title
            appIconImage
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 80, height: 80)

            VStack(spacing: 6) {
                Text("Welcome to PhoDoo")
                    .font(.title)
                    .fontWeight(.bold)
                Text("AI-powered photo renaming")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // Feature bullets
            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "photo.stack", text: "Connect to Piwigo or browse local photo folders")
                featureRow(icon: "brain", text: "AI generates descriptive titles from your photos")
                featureRow(icon: "person.crop.rectangle.stack", text: "Face recognition identifies people automatically")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // How it works
            VStack(alignment: .leading, spacing: 10) {
                Text("How it works")
                    .font(.headline)
                stepRow(number: 1, text: "Connect to your photo source")
                stepRow(number: 2, text: "Select an album and browse photos")
                stepRow(number: 3, text: "AI analyzes each photo and suggests a title")
                stepRow(number: 4, text: "Review and apply the new names")
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )

            // API key hint
            HStack(spacing: 8) {
                Image(systemName: "key")
                    .foregroundStyle(.orange)
                Text("Set up your AI API key in ")
                    + Text("PhoDoo \u{2192} Settings (\u{2318},)")
                        .fontWeight(.medium)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer()

            // Bottom controls
            HStack {
                Toggle("Don't show again", isOn: $hasSeenOnboarding)
                    .toggleStyle(.checkbox)
                    .font(.callout)

                Spacer()

                Button("Get Started") {
                    hasSeenOnboarding = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(32)
        .frame(width: 460, height: 560)
    }

    // MARK: - Helpers

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 24)
            Text(text)
                .font(.callout)
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.blue))
            Text(text)
                .font(.callout)
        }
    }

    private var appIconImage: Image {
        let candidates = [
            Bundle.main.resourcePath.map { "\($0)/AppIcon.icns" },
            Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path,
            "AppIcon.icns",
        ].compactMap { $0 }

        for path in candidates {
            if let nsImage = NSImage(contentsOfFile: path) {
                return Image(nsImage: nsImage)
            }
        }

        return Image(nsImage: NSApp.applicationIconImage)
    }
}
