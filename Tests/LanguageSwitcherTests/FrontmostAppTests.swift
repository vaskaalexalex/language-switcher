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
}
