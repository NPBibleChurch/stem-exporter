import SwiftUI

/// The app's semantic colours, resolved per appearance.
///
/// Every custom-drawn view — waveforms, the trim scrubber, clip markers — reads
/// its colours from here rather than hardcoding light-mode values, so forcing
/// Light or Dark in Settings changes the drawing as well as the chrome.
struct Palette: Equatable {

    var windowBackground: Color
    var chromeBackground: Color
    var sidebarBackground: Color
    var controlBackground: Color
    var rowHighlight: Color
    var rowSelected: Color

    var separator: Color
    var hairline: Color
    var controlBorder: Color

    var label: Color
    var secondaryLabel: Color
    var tertiaryLabel: Color
    var quaternaryLabel: Color

    var accent: Color
    var waveform: Color
    var waveformMuted: Color
    var mixWaveform: Color

    var clip: Color
    var clipLabel: Color
    var success: Color
    var trimHandle: Color
    var trimShade: Color
    var trimRegion: Color
    var playhead: Color
    var playheadGuide: Color

    var warningBackground: Color
    var warningBorder: Color
    var warningLabel: Color

    static let light = Palette(
        windowBackground: Color(hex: 0xFBFBFD),
        chromeBackground: Color(hex: 0xF3F3F5),
        sidebarBackground: Color(hex: 0xF5F5F7),
        controlBackground: .white,
        rowHighlight: Color(hex: 0xF0F6FF),
        rowSelected: Color(hex: 0xF7FBFF),
        separator: Color(hex: 0xE5E5E9),
        hairline: Color(hex: 0xF0F0F2),
        controlBorder: Color(hex: 0xD4D4D8),
        label: Color(hex: 0x1D1D1F),
        secondaryLabel: Color(hex: 0x6E6E73),
        tertiaryLabel: Color(hex: 0x86868B),
        quaternaryLabel: Color(hex: 0xC7C7CC),
        accent: Color(hex: 0x0A7CFF),
        waveform: Color(hex: 0x0A7CFF),
        waveformMuted: Color(hex: 0xC7C7CC),
        mixWaveform: Color(hex: 0xB9C6D6),
        clip: Color(hex: 0xFF3B30),
        clipLabel: Color(hex: 0xB31217),
        success: Color(hex: 0x28C840),
        trimHandle: Color(hex: 0xFF9F0A),
        trimShade: Color(red: 0.47, green: 0.51, blue: 0.55, opacity: 0.35),
        trimRegion: Color(hex: 0xFF9F0A).opacity(0.08),
        playhead: Color(hex: 0x1D1D1F),
        playheadGuide: Color(hex: 0x1D1D1F).opacity(0.22),
        warningBackground: Color(hex: 0xFFF6E5),
        warningBorder: Color(hex: 0xFFE1A6),
        warningLabel: Color(hex: 0x8A5A00)
    )

    static let dark = Palette(
        windowBackground: Color(hex: 0x1E1E20),
        chromeBackground: Color(hex: 0x2A2A2C),
        sidebarBackground: Color(hex: 0x252527),
        controlBackground: Color(hex: 0x323235),
        rowHighlight: Color(hex: 0x2B3444),
        rowSelected: Color(hex: 0x24303F),
        separator: Color(hex: 0x38383D),
        hairline: Color(hex: 0x2D2D31),
        controlBorder: Color(hex: 0x48484D),
        label: Color(hex: 0xF2F2F7),
        secondaryLabel: Color(hex: 0xAEAEB2),
        tertiaryLabel: Color(hex: 0x8E8E93),
        quaternaryLabel: Color(hex: 0x5A5A5F),
        accent: Color(hex: 0x3B9BFF),
        waveform: Color(hex: 0x3B9BFF),
        waveformMuted: Color(hex: 0x5A5A5F),
        mixWaveform: Color(hex: 0x6E7B8C),
        clip: Color(hex: 0xFF6961),
        clipLabel: Color(hex: 0xFF8A80),
        success: Color(hex: 0x32D74B),
        trimHandle: Color(hex: 0xFFB340),
        trimShade: Color(red: 0.05, green: 0.05, blue: 0.06, opacity: 0.55),
        trimRegion: Color(hex: 0xFFB340).opacity(0.10),
        playhead: Color(hex: 0xF2F2F7),
        playheadGuide: Color(hex: 0xF2F2F7).opacity(0.28),
        warningBackground: Color(hex: 0x3A2E14),
        warningBorder: Color(hex: 0x5C4718),
        warningLabel: Color(hex: 0xF5C463)
    )

    static func forScheme(_ scheme: ColorScheme) -> Palette {
        scheme == .dark ? .dark : .light
    }
}

private struct PaletteKey: EnvironmentKey {
    static let defaultValue = Palette.light
}

extension EnvironmentValues {
    var palette: Palette {
        get { self[PaletteKey.self] }
        set { self[PaletteKey.self] = newValue }
    }
}

extension View {
    /// Resolve the palette from the effective colour scheme and hand it down.
    ///
    /// Deriving it from SwiftUI's own `colorScheme` (rather than from NSAppearance)
    /// is what makes the explicit Light/Dark setting work: `.preferredColorScheme`
    /// changes that environment value, and everything below re-reads its colours.
    func withPalette() -> some View {
        modifier(PaletteModifier())
    }
}

private struct PaletteModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.environment(\.palette, Palette.forScheme(colorScheme))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

extension Font {
    /// The tabular numerals the timecode readouts need so digits don't jitter.
    static func monoDigits(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}
