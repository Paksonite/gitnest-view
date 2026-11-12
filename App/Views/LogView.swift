import AppKit
import SwiftUI

/// A job's log: its steps as sections that open and close, coloured text,
/// followed live while the job runs. "Summary" hides what the runner says
/// about itself and shortens Terraform resource blocks to one line each.
struct LogPane: View {
    @Environment(AppModel.self) private var model
    let target: LogTarget
    /// Shows a close button when the pane is a window of its own.
    var onClose: (() -> Void)?
    @State private var follower = LogFollower()
    @State private var full = false
    @State private var follow = true
    /// Steps the reader opened or closed by hand; the rest follow `opensByItself`.
    @State private var chosen: [Int: Bool] = [:]

    var body: some View {
        VStack(spacing: 0) {
            header
            HLine()
            if !follower.loaded {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if follower.lines.isEmpty, follower.steps.isEmpty {
                EmptyState(
                    follower.live ? "Waiting for output…" : "This job has no log",
                    symbol: "text.alignleft",
                    message: follower.state == .waiting ? "No runner has picked this job up yet."
                        : follower.live ? "" : "Jobs that only call another workflow print nothing themselves; the log is in the jobs they start."
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            if follower.steps.isEmpty {
                                LogText(lines: shown(follower.whole)).padding(.vertical, 6)
                            } else {
                                ForEach(follower.steps) { step in
                                    StepSection(
                                        log: step, lines: shown(step.lines),
                                        open: chosen[step.id] ?? opensByItself(step),
                                        toggle: { chosen[step.id] = !(chosen[step.id] ?? opensByItself(step)) }
                                    )
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                    }
                    .onChange(of: follower.lines.count) {
                        if follow, follower.live { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
        }
        .task(id: target) {
            guard let client = model.client(for: target.repo.host) else { return }
            chosen = [:]
            follower.follow(target, client: client)
        }
        .onDisappear { follower.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            CheckIcon(state: follower.state)
            Text(target.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if follower.live { Badge(text: "Live", color: Theme.green) }
            Spacer()
            if let error = follower.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.red).lineLimit(1)
            }
            if follower.live {
                Button {
                    follow.toggle()
                } label: {
                    Label("Follow", systemImage: follow ? "arrow.down.to.line" : "pause")
                }
                .buttonStyle(ChipButtonStyle())
                .help(follow ? "Following the end of the log; click to stop" : "Click to follow the end of the log")
            }
            Segments(options: [(false, "Summary"), (true, "Full log")], selection: $full)
                .help("Summary hides the runner's own lines and shows one line per Terraform resource")
            if let web = target.webURL, let url = URL(string: web) {
                Button("Open in Browser", systemImage: "arrow.up.right.square") { openExternal(url) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .help("Open on the server")
            }
            if let onClose {
                Button("Close", systemImage: "xmark", action: onClose)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close (Esc)")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    private func shown(_ lines: [LogLine]) -> [LogLine] {
        full ? lines : TerraformLog.condense(lines.filter { !$0.isRunnerNoise })
    }

    /// A step shows its log without being asked when it is running, when it
    /// failed, or when it holds what the job is about: Terraform's result,
    /// or else the last step that did real work.
    private func opensByItself(_ log: StepLog) -> Bool {
        switch log.step.state {
        case .running, .failure: return true
        case .waiting, .unknown, .skipped, .cancelled: return false
        case .success: break
        }
        guard !follower.live else { return false }
        let steps = follower.steps
        if steps.contains(where: { $0.step.state == .failure }) { return false }
        let withTerraform = steps.filter { TerraformPlan.parse($0.lines) != nil }
        if !withTerraform.isEmpty { return withTerraform.last?.id == log.id }
        let work = steps.filter { !["Set up job", "Complete job"].contains($0.step.name) && !$0.lines.isEmpty }
        return work.last?.id == log.id
    }
}

/// One step: a header that opens and closes its log.
private struct StepSection: View {
    let log: StepLog
    let lines: [LogLine]
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 10)
                    CheckIcon(state: log.step.state, size: 12)
                    Text(log.step.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(log.step.state == .waiting ? Theme.secondary : Theme.text)
                        .lineLimit(1)
                    Spacer()
                    if !lines.isEmpty {
                        Text("\(lines.count) lines").font(.system(size: 11)).foregroundStyle(Theme.tertiary).monospacedDigit()
                    }
                    if let duration = log.step.duration {
                        Text(duration).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverBackground(radius: 0)
            if open {
                if lines.isEmpty {
                    Text(log.step.state.isFinished ? "No output." : "Waiting for output…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 40)
                        .padding(.vertical, 8)
                        .background(Theme.inset)
                } else {
                    LogText(lines: lines)
                        .padding(.leading, 26)
                        .padding(.vertical, 6)
                        .background(Theme.inset)
                }
            }
            HLine()
        }
        .animation(.snappy(duration: 0.18), value: open)
    }
}

/// The log as a window over the app: it grows out of the middle, and a click
/// outside it, or Esc, closes it.
struct LogModalLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        GeometryReader { window in
            if let target = model.logTarget {
                ZStack {
                    Color.black.opacity(0.5)
                        .onTapGesture { close() }
                        .transition(.opacity)
                    LogPane(target: target, onClose: close)
                        .id(target)
                        .frame(width: min(1180, window.size.width - 120), height: min(800, window.size.height - 100))
                        .background(Theme.window, in: RoundedRectangle(cornerRadius: 12))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
                        .shadow(color: .black.opacity(0.5), radius: 40, y: 18)
                        .transition(.scale(scale: 0.92).combined(with: .opacity).combined(with: .offset(y: 14)))
                }
            }
        }
        .animation(.spring(duration: 0.32, bounce: 0.18), value: model.logTarget)
    }

    private func close() {
        model.logTarget = nil
    }
}

/// Coloured log text that is as tall as its content, for use inside a
/// scrolling page. AppKit's text view stays fast with thousands of lines
/// and gives selection and copying across lines.
struct LogText: View {
    let lines: [LogLine]
    @State private var height: CGFloat = 18

    var body: some View {
        LogTextBody(lines: lines, height: $height)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}

/// A text view that reports how tall its text is at the width it was given.
final class MeasuringTextView: NSTextView {
    var onHeight: ((CGFloat) -> Void)?
    private var reported: CGFloat = -1

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        measure()
    }

    func measure() {
        guard let container = textContainer, let layout = layoutManager, frame.width > 1 else { return }
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height + textContainerInset.height * 2)
        guard abs(height - reported) > 0.5 else { return }
        reported = height
        // Not during layout: SwiftUI state may not change in the middle of it.
        DispatchQueue.main.async { [weak self] in self?.onHeight?(height) }
    }
}

private struct LogTextBody: NSViewRepresentable {
    let lines: [LogLine]
    @Binding var height: CGFloat

    final class Coordinator {
        var shown: [LogLine] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MeasuringTextView {
        // TextKit 1: its layout can be measured synchronously.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let text = MeasuringTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 2)
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        return text
    }

    func updateNSView(_ text: MeasuringTextView, context: Context) {
        text.onHeight = { new in
            if abs(height - new) > 0.5 { height = new }
        }
        let coordinator = context.coordinator
        guard coordinator.shown != lines, let storage = text.textStorage else { return }
        if lines.count > coordinator.shown.count, Array(lines.prefix(coordinator.shown.count)) == coordinator.shown {
            // The log grew: add only the new lines.
            storage.append(LogRenderer.attributed(Array(lines[coordinator.shown.count...])))
        } else {
            storage.setAttributedString(LogRenderer.attributed(lines))
        }
        coordinator.shown = lines
        text.measure()
    }
}

/// Turns log lines into coloured text: what the program coloured itself, and
/// otherwise what the line means (an error, a step, a Terraform change).
@MainActor
enum LogRenderer {
    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)

    private static let green = NSColor(Theme.green)
    private static let red = NSColor(Theme.red)
    private static let yellow = NSColor(Theme.yellow)
    private static let orange = NSColor(Theme.orange)
    private static let blue = NSColor(Theme.blue)
    private static let purple = NSColor(Theme.purple)
    private static let plain = NSColor(Theme.text)
    private static let dim = NSColor(Theme.secondary)
    private static let faint = NSColor(Theme.tertiary)

    private static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2.5
        // Wrapped lines continue under the text, not under the time.
        style.headIndent = 74
        return style
    }()

    static func attributed(_ lines: [LogLine]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for line in lines { append(line, to: out) }
        return out
    }

    private static func color(_ action: TerraformPlan.Action) -> NSColor {
        switch action {
        case .create: green
        case .update: yellow
        case .destroy: red
        case .replace: orange
        case .read: blue
        }
    }

    private static func color(_ ansi: LogStyle.Color) -> NSColor {
        switch ansi {
        case .black: faint
        case .red: red
        case .green: green
        case .yellow: yellow
        case .blue: blue
        case .magenta: purple
        case .cyan: NSColor.systemTeal
        case .white: plain
        }
    }

    /// The colour and weight of a whole line, from what it says.
    static func tone(_ line: LogLine) -> (color: NSColor, bold: Bool) {
        let text = line.text.trimmingCharacters(in: .whitespaces)
        if line.isRunnerNoise { return (faint, false) }
        if text.hasPrefix("❌") || text.hasPrefix("::error") || text.hasPrefix("Error:") || text.hasPrefix("│ Error:")
            || text.hasPrefix("error:") || text.hasPrefix("ERRO") || text.hasPrefix("FATAL") || text.contains("exitcode '1'") {
            return (red, true)
        }
        if text.hasPrefix("Warning:") || text.hasPrefix("│ Warning:") || text.hasPrefix("::warning") || text.hasPrefix("WARN") {
            return (yellow, true)
        }
        if text.hasPrefix("⭐") { return (plain, true) }
        if text.hasPrefix("✅") || text.hasPrefix("🏁") || text.hasPrefix("Apply complete!") || text.hasPrefix("No changes.")
            || text.contains("has been successfully initialized") {
            return (green, true)
        }
        if text.hasPrefix("Plan:") || text.hasPrefix("Changes to Outputs:") { return (plain, true) }
        if text.hasPrefix("# "), let change = TerraformPlan.change(text) { return (color(change.action), true) }
        if text.hasPrefix("-/+ ") || text.hasPrefix("+/- ") { return (orange, false) }
        if text.hasPrefix("+ ") { return (green, false) }
        if text.hasPrefix("- ") { return (red, false) }
        if text.hasPrefix("~ ") { return (yellow, false) }
        if text.hasPrefix("<= ") { return (blue, false) }
        if text.hasPrefix("│") || text.hasPrefix("╷") || text.hasPrefix("╵") { return (dim, false) }
        if text.hasPrefix("Initializing ") || text.hasPrefix("Refreshing state") || text.contains(": Refreshing state...")
            || text.contains(": Reading...") || text.contains(": Read complete") {
            return (dim, false)
        }
        if text.contains(": Creating...") || text.contains(": Creation complete") { return (green, false) }
        if text.contains(": Destroying...") || text.contains(": Destruction complete") { return (red, false) }
        if text.contains(": Modifying...") || text.contains(": Modifications complete") { return (yellow, false) }
        return (plain, false)
    }

    private static func append(_ line: LogLine, to out: NSMutableAttributedString) {
        let time = (line.time ?? "        ") + "  "
        out.append(NSAttributedString(string: time, attributes: [.font: font, .foregroundColor: faint, .paragraphStyle: paragraph]))

        if let action = line.action, let gap = line.text.range(of: "  ") {
            // "+ create" in the action's colour, the address plain.
            out.append(NSAttributedString(string: String(line.text[..<gap.upperBound]),
                                          attributes: [.font: bold, .foregroundColor: color(action), .paragraphStyle: paragraph]))
            out.append(NSAttributedString(string: String(line.text[gap.upperBound...]) + "\n",
                                          attributes: [.font: font, .foregroundColor: plain, .paragraphStyle: paragraph]))
            return
        }

        let tone = tone(line)
        let body = NSMutableAttributedString(string: line.text, attributes: [
            .font: tone.bold ? bold : font, .foregroundColor: tone.color, .paragraphStyle: paragraph,
        ])
        // What the program coloured itself wins over the guess above.
        let length = body.length
        for style in line.styles where style.start < length {
            let range = NSRange(location: style.start, length: min(style.length, length - style.start))
            if let ansi = style.color { body.addAttribute(.foregroundColor, value: color(ansi), range: range) }
            if style.bold { body.addAttribute(.font, value: bold, range: range) }
        }
        out.append(body)
        out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: paragraph]))
    }
}
