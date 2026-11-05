import SwiftUI

struct PhoneKeypad: View {
    let actionLabel: String
    let onDigit: (String) -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]
    private let letters = ["2": "ABC", "3": "DEF", "4": "GHI", "5": "JKL", "6": "MNO", "7": "PQRS", "8": "TUV", "9": "WXYZ", "0": "+"]
    var body: some View {
        VStack(spacing: 8) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { digit in
                        Button { onDigit(digit) } label: {
                            VStack(spacing: 1) {
                                Text(digit).font(.system(size: 25, weight: .medium, design: .rounded))
                                Text(letters[digit] ?? " ").font(.system(size: 8, weight: .semibold)).tracking(1).foregroundStyle(.secondary)
                            }.frame(width: 76, height: 48)
                        }.buttonStyle(PhoneKeyStyle(palette: theme.palette(for: scheme)))
                            .accessibilityLabel("\(actionLabel) \(digit)")
                    }
                }
            }
        }.frame(maxWidth: .infinity)
    }
}
private struct PhoneKeyStyle: ButtonStyle {
    let palette: ThemePalette
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(configuration.isPressed ? palette.selection : palette.canvas, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}
