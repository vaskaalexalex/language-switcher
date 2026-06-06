import Foundation
import Testing
@testable import LanguageSwitcher

@Suite
struct FrontmostAppTests {
    @Test
    func testIsElectronBundleDetectsFramework() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: root) }

        let frameworks = root
            .appendingPathComponent("Contents")
            .appendingPathComponent("Frameworks")
        try FileManager.default.createDirectory(
            at: frameworks,
            withIntermediateDirectories: true
        )

        #expect(FrontmostApp.isElectronBundle(at: root) == false)

        try FileManager.default.createDirectory(
            at: frameworks.appendingPathComponent("Electron Framework.framework"),
            withIntermediateDirectories: true
        )

        #expect(FrontmostApp.isElectronBundle(at: root) == true)
    }

    @Test
    func testForcePasteClassifiesModernTerminals() {
        // Warp and other AX-write-hostile terminals route through the paste
        // pipeline like Electron.
        #expect(FrontmostApp.isForcePasteBundleId("dev.warp.Warp-Stable") == true)
        #expect(FrontmostApp.isForcePasteBundleId("com.mitchellh.ghostty") == true)
        // Regular apps and Electron apps are not force-paste (Electron is
        // detected separately by its framework).
        #expect(FrontmostApp.isForcePasteBundleId("com.microsoft.VSCode") == false)
        #expect(FrontmostApp.isForcePasteBundleId("com.apple.TextEdit") == false)
    }
}
