import SwiftUI
import EnsembleCore

/// The connected screens drawn where macOS has them, as System Settings > Displays does: each one at its real
/// position and relative size, with its name, size in points and calibration. The main screen carries a menu bar
/// strip. Clicking a screen recalibrates only that screen. Shown in the menu panel and at the top of Settings,
/// Calibration; it follows `state.screenChoices`, which is rebuilt whenever the arrangement changes.
struct ScreenArrangementView: View {
    let screens: [ScreenChoice]
    /// The saved position in use: each screen shows the date that position calibrated it.
    let spotInUse: String?
    let calibrating: Bool
    let width: CGFloat
    let maxHeight: CGFloat
    let recalibrate: (String) -> Void
    @State private var hovered: String?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d")
        return f
    }()

    var body: some View {
        let layout = ScreenLayout.fit(screens.map(\.frame), width: width, maxHeight: maxHeight)
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(screens, layout.rects)), id: \.0.id) { screen, rect in
                tile(screen, size: rect.insetBy(dx: 2, dy: 2).size)
                    .offset(x: rect.minX + 2, y: rect.minY + 2)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: screens)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screen arrangement")
    }

    /// "Calibrated Oct 15" (the date the position in use calibrated it) or "Not calibrated".
    static func calibrationLabel(_ screen: ScreenChoice, spotInUse: String?) -> String {
        let date = (spotInUse.flatMap { screen.calibratedAt[$0] } ?? screen.calibratedAt.values.max())
            .map { dateFormatter.string(from: $0) }
        return ScreenLayout.calibrationState(valid: screen.calibrated, calibratedOn: date)
    }

    private func tile(_ screen: ScreenChoice, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let isHovered = hovered == screen.id && !calibrating
        let roomy = size.height >= 54 && size.width >= 70
        let status = Self.calibrationLabel(screen, spotInUse: spotInUse)
        return Button { recalibrate(screen.id) } label: {
            ZStack(alignment: .top) {
                shape.fill(Color.primary.opacity(isHovered ? 0.12 : 0.07))
                if screen.isMain {
                    // The menu bar strip System Settings draws on the main screen.
                    Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 3)
                }
                VStack(spacing: 1) {
                    Text(screen.displayName).font(.caption.weight(.semibold))
                    if roomy {
                        Text(ScreenLayout.size(of: screen.frame) + (screen.isMain ? ", main" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Label(status, systemImage: screen.calibrated ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(screen.calibrated ? Color.secondary : Color.orange)
                        .labelStyle(.titleAndIcon)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .clipShape(shape)
            // The owner's highlight rule: a blue outline only, never filled.
            .overlay(shape.strokeBorder(isHovered ? Color.blue : Color.primary.opacity(0.22), lineWidth: isHovered ? 2 : 1))
            .frame(width: size.width, height: size.height)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(calibrating)
        .onHover { inside in
            withAnimation(.smooth(duration: 0.25)) { hovered = inside ? screen.id : (hovered == screen.id ? nil : hovered) }
        }
        .help("\(screen.displayName), \(ScreenLayout.size(of: screen.frame))\(screen.isMain ? ", main screen" : ""). \(status). Click to recalibrate only this screen.")
        .accessibilityLabel("\(screen.displayName), \(status)")
        .accessibilityHint("Recalibrates only this screen")
    }
}
