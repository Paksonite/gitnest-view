import AppKit
import SwiftUI

/// A file of a clone to read in the app: Terraform coloured, with line
/// numbers, at a line when one is given.
struct FileTarget: Hashable, Sendable {
    var repo: ForgeRepo
    var file: String
    /// 1-based; the block that starts there is marked.
    var line: Int?
}

/// A list with the file pane beside it: the pane slides in from the right
/// when a file is chosen and takes its place in the layout (nothing is
/// covered); Escape or its close button sends it away.
struct WithFilePane<Content: View>: View {
    @Environment(AppModel.self) private var model
    /// The pane shows only files of this repository; nil shows any.
    var repo: ForgeRepo? = nil
    @ViewBuilder var content: Content

    private var target: FileTarget? {
        guard let target = model.fileTarget, repo == nil || target.repo.id == repo?.id else { return nil }
        return target
    }

    var body: some View {
        GeometryReader { space in
            HStack(spacing: 0) {
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let target {
                    VLine()
                    FilePane(target: target)
                        .frame(width: max(380, min(space.size.width - 470, space.size.width * 0.5)))
                        .transition(.move(edge: .trailing))
                }
            }
            .clipped()
            .animation(Motion.panel, value: target != nil)
        }
        .onDisappear { model.fileTarget = nil }
    }
}

/// One file of a clone: its path, what can be done with it, and the text.
struct FilePane: View {
    @Environment(AppModel.self) private var model
    let target: FileTarget
    @State private var text: String?
    @State private var problem: String?
    /// Where the text is scrolled to and what is marked.
    @State private var focus: CodeFocus?

    var body: some View {
        let clone = model.clone(of: target.repo)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text").foregroundStyle(Theme.secondary)
                Text(target.file).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    .textSelection(.enabled)
                if let branch = clone?.branch {
                    Text(branch).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        .help("The file as it is in the clone, on \(branch)")
                }
                Spacer(minLength: 8)
                Button("Copy Path", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(target.file, forType: .string)
                    model.toast("Copied \(target.file)")
                }
                .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Copy the path")
                Button("Edit", systemImage: "arrow.up.forward.square") {
                    if let clone { openInEditor(clone, target.file, line: focus?.line ?? target.line) }
                }
                .buttonStyle(ChipButtonStyle())
                .help("Open this file in the editor to change it")
                Button("Close File", systemImage: "sidebar.right") { model.fileTarget = nil }
                    .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(Theme.secondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
                    .keyboardShortcut(.cancelAction)
                    .help("Close the file (Esc)")
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 40)
            HLine()
            Group {
                if let problem {
                    EmptyState("Cannot show this file", symbol: "doc.questionmark", message: problem)
                } else if let text {
                    CodeText(text: text, language: Syntax.language(of: target.file), focus: focus) { model.fileTarget = nil }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.window)
        .task(id: target) { await load() }
        .onExitCommand { model.fileTarget = nil }
    }

    private func load() async {
        problem = nil
        guard let clone = model.clone(of: target.repo) else {
            text = nil
            problem = "\(target.repo.name) is not cloned: files are read from the clone."
            return
        }
        let path = URL(fileURLWithPath: clone.path).appending(path: target.file).path
        switch await Task.detached(operation: { FileReader.read(path) }).value {
        case .success(let content):
            text = content
            focus = target.line.map { CodeFocus(line: $0, end: Syntax.blockEnd(content, line: $0, language: Syntax.language(of: target.file))) }
        case .failure(let failure):
            text = nil
            problem = failure.message
        }
    }
}

/// Reading a clone's files for the viewer.
enum FileReader {
    struct Failure: Error { var message: String }

    static func read(_ path: String) -> Result<String, Failure> {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return .failure(Failure(message: "The file is not in the clone on this branch."))
        }
        if let size = attributes[.size] as? Int, size > 3_000_000 {
            return .failure(Failure(message: "The file is larger than 3 MB: open it in the editor."))
        }
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            return .failure(Failure(message: "The file is not text."))
        }
        return .success(text)
    }

    private static let skipped: Set<String> = [".git", ".terraform", ".terragrunt-cache", "node_modules", ".idea", ".vscode"]
    private static let shown: Set<String> = ["tf", "hcl", "tfvars", "tofu", "yaml", "yml", "json", "md", "txt", "sh", "tpl", "tftpl", "toml", "cfg", "ini", "py"]

    /// The clone's readable files, Terraform first, at most 3000.
    static func list(_ root: String) -> [String] {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return [] }
        var found: [String] = []
        let prefix = base.standardizedFileURL.path + "/"
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard shown.contains(url.pathExtension.lowercased()) || name == "Makefile" || name == "CODEOWNERS" else { continue }
            let path = url.standardizedFileURL.path
            found.append(path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path)
            if found.count >= 3000 { break }
        }
        func rank(_ file: String) -> Int { Syntax.language(of: file) == .hcl ? 0 : 1 }
        return found.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// Opens a clone's file in the editor, at a line when the editor can.
@MainActor
func openInEditor(_ clone: Repo, _ file: String, line: Int?) {
    let path = URL(fileURLWithPath: clone.path).appending(path: file).path
    if let line, NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") != nil,
       let url = URL(string: "vscode://file\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path):\(line)") {
        openExternal(url)
    } else {
        openFile(clone, file)
    }
}

// MARK: - The text

struct CodeFocus: Equatable {
    var line: Int
    var end: Int
}

/// Source text with colours and line numbers; selectable, searchable (⌘F).
struct CodeText: NSViewRepresentable {
    let text: String
    let language: Syntax.Language
    let focus: CodeFocus?
    /// Escape pressed in the text.
    var onEscape: (() -> Void)? = nil

