import XCTest

/// macOS 26 renders Liquid Glass natively. The app used to hand-roll it out of four stacked fills
/// because macOS did not, and the fake could not sample what was behind it, react to motion, or
/// carry the system's edge treatment. These keep the app on the real thing.
final class LiquidGlassAdoptionTests: XCTestCase {
    private func appSources() throws -> [(name: String, lines: [Substring])] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/TokenApp")
        var out: [(String, [Substring])] = []
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            out.append((file.lastPathComponent, body.split(separator: "\n", omittingEmptySubsequences: false)))
        }
        XCTAssertGreaterThan(out.count, 5, "the walk found almost no sources; check the path")
        return out
    }

    /// Every card in the app comes from one view, so this is the whole surface.
    func testCardsUseTheSystemGlassEffect() throws {
        let design = try appSources().first { $0.name == "TokenPilotDesign.swift" }
        let body = try XCTUnwrap(design?.lines.joined(separator: "\n"))

        XCTAssertTrue(body.contains("content.glassEffect(.regular, in: shape)"),
                      "the effect belongs on the content, not behind it")
        XCTAssertFalse(
            body.contains(".fill(.regularMaterial)"),
            "stacking a material with opacity layers is the hand-rolled glass this replaced"
        )
    }

    /// `reduceTransparency` means the user asked for no translucency, and the contrast guarantees in
    /// `DesignConsistencyTests` are computed against the opaque tokens. Glass must not apply there.
    func testReduceTransparencyStillGetsAnOpaqueSurface() throws {
        let design = try appSources().first { $0.name == "TokenPilotDesign.swift" }
        let lines = try XCTUnwrap(design?.lines)
        let start = try XCTUnwrap(lines.firstIndex { $0.contains("struct GlassSurface") })
        let end = try XCTUnwrap(lines[start...].firstIndex { $0 == "}" })
        let view = lines[start...end]

        let branch = try XCTUnwrap(view.firstIndex { $0.contains("if reduceTransparency") })
        let glass = try XCTUnwrap(view.firstIndex { $0.contains("glassEffect") })
        let opaque = try XCTUnwrap(view.firstIndex { $0.contains("palette.surface(surface)") })

        XCTAssertLessThan(branch, opaque, "the opaque fill must sit inside the reduce-transparency branch")
        XCTAssertLessThan(opaque, glass, "glass must be the else branch, not the default")
    }

    /// A blanket swap here was measured to be a regression, so the mapping is pinned: nothing stays on
    /// the old styles, and nothing new arrives on them.
    func testNoButtonIsLeftOnTheOldStyles() throws {
        var offenders: [String] = []
        for source in try appSources() {
            for (index, line) in source.lines.enumerated()
            where line.contains("buttonStyle(.bordered)") || line.contains("buttonStyle(.borderedProminent)") {
                offenders.append("\(source.name):\(index + 1)")
            }
        }
        XCTAssertTrue(offenders.isEmpty, "still on pre-Liquid-Glass button styles: \(offenders)")
    }

    /// `.glass` takes a tint as its *fill*, which turns a secondary button into one that reads as
    /// primary — a red "Delete Token" becomes a solid red call to action. On a glass button the
    /// accent belongs on the label instead.
    func testAGlassButtonIsNeverTinted() throws {
        var offenders: [String] = []
        for source in try appSources() {
            for (index, line) in source.lines.enumerated() where line.contains("buttonStyle(.glass)") {
                let next = source.lines[(index + 1)..<min(index + 3, source.lines.count)]
                if next.contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(".tint(") }) {
                    offenders.append("\(source.name):\(index + 1)")
                }
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "a tint on a glass button fills it and promotes it; use foregroundStyle: \(offenders)"
        )
    }

    /// The popover's own backdrop stays an `NSVisualEffectView`: `glassEffect` samples what is inside
    /// the window, and a menu bar popover needs to blend with the desktop behind it. Rendering both
    /// showed no visible difference, so this is recorded rather than churned.
    func testThePopoverBackdropStaysBehindWindow() throws {
        let overview = try appSources().first { $0.name == "OverviewScreen.swift" }
        let body = try XCTUnwrap(overview?.lines.joined(separator: "\n"))

        XCTAssertTrue(body.contains("VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow)"))
    }

    /// The landmine this closed. Glazing a `Color.clear` behind the content looks identical on its
    /// own, and inside a `GlassEffectContainer` it composites the card's own text into the sampling
    /// and comes out smeared. Applied to the content it stays crisp, so the container is safe to add
    /// — and this keeps the background form from creeping back in and quietly breaking that.
    func testNoCardGlazesAClearBackgroundInstead() throws {
        var offenders: [String] = []
        for source in try appSources() {
            for (index, line) in source.lines.enumerated() where line.contains("Color.clear.glassEffect") {
                offenders.append("\(source.name):\(index + 1)")
            }
        }
        XCTAssertTrue(
            offenders.isEmpty,
            "glazing a clear background smears text inside a GlassEffectContainer: \(offenders)"
        )
    }

    /// One surface for every card, so the conversion cannot be half-applied.
    func testEveryCardSurfaceComesFromTheOneModifier() throws {
        var background = 0
        var modifier = 0
        for source in try appSources() {
            for line in source.lines {
                if line.contains("LiquidGlassBackground") { background += 1 }
                if line.contains(".glassSurface(") { modifier += 1 }
            }
        }
        XCTAssertEqual(background, 0, "the old background view is gone")
        XCTAssertGreaterThanOrEqual(modifier, 7, "expected every card surface plus GlassCard itself")
    }
}
