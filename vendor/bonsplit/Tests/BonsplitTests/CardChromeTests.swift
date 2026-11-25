import XCTest
@testable import Bonsplit
import AppKit

final class CardChromeTests: XCTestCase {
    private static let darkTheme = "#1E1F22"
    private static let lightTheme = "#FFFFFF"
    private static let minimumBorderContrast = 1.5
    private static let minimumTextContrast = 4.5

    private func appearance(_ hex: String, border: String? = nil) -> BonsplitConfiguration.Appearance {
        .init(chromeColors: .init(backgroundHex: hex, borderHex: border))
    }

    private func luminance(_ color: NSColor, over backdrop: NSColor? = nil) -> Double {
        let c = color.usingColorSpace(.sRGB)!
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        if let backdrop, a < 1 {
            let d = backdrop.usingColorSpace(.sRGB)!
            r = r * a + d.redComponent * (1 - a)
            g = g * a + d.greenComponent * (1 - a)
            b = b * a + d.blueComponent * (1 - a)
        }
        func linear(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func testFocusedBorderStandsOutFromWindowBackgroundInDarkAndLightThemes() {
        for hex in [Self.darkTheme, Self.lightTheme] {
            let look = appearance(hex)
            let border = luminance(TabBarColors.nsColorCardBorder(for: look, isFocused: true))
            let window = luminance(TabBarColors.nsColorCardWindowBackground(for: look))
            XCTAssertGreaterThanOrEqual(contrast(border, window), Self.minimumBorderContrast, hex)
        }
    }

    func testFocusedBorderIsStrongerThanUnfocusedBorder() {
        for hex in [Self.darkTheme, Self.lightTheme] {
            let look = appearance(hex)
            let card = luminance(TabBarColors.nsColorPaneBackground(for: look))
            let focused = luminance(TabBarColors.nsColorCardBorder(for: look, isFocused: true))
            let unfocused = luminance(TabBarColors.nsColorCardBorder(for: look, isFocused: false))
            XCTAssertGreaterThan(contrast(focused, card), contrast(unfocused, card), hex)
        }
    }

    func testWindowBackgroundSitsBelowTheCard() {
        let dark = appearance(Self.darkTheme)
        XCTAssertLessThan(
            luminance(TabBarColors.nsColorCardWindowBackground(for: dark)),
            luminance(TabBarColors.nsColorPaneBackground(for: dark))
        )
        let light = appearance(Self.lightTheme)
        XCTAssertLessThan(
            luminance(TabBarColors.nsColorCardWindowBackground(for: light)),
            luminance(TabBarColors.nsColorPaneBackground(for: light))
        )
    }

    func testTranslucentThemeLeavesTheWindowBackgroundClear() {
        let look = appearance("#1E1F22CC")
        let window = TabBarColors.nsColorCardWindowBackground(for: look).usingColorSpace(.sRGB)!
        XCTAssertEqual(window.alphaComponent, 0, accuracy: 0.001)
    }

    func testTabTextReadsOnTheCardInDarkAndLightThemes() {
        for hex in [Self.darkTheme, Self.lightTheme] {
            let look = appearance(hex)
            let card = TabBarColors.nsColorPaneBackground(for: look)
            let text = luminance(TabBarColors.nsColorActiveText(for: look), over: card)
            XCTAssertGreaterThanOrEqual(contrast(text, luminance(card)), Self.minimumTextContrast, hex)
        }
    }

    func testExplicitDividerColorBecomesTheCardBorder() {
        let look = appearance(Self.darkTheme, border: "#112233")
        let focused = TabBarColors.nsColorCardBorder(for: look, isFocused: true).usingColorSpace(.sRGB)!
        XCTAssertEqual(Int(round(focused.redComponent * 255)), 0x11)
        XCTAssertEqual(Int(round(focused.greenComponent * 255)), 0x22)
        XCTAssertEqual(Int(round(focused.blueComponent * 255)), 0x33)
        XCTAssertEqual(focused.alphaComponent, 1, accuracy: 0.001)
        let unfocused = TabBarColors.nsColorCardBorder(for: look, isFocused: false).usingColorSpace(.sRGB)!
        XCTAssertLessThan(unfocused.alphaComponent, 1)
    }

    func testCardGapIsHeldToItsRange() {
        XCTAssertEqual(BonsplitConfiguration.Appearance(cardGap: -4).cardGap, BonsplitCardMetrics.gapRange.lowerBound)
        XCTAssertEqual(BonsplitConfiguration.Appearance(cardGap: 500).cardGap, BonsplitCardMetrics.gapRange.upperBound)

        var look = BonsplitConfiguration.Appearance()
        look.cardGap = -1
        XCTAssertEqual(look.cardGap, BonsplitCardMetrics.gapRange.lowerBound)
        look.cardGap = 12
        XCTAssertEqual(look.cardGap, 12)
    }

    func testShadowIsSofterOnLightThemes() {
        let dark = TabBarColors.nsColorCardFocusedShadow(for: appearance(Self.darkTheme))
        let light = TabBarColors.nsColorCardFocusedShadow(for: appearance(Self.lightTheme))
        XCTAssertGreaterThan(dark.alphaComponent, light.alphaComponent)
    }

    func testPaneToolsShowOnlyForTheFocusedOrHoveredPane() {
        XCTAssertTrue(TabBarStyling.showsPaneTools(isFocused: true, isHovered: false))
        XCTAssertTrue(TabBarStyling.showsPaneTools(isFocused: false, isHovered: true))
        XCTAssertTrue(TabBarStyling.showsPaneTools(isFocused: true, isHovered: true))
        XCTAssertFalse(TabBarStyling.showsPaneTools(isFocused: false, isHovered: false))
    }

    func testTabNeverGrowsWiderThanItsPane() {
        XCTAssertEqual(TabBarStyling.tabMaxWidth(containerWidth: 120), 120)
        XCTAssertEqual(TabBarStyling.tabMaxWidth(containerWidth: 1000), TabBarMetrics.tabMaxWidth)
        XCTAssertEqual(TabBarStyling.tabMaxWidth(containerWidth: 10), TabBarMetrics.tabMinWidth)
        XCTAssertEqual(TabBarStyling.tabMaxWidth(containerWidth: 0), TabBarMetrics.tabMaxWidth)
    }

    func testNarrowPanesFoldTheirToolsIntoOneMenu() {
        XCTAssertTrue(TabBarStyling.foldsPaneTools(barWidth: 260))
        XCTAssertFalse(TabBarStyling.foldsPaneTools(barWidth: 600))
        XCTAssertFalse(TabBarStyling.foldsPaneTools(barWidth: 0), "unmeasured bars keep the full row")
    }
}
