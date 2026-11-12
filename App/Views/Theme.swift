import AppKit
import SwiftUI

/// The app's own colours: a quiet, dense look in both appearances.
enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let window = dynamic(light: 0xFBFBFC, dark: 0x0D0D0F)
    static let sidebar = dynamic(light: 0xF4F4F6, dark: 0x101012)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x141417)
    static let inset = dynamic(light: 0xF4F4F6, dark: 0x0F0F12)
    static let hover = dynamic(light: 0xECECEF, dark: 0x1A1A1E)
    static let selected = dynamic(light: 0xE4E4E9, dark: 0x202026)
    static let border = dynamic(light: 0xE2E2E7, dark: 0x25252B)
    static let text = dynamic(light: 0x1B1B1F, dark: 0xECECEF)
    static let secondary = dynamic(light: 0x6B6B76, dark: 0x8E8E99)
    static let tertiary = dynamic(light: 0x9A9AA5, dark: 0x5C5C66)

    /// The green of the GitNest logo.
    static let brand = dynamic(light: 0x17A862, dark: 0x34E08A)
    static let green = dynamic(light: 0x1F9D55, dark: 0x3FB97A)
    static let red = dynamic(light: 0xD1383D, dark: 0xE5534B)
    static let yellow = dynamic(light: 0xB7791F, dark: 0xD9A53F)
    static let orange = dynamic(light: 0xC2621B, dark: 0xE08A4A)
    static let purple = dynamic(light: 0x7C4DDB, dark: 0xA78BFA)
    static let blue = dynamic(light: 0x2F6FDE, dark: 0x6EA8FE)
    static let teal = dynamic(light: 0x0E7C86, dark: 0x5CC8D4)

    static let radius: CGFloat = 8
}

/// How things move: short, and only to show where something comes from or
/// went. Nothing moves when the system asks for reduced motion.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// A selection sliding to its new place, a press.
    static var snap: Animation? { reduced ? nil : .snappy(duration: 0.2, extraBounce: 0.04) }
    /// Content settling in after a switch.
    static var settle: Animation? { reduced ? nil : .easeOut(duration: 0.18) }
    /// A panel sliding in from an edge.
    static var panel: Animation? { reduced ? nil : .spring(duration: 0.34, bounce: 0.12) }
    static var hover: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
}

/// New content rises a few points into place: the eye sees that it changed.
private struct SettleIn: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0.35)
            .offset(y: shown ? 0 : 5)
            .onAppear {
                if Motion.reduced { shown = true } else { withAnimation(Motion.settle) { shown = true } }
            }
    }
}

/// The pointing hand over something that opens on a click.
private struct LinkCursor: ViewModifier {
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                guard hovering != inside else { return }
                inside = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear { if inside { NSCursor.pop(); inside = false } }
    }
}

/// Greys out a control that changes things on a server whose token is
/// read-only, and says why.
private struct NeedsWrite: ViewModifier {
    @Environment(AppModel.self) private var model
    let host: String?

    func body(content: Content) -> some View {
        // The control keeps its own tooltip while it works.
        if model.mayWrite(host ?? model.workspace?.host) {
            content
        } else {
            content.disabled(true).opacity(0.5).help(AppModel.readOnlyNote)
        }
    }
}

extension View {
    /// For buttons that write to the forge.
    func needsWrite(host: String? = nil) -> some View { modifier(NeedsWrite(host: host)) }
    func settleIn() -> some View { modifier(SettleIn()) }
    func linkCursor() -> some View { modifier(LinkCursor()) }
}

extension CheckState {
    var color: Color {
        switch self {
        case .success: Theme.green
        case .failure: Theme.red
        case .running: Theme.yellow
        case .waiting: Theme.orange
        case .cancelled, .skipped, .unknown: Theme.tertiary
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle"
        case .failure: "xmark.circle"
        case .running: "circle.dotted.circle"
        case .waiting: "clock"
        case .cancelled: "slash.circle"
        case .skipped: "arrow.right.circle"
        case .unknown: "circle.dashed"
        }
    }

    var label: String {
        switch self {
        case .success: "success"
        case .failure: "failed"
        case .running: "running"
        case .waiting: "waiting"
        case .cancelled: "cancelled"
        case .skipped: "skipped"
        case .unknown: "unknown"
        }
    }
}

/// A turning arc: something is running right now. Core Animation turns
/// it in the render server, so a screen full of running pipelines costs the
/// app no CPU (a SwiftUI repeat-forever animation redraws every frame).
struct Spinner: View {
    var color: Color = Theme.yellow
    var size: CGFloat = 12

    var body: some View {
        SpinnerLayer(color: NSColor(color), lineWidth: max(1.4, size / 8))
            .frame(width: size, height: size)
    }
}

private struct SpinnerLayer: NSViewRepresentable {
    let color: NSColor
    let lineWidth: CGFloat

