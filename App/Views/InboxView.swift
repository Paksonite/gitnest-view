import SwiftUI

/// What waits for the user, server by server: the pull requests that ask
/// for their review and their own. Nothing else: merges and other people's
/// traffic are not the user's steps.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    /// One server picked from the menu, or all of them (empty).
    @AppStorage("inboxServer") private var onlyHost = ""

    private var allHosts: [String] {
        let current = model.workspace?.host
        return model.accounts.map(\.host).sorted { a, b in a == current ? true : b == current ? false : a < b }
    }

    private var hosts: [String] {
        let all = allHosts
        return all.contains(onlyHost) ? [onlyHost] : all
    }

    var body: some View {
        let hosts = hosts
        let several = model.accounts.count > 1
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Inbox").font(.system(size: 14, weight: .semibold))
                Text("reviews asked of you and your own pull requests").foregroundStyle(Theme.secondary)
                Spacer()
                if several { serverPicker }
                if model.unreadCount > 0 {
                    Button("Mark All Read") { Task { await model.markAllRead() } }.buttonStyle(ChipButtonStyle())
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.checkForNews() } }
                    .buttonStyle(ChipButtonStyle())
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .frame(height: 48)
            .background(TitleBarArea())
            HLine()
            if model.inbox.isEmpty && model.myPulls.isEmpty {
                EmptyState("Nothing waits", symbol: "tray", message: "Review requests and your open pull requests on the connected servers appear here.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(hosts, id: \.self) { host in server(host) }
                    }
                    .padding(12)
                }
            }
        }
        .task { await model.checkForNews() }
    }

    /// All connected servers, or one of them.
    private var serverPicker: some View {
        let all = allHosts
        let picked = all.contains(onlyHost) ? onlyHost : nil
        return Dropdown(id: "inbox-server", width: 280, autoOpen: model.initialOpen == "inbox-server") {
            HStack(spacing: 6) {
                if let picked { Circle().fill(ServerName.color(picked)).frame(width: 7, height: 7) }
                Text(picked.map(ServerName.short) ?? "All servers").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            .help("Show every connected server, or one of them")
        } content: {
            DropdownItem(title: "All servers", symbol: "square.stack.3d.up", detail: "\(all.count)", checked: picked == nil) { onlyHost = "" }
            DropdownDivider()
            DropdownHeader(text: "Connected servers")
            ForEach(all, id: \.self) { host in
                let count = model.inbox.filter { $0.host == host }.count + model.myPulls.filter { $0.host == host }.count
                DropdownItem(title: host, symbol: "server.rack",
                             detail: count > 0 ? "\(count)" : nil, checked: picked == host) { onlyHost = host }
            }
        }
    }

    /// One server's part: its name always on top, so nothing is mistaken
    /// for another server's.
    private func server(_ host: String) -> some View {
        let reviews = model.inbox.filter { $0.host == host }
        let mine = sorted(model.myPulls.filter { $0.host == host })
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(ServerName.color(host)).frame(width: 8, height: 8)
                Text(host).font(.system(size: 12.5, weight: .semibold))
                if host == model.workspace?.host { Text("this workspace's server").font(.system(size: 11)).foregroundStyle(Theme.tertiary) }
                Spacer()
                Text("\(reviews.count + mine.count)").font(.system(size: 11.5)).foregroundStyle(Theme.secondary).monospacedDigit()
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            HLine()
            VStack(alignment: .leading, spacing: 1) {
                if reviews.isEmpty && mine.isEmpty {
                    Text("Nothing waits for you on this server.").font(.system(size: 12)).foregroundStyle(Theme.tertiary).padding(12)
                }
                if !reviews.isEmpty {
                    header("Waiting for your review", reviews.count)
                    ForEach(reviews) { item in
                        let fullName = item.hit.repository?.fullName ?? ""
                        row(symbol: "eye", tint: Theme.orange, title: item.hit.title,
                            detail: "\(fullName) #\(item.hit.number) · \(item.hit.user?.displayName ?? "")", when: item.hit.updatedAt, badge: nil,
                            unread: model.isUnread(host: host, fullName: fullName, number: item.hit.number)) {
                            Task {
                                await model.markRead(host: host, fullName: fullName, number: item.hit.number)
                                await model.open(item)
                            }
                        }
                    }
                }
                if !mine.isEmpty {
                    header("Your pull requests", mine.count)
                    ForEach(mine) { pull in
                        row(state: pull.state, title: pull.title, detail: "\(pull.repoFullName) #\(pull.number)", when: nil,
                            badge: pull.state == .failure ? ("checks fail", Theme.red)
                                : pull.changesRequested ? ("changes requested", Theme.orange)
                                : pull.ready ? ("ready to merge", Theme.green)
                                : pull.approvals > 0 ? ("approved", Theme.green) : ("waiting for review", Theme.secondary),
                            unread: model.isUnread(host: host, fullName: pull.repoFullName, number: pull.number)) {
                            Task {
                                await model.markRead(host: host, fullName: pull.repoFullName, number: pull.number)
                                await model.openPull(host: pull.host, fullName: pull.repoFullName, number: pull.number, url: pull.htmlURL)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.border))
        .overlay(alignment: .leading) {
            // The server's colour down the side: the eye sorts by it.
            UnevenRoundedRectangle(topLeadingRadius: Theme.radius, bottomLeadingRadius: Theme.radius)
                .fill(ServerName.color(host)).frame(width: 3)
        }
    }

    /// What needs the user first: failing, then changes asked, then ready to merge.
    private func sorted(_ pulls: [MyPull]) -> [MyPull] {
        func rank(_ pull: MyPull) -> Int { pull.state == .failure ? 0 : pull.changesRequested ? 1 : pull.ready ? 2 : 3 }
        return pulls.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.number > $1.number }
    }

    private func header(_ text: String, _ count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.5)
            Text("\(count)").font(.system(size: 10.5)).monospacedDigit()
        }
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }

    private func row(symbol: String? = nil, tint: Color = Theme.secondary, state: CheckState? = nil, title: String, detail: String,
                     when: Date?, badge: (String, Color)?, unread: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // Unread: something happened here since the user last looked.
                Circle().fill(unread ? Theme.blue : .clear).frame(width: 7, height: 7)
                    .help(unread ? "New since you last opened it" : "")
                    .accessibilityLabel(unread ? "Unread" : "Read")
                Group {
                    if let state { CheckIcon(state: state) } else if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(unread ? .semibold : .regular).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(detail)
                        if let when { Text(when.relative) }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if let badge { Badge(text: badge.0, color: badge.1, filled: false) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .opacity(unread ? 1 : 0.82)
        }
        .buttonStyle(.plain)
        .hoverBackground(radius: 0)
    }
}
