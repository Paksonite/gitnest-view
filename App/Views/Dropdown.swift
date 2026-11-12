import Observation
import SwiftUI

/// The app's own drop-down menus: drawn in the window with the app's colours,
/// not the system menu. One can be open at a time; a click anywhere else
/// closes it.
@MainActor @Observable
final class DropdownCenter {
    struct Active {
        var id: String
        var anchor: CGRect
        var width: CGFloat
        var content: AnyView
    }

    private(set) var active: Active?

    func toggle(id: String, anchor: CGRect, width: CGFloat, content: AnyView) {
        if active?.id == id {
            close()
        } else {
            withAnimation(.snappy(duration: 0.16)) {
                active = Active(id: id, anchor: anchor, width: width, content: content)
            }
        }
    }

    func close() {
        withAnimation(.snappy(duration: 0.12)) { active = nil }
    }
}

/// The coordinate space the menus are placed in: the whole window.
let dropdownSpace = "gitnest.window"

/// A button that opens a themed menu below itself.
struct Dropdown<Label: View, Content: View>: View {
    let id: String
    var width: CGFloat = 260
    /// Opens the menu by itself shortly after it appears (development only).
    var autoOpen = false
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content
    @Environment(DropdownCenter.self) private var center
    @State private var frame: CGRect = .zero

    var body: some View {
        Button {
            center.toggle(id: id, anchor: frame, width: width, content: AnyView(content))
        } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            guard autoOpen else { return }
            try? await Task.sleep(for: .seconds(3))
            center.toggle(id: id, anchor: frame, width: width, content: AnyView(content))
        }
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.frame(in: .named(dropdownSpace)), initial: true) { _, new in
                    frame = new
                }
            }
        }
    }
}

/// Draws the open menu over the window; goes on the window's root view.
struct DropdownLayer: View {
    @Environment(DropdownCenter.self) private var center

    var body: some View {
        GeometryReader { window in
            if let active = center.active {
                let width = max(active.width, active.anchor.width)
                let x = min(active.anchor.minX, window.size.width - width - 8)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .onTapGesture { center.close() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) { active.content }
                            .padding(5)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(width: width)
                    .frame(maxHeight: min(440, window.size.height - active.anchor.maxY - 16))
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
                    .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                    .offset(x: max(8, x), y: active.anchor.maxY + 5)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                }
                .background {
                    Button("Close") { center.close() }
                        .keyboardShortcut(.cancelAction)
                        .hidden()
                }
            }
        }
    }
}

struct DropdownHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 3)
    }
}

struct DropdownDivider: View {
    var body: some View {
        HLine().padding(.vertical, 4).padding(.horizontal, -5)
    }
}

struct DropdownItem: View {
    let title: String
    var symbol: String?
    var detail: String?
    var checked = false
    var monospaced = false
    var disabled = false
    let action: () -> Void
    @Environment(DropdownCenter.self) private var center

    var body: some View {
        Button {
            center.close()
            action()
        } label: {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                if checked {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.green)
                }
            }
            .foregroundStyle(disabled ? Theme.tertiary : Theme.text)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .hoverBackground(radius: 5)
    }
}
