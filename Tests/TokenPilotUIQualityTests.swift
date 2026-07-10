import XCTest

final class TokenPilotUIQualityTests: XCTestCase {
    func testMenuBarLabelStaysDirectSingleLineNumericText() throws {
        let app = try source("Sources/TokenApp/TokenMonitorApp.swift")
        let label = try XCTUnwrap(block(named: "} label:", in: app))

        XCTAssertTrue(label.contains("Text(model.menuBarTitle)"))
        XCTAssertTrue(label.contains(".lineLimit(1)"))
        XCTAssertTrue(label.contains(".fixedSize(horizontal: true, vertical: false)"))
        XCTAssertFalse(label.contains("VStack"))
        XCTAssertFalse(label.contains("HStack"))
        XCTAssertFalse(label.contains("MenuBarProviderMark"))
        XCTAssertFalse(label.contains("TokenPilotMenuBarMark"))
        XCTAssertFalse(label.contains("MenuBarRemainingBadgeRow"))
        XCTAssertFalse(label.contains("menuBarRemainingBadges"))
    }

    func testLegacyStackedMenuBarBadgeViewsAreDeleted() throws {
        let components = try source("Sources/TokenApp/Views/Components.swift")

        XCTAssertFalse(components.contains("struct MenuBarProviderMark"))
        XCTAssertFalse(components.contains("struct TokenPilotMenuBarMark"))
        XCTAssertFalse(components.contains("struct MenuBarRemainingBadgeRow"))
        XCTAssertFalse(components.contains("struct MenuBarRemainingBadge"))
    }

    func testPopoverSurfaceAndTopSummaryUseQuietUtilityContract() throws {
        let app = try source("Sources/TokenApp/TokenMonitorApp.swift")
        let overview = try source("Sources/TokenApp/Views/OverviewScreen.swift")
        let design = try source("Sources/TokenApp/DesignSystem/TokenPilotDesign.swift")
        let components = try source("Sources/TokenApp/Views/Components.swift")
        let uiSource = [app, overview, design, components].joined(separator: "\n")

        XCTAssertTrue(app.contains(".frame(width: 420, height: 620)"))
        XCTAssertTrue(overview.contains("UsageSummaryCard(model: model)"))
        XCTAssertFalse(overview.contains("ResetHeroCard(model: model)"))
        XCTAssertFalse(overview.contains("struct ResetHeroCard"))
        XCTAssertFalse(overview.contains("struct HeroStatPill"))

        XCTAssertTrue(overview.contains("statusText"))
        XCTAssertTrue(overview.contains("remainingText"))
        XCTAssertFalse(components.contains("Text(progressAssistiveText)"))
        XCTAssertTrue(components.contains("accessibilityValue(progressAssistiveText)"))
        XCTAssertFalse(uiSource.contains(".tracking(-"))

        XCTAssertTrue(design.contains("static let cardRadius: CGFloat = 8"))
        XCTAssertFalse(components.contains(".shadow(color:"))
        XCTAssertFalse(uiSource.contains("cornerRadius: 10"))
        XCTAssertFalse(uiSource.contains("cornerRadius: 14"))
        XCTAssertFalse(uiSource.contains(".font(.caption2"))
        XCTAssertFalse(uiSource.contains(".font(.system(size: 8"))
        XCTAssertFalse(uiSource.contains(".font(.system(size: 9"))
    }

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath))
    }

    private func block(named marker: String, in source: String) -> String? {
        guard let markerRange = source.range(of: marker),
              let openingBrace = source[markerRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }

        var depth = 0
        var index = openingBrace
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            let next = source.index(after: index)
            if depth == 0 {
                return String(source[openingBrace..<next])
            }
            index = next
        }
        return nil
    }
}
