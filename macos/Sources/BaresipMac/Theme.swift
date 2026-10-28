import SwiftUI

struct ThemePalette {
    let accent: Color
    let button: Color
    let buttonText: Color
    let canvas: Color
    let sidebar: Color
    let surface: Color
    var border: Color { accent.opacity(0.18) }
    var selection: Color { accent.opacity(0.16) }
}
enum AppTheme: String, CaseIterable, Identifiable {
    case system, telnyx, ocean, sunset
    static let storageKey = "workspaceTheme"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var subtitle: String {
        switch self {
        case .system: return "Your Mac's accent and neutral surfaces"
        case .telnyx: return "Mint green, charcoal and warm ivory"
        case .ocean: return "Blue accents and cool slate surfaces"
        case .sunset: return "Warm coral and soft plum surfaces"
        }
    }
    func palette(for scheme: ColorScheme) -> ThemePalette {
        let dark = scheme == .dark
        switch self {
        case .system:
            return ThemePalette(accent: Color(nsColor: .controlAccentColor), button: Color(nsColor: .controlAccentColor), buttonText: Color(nsColor: .selectedControlTextColor),
                                canvas: Color(nsColor: .windowBackgroundColor), sidebar: Color(nsColor: .underPageBackgroundColor), surface: Color(nsColor: .controlBackgroundColor))
        case .telnyx:
            return ThemePalette(accent: .hex(dark ? 0x00E3AA : 0x00775A), button: .hex(0x00E3AA), buttonText: .hex(0x071C16),
                                canvas: .hex(dark ? 0x101A17 : 0xFEFDF5), sidebar: .hex(dark ? 0x0A1310 : 0xF1F2E8), surface: .hex(dark ? 0x1C2923 : 0xFFFFFF))
        case .ocean:
            return ThemePalette(accent: .hex(dark ? 0x80BEFF : 0x245CB8), button: .hex(dark ? 0x80BEFF : 0x245CB8), buttonText: dark ? .hex(0x102238) : .white,
                                canvas: .hex(dark ? 0x111B2A : 0xF2F6FC), sidebar: .hex(dark ? 0x0C1420 : 0xE7EEF8), surface: .hex(dark ? 0x1C2A3D : 0xFFFFFF))
        case .sunset:
            return ThemePalette(accent: .hex(dark ? 0xFFAA91 : 0xA63B25), button: .hex(dark ? 0xFFAA91 : 0xA63B25), buttonText: dark ? .hex(0x2C171D) : .white,
                                canvas: .hex(dark ? 0x23191F : 0xFFF7F2), sidebar: .hex(dark ? 0x191217 : 0xF7E9E2), surface: .hex(dark ? 0x32232C : 0xFFFFFF))
        }
    }
}
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    static let storageKey = "workspaceAppearance"
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: return nil; case .light: return .light; case .dark: return .dark }
    }
}
private struct AppThemeKey: EnvironmentKey { static let defaultValue = AppTheme.telnyx }
extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}
extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
struct WorkspaceTheme: ViewModifier {
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.telnyx.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceID = AppAppearance.system.rawValue
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let theme = AppTheme(rawValue: themeID) ?? .telnyx
        content
            .environment(\.appTheme, theme)
            .tint(theme.palette(for: scheme).accent)
            .accentColor(theme.palette(for: scheme).accent)
            .groupBoxStyle(ThemedGroupBox())
            .preferredColorScheme((AppAppearance(rawValue: appearanceID) ?? .system).scheme)
    }
}
struct ThemedGroupBox: GroupBoxStyle {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            configuration.label.font(.callout.weight(.medium)).foregroundStyle(.secondary)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette(for: scheme).surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.palette(for: scheme).border, lineWidth: 1) }
        }
    }
}

struct AppearanceSettingsView: View {
    @AppStorage(AppTheme.storageKey) private var themeID = AppTheme.telnyx.rawValue
    @AppStorage(AppAppearance.storageKey) private var appearanceID = AppAppearance.system.rawValue
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Appearance").font(.largeTitle.weight(.semibold))
                    Text("Make this workspace yours. Changes apply immediately and are saved on this Mac.").foregroundStyle(.secondary)
                }
                Picker("Appearance", selection: $appearanceID) {
                    ForEach(AppAppearance.allCases) { appearance in Text(appearance.title).tag(appearance.rawValue) }
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    ForEach(AppTheme.allCases) { option in
                        let palette = option.palette(for: scheme)
                        Button { themeID = option.rawValue } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 0) {
                                    VStack(spacing: 6) {
                                        Circle().fill(palette.accent).frame(width: 10, height: 10)
                                        RoundedRectangle(cornerRadius: 3).fill(palette.selection).frame(height: 22)
                                        Spacer(minLength: 0)
                                    }.padding(10).frame(width: 56).background(palette.sidebar)
                                    VStack(alignment: .leading, spacing: 9) {
                                        RoundedRectangle(cornerRadius: 3).fill(palette.accent).frame(width: 70, height: 5)
                                        RoundedRectangle(cornerRadius: 6).fill(palette.surface).frame(height: 28)
                                        Text("Call").font(.caption.weight(.semibold)).foregroundStyle(palette.buttonText)
                                            .padding(.horizontal, 16).padding(.vertical, 4).background(palette.button, in: Capsule())
                                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(palette.canvas)
                                }.frame(height: 110).clipShape(RoundedRectangle(cornerRadius: 9))
                                HStack {
                                    Text(option.title).font(.headline)
                                    Spacer()
                                    Image(systemName: themeID == option.rawValue ? "checkmark.circle.fill" : "circle").foregroundStyle(palette.accent)
                                }
                                Text(option.subtitle).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(14).background(theme.palette(for: scheme).surface, in: RoundedRectangle(cornerRadius: 14))
                                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(themeID == option.rawValue ? theme.palette(for: scheme).accent : theme.palette(for: scheme).border, lineWidth: themeID == option.rawValue ? 2 : 1) }
                        }.buttonStyle(.plain).accessibilityLabel("\(option.title) theme").accessibilityValue(themeID == option.rawValue ? "Selected" : "Not selected")
                    }
                }
                Text("Registration, hold and error indicators keep their familiar status colors in every theme.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.background(theme.palette(for: scheme).canvas)
    }
}