    final class Coordinator {
        var text: String?
        var focus: CodeFocus?
        var observer: NSObjectProtocol?
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CodeTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.drawsBackground = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.textContainerInset = NSSize(width: 8, height: 10)
        // Long lines scroll sideways: wrapped Terraform is hard to read.
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.layoutManager?.allowsNonContiguousLayout = true

        let ruler = LineRuler(scrollView: scroll, orientation: .verticalRuler)
        ruler.textView = view
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak ruler] _ in
            MainActor.assumeIsolated { ruler?.needsDisplay = true }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let ruler = scroll.verticalRulerView as? LineRuler else { return }
        (view as? CodeTextView)?.onEscape = onEscape
        let coordinator = context.coordinator
        if coordinator.text != text {
            coordinator.text = text
            coordinator.focus = nil
            view.textStorage?.setAttributedString(Self.render(text, language: language))
            ruler.lineStarts = Syntax.lineStarts(text)
            ruler.ruleThickness = CGFloat(max(3, String(ruler.lineStarts.count).count)) * 7.5 + 18
            view.scroll(.zero)
        }
        guard coordinator.focus != focus else { return }
        let old = coordinator.focus
        coordinator.focus = focus
        ruler.marked = focus.map { $0.line...max($0.line, $0.end) }
        ruler.needsDisplay = true
        guard let storage = view.textStorage else { return }
        let starts = ruler.lineStarts
        func range(_ focus: CodeFocus) -> NSRange? {
            guard focus.line >= 1, focus.line <= starts.count else { return nil }
            let from = starts[focus.line - 1]
            let to = focus.end < starts.count ? starts[focus.end] : storage.length
            return NSRange(location: from, length: max(0, min(storage.length, to) - from))
        }
        if let old, let was = range(old) { storage.removeAttribute(.backgroundColor, range: was) }
        guard let focus, let marked = range(focus) else { return }
        storage.addAttribute(.backgroundColor, value: NSColor(Theme.blue).withAlphaComponent(0.09), range: marked)
        // Two lines of what comes before stay visible above the block. After
        // this update: the view has no size yet when the file has just been set.
        let first = starts[max(0, focus.line - 3)]
        let last = NSMaxRange(marked)
        DispatchQueue.main.async { [weak scroll, weak view] in
            guard let scroll, let view, let layout = view.layoutManager, let length = view.textStorage?.length, length > 0 else { return }
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(length, last)))
            let glyph = layout.glyphIndexForCharacter(at: min(first, length - 1))
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let limit = max(0, view.frame.height - scroll.contentView.bounds.height)
            let y = min(max(0, rect.minY), limit)
            NSAnimationContext.runAnimationGroup { animation in
                animation.duration = Motion.reduced ? 0 : 0.22
                scroll.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: y))
            }
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    @MainActor
    static func render(_ text: String, language: Syntax.Language) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        let out = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(Theme.text), .paragraphStyle: paragraph])
        let length = out.length
        for token in Syntax.tokens(text, language: language) where NSMaxRange(token.range) <= length {
            out.addAttribute(.foregroundColor, value: color(token.kind), range: token.range)
            if token.kind == .keyword {
                out.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), range: token.range)
            }
        }
        return out
    }

    @MainActor
    private static func color(_ kind: Syntax.Kind) -> NSColor {
        switch kind {
        case .comment: NSColor(Theme.tertiary)
        case .string: NSColor(Theme.green)
        case .number, .constant: NSColor(Theme.orange)
        case .keyword: NSColor(Theme.purple)
        case .attribute: NSColor(Theme.blue)
        case .function: NSColor(Theme.yellow)
        case .reference: NSColor(Theme.teal)
        case .punctuation: NSColor(Theme.secondary)
        }
    }
}

/// A read-only text view that hands Escape to its owner: NSTextView keeps
/// it for itself (completion), so the panel around it would never close.
final class CodeTextView: NSTextView {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        // The find bar closes first, the way Escape works everywhere.
        if let scroll = enclosingScrollView, scroll.isFindBarVisible {
            let item = NSMenuItem()
            item.tag = NSTextFinder.Action.hideFindInterface.rawValue
            performTextFinderAction(item)
            return
        }
        onEscape?()
    }
}

/// Line numbers beside the text; the marked block gets a bar.
final class LineRuler: NSRulerView {
    weak var textView: NSTextView?
    var lineStarts: [Int] = [0]
    var marked: ClosedRange<Int>?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let view = textView, let layout = view.layoutManager, let container = view.textContainer else { return }
        let length = view.textStorage?.length ?? 0
        let visible = view.visibleRect
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        // The first line that starts at or after the first visible character.
        var low = 0, high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= characters.location { low = middle } else { high = middle - 1 }
        }
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.tertiary)]
        let strong: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(Theme.blue)]
        let inset = view.textContainerInset.height
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let fragment: NSRect
            if start < length {
                fragment = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: start), effectiveRange: nil)
            } else if length > 0, line > 0 {
                // The empty line after the last newline.
                fragment = layout.extraLineFragmentRect
            } else {
                break
            }
            let y = fragment.minY + inset - visible.minY
            let isMarked = marked?.contains(line + 1) ?? false
            if isMarked {
                NSColor(Theme.blue).setFill()
                NSRect(x: bounds.width - 3, y: y, width: 2, height: fragment.height).fill()
            }
            let label = NSAttributedString(string: "\(line + 1)", attributes: isMarked ? strong : plain)
            let size = label.size()
            label.draw(at: NSPoint(x: bounds.width - size.width - 9, y: y + (fragment.height - size.height) / 2 - 1))
            line += 1
        }
    }
}