    final class SpinnerView: NSView {
        let arc = CAShapeLayer()
        var color: NSColor = .systemYellow { didSet { updateColor() } }
        var lineWidth: CGFloat = 1.5 { didSet { arc.lineWidth = lineWidth } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeStart = 0.12
            arc.strokeEnd = 0.82
            layer?.addSublayer(arc)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layout() {
            super.layout()
            let inset = lineWidth / 2
            arc.frame = bounds
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            if arc.animation(forKey: "turn") == nil { startTurning() }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { startTurning() }
        }

        private func updateColor() {
            effectiveAppearance.performAsCurrentDrawingAppearance { arc.strokeColor = color.cgColor }
        }

        private func startTurning() {
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = 0.9
            turn.repeatCount = .infinity
            turn.isRemovedOnCompletion = false
            arc.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            arc.position = CGPoint(x: bounds.midX, y: bounds.midY)
            arc.bounds = bounds
            arc.add(turn, forKey: "turn")
        }
    }

    func makeNSView(context: Context) -> SpinnerView {
        let view = SpinnerView(frame: .zero)
        view.color = color
        view.lineWidth = lineWidth
        return view
    }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.color = color
        view.lineWidth = lineWidth
    }
}

struct CheckIcon: View {
    let state: CheckState
    var size: CGFloat = 13

    var body: some View {
        Group {
            if state == .running {
                Spinner(color: state.color, size: size - 1)
            } else {
                Image(systemName: state.symbol)
                    .font(.system(size: size))
                    .foregroundStyle(state.color)
            }
        }
        .frame(width: size + 3, height: size + 3)
        .help(state.label.capitalized)
        .accessibilityLabel(state.label)
    }
}

/// The GitNest mark with the product's name.
struct Wordmark: View {
    var size: CGFloat = 14

    var body: some View {
        HStack(spacing: size * 0.4) {
            Image("Logo").resizable().scaledToFit().frame(width: size * 1.45, height: size * 1.45)
            (Text("Git").foregroundStyle(Theme.text) + Text("Nest").foregroundStyle(Theme.brand)
                + Text(" View").foregroundStyle(Theme.secondary).fontWeight(.regular))
                .font(.system(size: size, weight: .bold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("GitNest View")
    }
}

extension Color {
    /// "#fbca04" or "fbca04", as forges store label colours.
    init?(hex: String?) {
        guard let hex else { return nil }
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// The dot next to a repository: its latest pipeline.
struct StatusDot: View {
    let state: CheckState?

    var body: some View {
        if state == .running {
            // A pipeline is running right now: the dot turns.
            Spinner(color: Theme.yellow, size: 9)
                .frame(width: 9, height: 9)
                .help("Latest pipeline: running")
        } else {
            dot
        }
    }

    private var dot: some View {
        Circle()
            .fill(state?.color ?? Theme.tertiary.opacity(0.6))
            .frame(width: 7, height: 7)
            .help(state.map { "Latest pipeline: \($0.label)" } ?? "No pipeline yet")
            .accessibilityLabel(state.map { "Latest pipeline \($0.label)" } ?? "No pipeline yet")
    }
}

struct Badge: View {
    let text: String
    var color: Color = Theme.secondary
    var filled = true

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .foregroundStyle(color)
            .background(filled ? color.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(color.opacity(0.45)))
    }
}

/// A titled box, like the cards of a pull request page.
struct Card<Content: View, Trailing: View>: View {
    let title: String
    /// Drawn after the title: the state of what the card is about.
    var state: CheckState?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    init(_ title: String, state: CheckState? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.state = state
        self.trailing = trailing()
        self.content = content()
    }

    /// Drawn before the title: whose card this is (a logo).
    var leading: AnyView?

    func leading(_ view: some View) -> Card {
        var copy = self
        copy.leading = AnyView(view)
        return copy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let leading { leading }
                Text(title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text)
                if let state { CheckIcon(state: state, size: 12) }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            Rectangle().fill(Theme.border).frame(height: 1)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
    }
}

/// The centred message of an empty pane: an icon in a box, a title, a hint.
struct EmptyState<Actions: View>: View {
    let symbol: String
    let title: String
    var message: String = ""
    @ViewBuilder var actions: Actions

    init(_ title: String, symbol: String, message: String = "", @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(Theme.secondary)
                .frame(width: 40, height: 40)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.text)
            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            actions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A small bordered button, as in the pane headers.
struct ChipButtonStyle: ButtonStyle {
    var prominent = false
    /// The colour of a prominent button; blue unless the action is special (merging is green).
    var tint: Color = Theme.blue
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .foregroundStyle(prominent ? Color.white : Theme.text)
            .background(prominent ? tint : (configuration.isPressed ? Theme.selected : Theme.card), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(prominent ? .clear : Theme.border))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(Motion.hover, value: configuration.isPressed)
    }
}

/// Which server something is on: GitNest shows several at once, and a
/// pull request without its server is half a fact.
@MainActor
enum ServerName {
    /// "forgejo.int.example.com" → "example": the part people call it by.
    static func short(_ host: String) -> String {
        let name = domain(host)
        // Two servers of one domain would get the same name: tell them
        // apart by their first label instead ("forgejo", "forgejo16").
        if known.filter({ domain($0) == name }).count > 1, let first = host.split(separator: ".").first { return String(first) }
        return name
    }

    private static func domain(_ host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        return labels.count >= 2 ? labels[labels.count - 2] : host
    }

    /// The servers connected now, kept by the model.
    @MainActor static var known: [String] = []

    /// The same colour for the same server, everywhere.
    static func color(_ host: String) -> Color {
        let palette = [Theme.blue, Theme.purple, Theme.teal, Theme.orange, Theme.yellow, Theme.green]
        let sum = host.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[sum % palette.count]
    }
}

struct ServerChip: View {
    let host: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(ServerName.color(host)).frame(width: 6, height: 6)
            Text(ServerName.short(host)).font(.system(size: 10.5, weight: .medium))
        }
        .foregroundStyle(Theme.secondary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(ServerName.color(host).opacity(0.12), in: Capsule())
        .help("On \(host)")
        .accessibilityLabel("Server \(host)")
    }
}

/// Jira's mark, drawn: two folded blue squares.
struct JiraMark: View {
    var size: CGFloat = 14
    private static let blue = Color(.sRGB, red: 0.13, green: 0.42, blue: 0.95)

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.16).fill(Self.blue.opacity(0.55))
                .frame(width: size * 0.62, height: size * 0.62).rotationEffect(.degrees(45)).offset(y: size * 0.16)
            RoundedRectangle(cornerRadius: size * 0.16).fill(Self.blue)
                .frame(width: size * 0.62, height: size * 0.62).rotationEffect(.degrees(45)).offset(y: -size * 0.12)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Jira")
    }
}

/// Open / Closed / All, and similar small choices.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, label in
                Button(label) { selection = value }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .foregroundStyle(selection == value ? Theme.text : Theme.secondary)
                    .background {
                        // One pill that slides between the choices.
                        if selection == value {
                            RoundedRectangle(cornerRadius: 5).fill(Theme.selected).matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
            }
        }
        .animation(Motion.snap, value: selection)
        .padding(2)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
    }
}

