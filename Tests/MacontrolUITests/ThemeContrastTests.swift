@testable import MacontrolUI
import SwiftUI
import Testing

/// T-0060: status text is readable. WCAG AA asks 4.5:1 for text this size; system green and orange on white give 2.2:1.
@Suite struct ThemeContrastTests {
    @Test(arguments: ["success", "caution", "danger"])
    func statusTextReachesAA(name: String) {
        let color = ["success": Theme.successText, "caution": Theme.cautionText, "danger": Theme.dangerText][name]!
        // White list rows down to a gray sheet or sidebar in light mode; window and control grays in dark mode.
        for (scheme, backgrounds) in [(ColorScheme.light, [1.0, 0.925, 0.898]), (.dark, [0.118, 0.196])] {
            var environment = EnvironmentValues()
            environment.colorScheme = scheme
            let text = color.resolve(in: environment)
            let ink = 0.2126 * Double(text.linearRed) + 0.7152 * Double(text.linearGreen) + 0.0722 * Double(text.linearBlue)
            for gray in backgrounds {
                let paper = Double(Color.Resolved(red: Float(gray), green: Float(gray), blue: Float(gray)).linearRed)
                let ratio = (max(ink, paper) + 0.05) / (min(ink, paper) + 0.05)
                #expect(ratio >= 4.5, "\(name) text in \(scheme) on gray \(gray): \(ratio)")
            }
        }
    }
}
