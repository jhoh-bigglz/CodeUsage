import AppKit
import Foundation
import SwiftUI

/// Command-line debug modes, handled before the app starts.
///
/// - `--dump`: fetch both providers once and print each snapshot as pretty JSON (errors as text) to stdout.
/// - `--render-preview <dir>`: render the popover and menu bar label with built-in sample data
///   (no network) to PNGs at 2x — popover-light.png, popover-dark.png, menubar-light.png, menubar-dark.png.
enum DebugCommands {
    /// Returns true when a debug command ran; the caller should then exit.
    static func runIfRequested() -> Bool {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--dump") {
            runDump()
            return true
        }

        if let index = arguments.firstIndex(of: "--render-preview") {
            let directory = index + 1 < arguments.count ? arguments[index + 1] : "."
            let succeeded: Bool
            if Thread.isMainThread {
                succeeded = MainActor.assumeIsolated { renderPreview(to: directory) }
            } else {
                succeeded = DispatchQueue.main.sync { MainActor.assumeIsolated { renderPreview(to: directory) } }
            }
            // The caller exits with 0; a failed render must not look like success to scripts.
            if !succeeded { exit(1) }
            return true
        }

        return false
    }

    // MARK: - --dump

    /// Thread-safe "finished" flag shared between the fetch task and the run-loop spin.
    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }

        func finish() {
            lock.lock(); done = true; lock.unlock()
        }
    }

    private static func runDump() {
        let providers: [UsageProvider] = [ClaudeProvider(), CodexProvider()]
        let completion = Completion()

        Task.detached {
            let results = await withTaskGroup(of: (Int, String).self) { group in
                for (index, provider) in providers.enumerated() {
                    group.addTask {
                        (index, await dumpText(for: provider))
                    }
                }
                var collected: [(Int, String)] = []
                for await item in group { collected.append(item) }
                return collected.sorted { $0.0 < $1.0 }.map(\.1)
            }
            let output = results.joined(separator: "\n\n") + "\n"
            FileHandle.standardOutput.write(Data(output.utf8))
            completion.finish()
        }

        // Spin the main run loop (so main-queue / main-actor work can still run) until the fetches finish.
        while !completion.isDone {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
    }

    private static func dumpText(for provider: UsageProvider) async -> String {
        let header = "== \(provider.id.displayName) =="
        do {
            let snapshot = try await provider.fetch()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            return header + "\n" + (String(data: data, encoding: .utf8) ?? "")
        } catch let error as ProviderError {
            return header + "\nerror: " + (error.errorDescription ?? String(describing: error))
        } catch {
            return header + "\nerror: " + error.localizedDescription
        }
    }

    // MARK: - --render-preview

    /// Returns false when any file could not be produced.
    @MainActor
    private static func renderPreview(to path: String) -> Bool {
        let directory = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            printError("디렉터리를 만들 수 없습니다: \(directory.path) (\(error.localizedDescription))")
            return false
        }
        var ok = true

        _ = NSApplication.shared
        let store = UsageStore.preview()

        for (scheme, suffix, appearanceName) in [
            (ColorScheme.light, "light", NSAppearance.Name.aqua),
            (ColorScheme.dark, "dark", NSAppearance.Name.darkAqua),
        ] {
            guard let appearance = NSAppearance(named: appearanceName) else { ok = false; continue }

            let windowBackground = resolvedColor(.windowBackgroundColor, in: appearance)
            let popover = PopoverView(store: store)
                .environment(\.colorScheme, scheme)
                .background(windowBackground)
            ok = write(popover, width: 340, appearance: appearance,
                  to: directory.appendingPathComponent("popover-\(suffix).png")) && ok

            // Approximate menu bar backdrop so the label is visible in the PNG.
            let barBackground = scheme == .dark
                ? Color(.sRGB, red: 0.17, green: 0.17, blue: 0.18, opacity: 1)
                : Color(.sRGB, red: 0.96, green: 0.96, blue: 0.96, opacity: 1)
            let label = MenuBarLabel(store: store, forTemplate: false)
                .environment(\.colorScheme, scheme)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(barBackground)
            ok = write(label, width: nil, appearance: appearance,
                  to: directory.appendingPathComponent("menubar-\(suffix).png")) && ok
        }
        return ok
    }

    @MainActor
    private static func write<V: View>(_ view: V, width: CGFloat?, appearance: NSAppearance, to url: URL) -> Bool {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = true
        if let width {
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        }

        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            image = renderer.cgImage
        }
        guard let image else {
            printError("렌더링 실패: \(url.lastPathComponent)")
            return false
        }

        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            printError("PNG 인코딩 실패: \(url.lastPathComponent)")
            return false
        }
        do {
            try data.write(to: url, options: .atomic)
            print("wrote \(url.path) (\(image.width)x\(image.height))")
            return true
        } catch {
            printError("저장 실패: \(url.path) (\(error.localizedDescription))")
            return false
        }
    }

    /// A dynamic AppKit color resolved for a specific appearance, as a fixed SwiftUI color.
    @MainActor
    private static func resolvedColor(_ color: NSColor, in appearance: NSAppearance) -> Color {
        var resolved = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return Color(nsColor: resolved)
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("CodeUsage: \(message)\n".utf8))
    }
}