struct HLine: View {
    var body: some View { Rectangle().fill(Theme.border).frame(height: 1) }
}

struct VLine: View {
    var body: some View { Rectangle().fill(Theme.border).frame(width: 1) }
}

extension PullRequest.Phase {
    var label: String {
        switch self {
        case .open: "Open"
        case .draft: "Draft"
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    var color: Color {
        switch self {
        case .open: Theme.green
        case .draft: Theme.secondary
        case .merged: Theme.purple
        case .closed: Theme.red
        }
    }
}

extension Date {
    /// "3 minutes ago"; "just now" for the last few seconds.
    var relative: String {
        abs(timeIntervalSinceNow) < 45 ? "just now" : formatted(.relative(presentation: .named))
    }
}

extension View {
    /// Highlights a row under the pointer.
    func hoverBackground(selected: Bool = false, radius: CGFloat = 6) -> some View {
        modifier(HoverBackground(selected: selected, radius: radius))
    }
}

private struct HoverBackground: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Theme.selected : (hovering ? Theme.hover : .clear), in: RoundedRectangle(cornerRadius: radius))
            .animation(Motion.hover, value: selected)
            .onHover { hovering = $0 }
    }
}

/// A column whose right edge can be dragged; its width is remembered.
/// A double click on the edge brings the width back to where it started.
struct ResizableColumn<Content: View>: View {
    @Environment(AppModel.self) private var model
    let key: String
    let initial: CGFloat
    let range: ClosedRange<CGFloat>
    @ViewBuilder var content: Content
    @State private var width: CGFloat?
    @State private var start: CGFloat?
    @State private var hovering = false

    var body: some View {
        let current = width ?? initial
        HStack(spacing: 0) {
            content.frame(width: current)
            Rectangle()
                .fill(hovering || start != nil ? Theme.blue.opacity(0.6) : Theme.border)
                .frame(width: hovering || start != nil ? 2 : 1)
                .padding(.horizontal, 3)
                .contentShape(Rectangle())
                .padding(.horizontal, -3)
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            if start == nil { start = current }
                            width = min(range.upperBound, max(range.lowerBound, (start ?? current) + drag.translation.width))
                        }
                        .onEnded { _ in
                            start = nil
                            if let width { model.defaults.set(Double(width), forKey: "width." + key) }
                        }
                )
                .onTapGesture(count: 2) {
                    width = initial
                    model.defaults.removeObject(forKey: "width." + key)
                }
                .help("Drag to resize; double-click for the usual width")
                .accessibilityLabel("Resize")
        }
        .onAppear {
            if width == nil, let saved = model.defaults.object(forKey: "width." + key) as? Double {
                width = min(range.upperBound, max(range.lowerBound, CGFloat(saved)))
            }
        }
    }
}
