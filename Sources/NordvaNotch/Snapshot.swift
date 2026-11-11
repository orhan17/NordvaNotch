import AppKit
import NordvaNotchCore
import SwiftUI

/// `--snapshot <dir>`: renders the island with made-up sessions for the README, off screen,
/// so nothing that happens to be on the real screen ends up in the pictures.
@MainActor
enum Snapshot {
    static func write(to directory: String) -> Int32 {
        let prefs = Preferences()
        var failed = false
        for mode in ["banner", "list", "compact"] {
            let feedback = Feedback(prefs: prefs)
            feedback.muted = true
            let island = IslandController(prefs: prefs, feedback: feedback)
            island.demo(mode)
            let model = island.model
            model.anchor = NotchAnchor(centerX: 0, top: 0, notchWidth: 185, height: 32, hasNotch: true)
            let height = IslandLayout.size(of: model.mode, anchor: model.anchor).height + 28
            let view = ZStack(alignment: .top) {
                LinearGradient(
                    colors: [Color(red: 0.42, green: 0.40, blue: 0.86), Color(red: 0.16, green: 0.30, blue: 0.62)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                Color.white.opacity(0.35).frame(height: 32)
                IslandView(model: model, actions: IslandActions())
            }
            .frame(width: IslandLayout.canvasWidth, height: height, alignment: .top)
            .clipped()

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else {
                failed = true
                continue
            }
            let path = directory + "/\(mode).png"
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
            } catch {
                print("failed \(path): \(error)")
                failed = true
            }
        }
        return failed ? 1 : 0
    }
}
