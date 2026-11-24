import AppKit
import SwiftUI

/// The releases published on the server, newest first: what each one
/// brought, its notes, and how to point at it (a module's `?ref=`).
struct ReleasesView: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    @State private var releases: [ForgeRelease]?
    @State private var chosen: ForgeRelease.ID?

    var body: some View {
        Group {
            if let releases, releases.isEmpty {
                EmptyState("No releases", symbol: "shippingbox",
                           message: "\(repo.name) has no release on \(model.workspace?.host ?? "the server") yet. Tags in the clone are in History.") {
                    HStack(spacing: 8) {
                        newRelease
                        Button("History") { model.repoTab = .history }.buttonStyle(ChipButtonStyle())
                    }
                }
            } else if let releases {
                HStack(spacing: 0) {
                    ResizableColumn(key: "releases", initial: 340, range: 260...560) { list(releases) }
                    if let index = releases.firstIndex(where: { $0.id == chosen }) {
                        ReleaseDetail(repo: repo, release: releases[index],
                                      previous: releases.dropFirst(index + 1).first { $0.draft != true })
                            .id(releases[index].id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyState("Choose a release", symbol: "shippingbox").frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(repo.id)/\(model.releasesRevision)") {
            let before = Set((releases ?? []).map(\.id))
            let found = await model.releases(of: repo)
            releases = found
            // A release just published here is the one to look at.
            if let fresh = found.first(where: { !before.isEmpty && !before.contains($0.id) }) { chosen = fresh.id }
            if chosen == nil || !found.contains(where: { $0.id == chosen }) { chosen = found.first?.id }
        }
    }

    private var newRelease: some View {
        Button("New Release", systemImage: "plus") { model.sheet = .newRelease(repo) }
            .buttonStyle(ChipButtonStyle(prominent: true))
            .needsWrite()
            .help("Publish a release: a version tag with notes")
    }

    private func list(_ releases: [ForgeRelease]) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(releases.count) release\(releases.count == 1 ? "" : "s")").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                newRelease
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 2)
            releaseList(releases)
        }
    }

    private func releaseList(_ releases: [ForgeRelease]) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(releases) { release in
                    Button { chosen = release.id } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(release.tagName).font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1)
                                if release.draft == true { Badge(text: "draft", color: Theme.secondary, filled: false) }
                                if release.prerelease == true { Badge(text: "pre-release", color: Theme.orange, filled: false) }
                                if release.id == releases.first(where: { $0.draft != true && $0.prerelease != true })?.id {
                                    Badge(text: "latest", color: Theme.green, filled: false)
                                }
                                Spacer(minLength: 4)
                            }
                            HStack(spacing: 6) {
                                if let name = release.name, !name.isEmpty, name != release.tagName {
                                    Text(name).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                if let when = release.publishedAt { Text(when.relative).foregroundStyle(Theme.tertiary) }
                            }
                            .font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverBackground(selected: chosen == release.id, radius: 6)
                }
            }
            .padding(8)
        }
    }
}

/// One release: its notes, what it brought since the one before, and how
/// to use it.
private struct ReleaseDetail: View {
    @Environment(AppModel.self) private var model
    let repo: ForgeRepo
    let release: ForgeRelease
    let previous: ForgeRelease?
    @State private var commits: [PullCommit]?
    @State private var problem: String?

    /// What a Terraform / OpenTofu module call puts in `source`.
    private var moduleSource: String? {
        guard let url = repo.cloneURL, !url.isEmpty else { return nil }
        return "git::\(url)?ref=\(release.tagName)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
                    Card("Notes") { ReleaseNotes(text: notes) }
                }
                if let source = moduleSource {
                    Card("Use it") {
                        HStack(spacing: 8) {
                            Text("source = \"\(source)\"").font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Button("Copy", systemImage: "doc.on.doc") { copy(source, "Copied the module source") }
                                .buttonStyle(ChipButtonStyle())
                                .help("A module call that uses this release")
                        }
                    }
                }
                changesCard
            }
            .padding(16)
        }
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(release.name?.isEmpty == false ? release.name! : release.tagName).font(.system(size: 16, weight: .semibold))
                HStack(spacing: 8) {
                    Text(release.tagName).font(.system(size: 12, design: .monospaced))
                    if let who = release.author?.displayName { Text(who) }
                    if let when = release.publishedAt {
                        Text(when.formatted(date: .abbreviated, time: .shortened)).help(when.relative)
                    }
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 8)
            Button("Copy Tag", systemImage: "tag") { copy(release.tagName, "Copied \(release.tagName)") }
                .buttonStyle(ChipButtonStyle())
            if let url = release.htmlURL.flatMap(URL.init) {
                Button("Open on Server", systemImage: "safari") { openExternal(url) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private var changesCard: some View {
        Card(previous.map { "Since \($0.tagName)" } ?? "Changes") {
            if let count = commits?.count { Text("\(count)").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        } content: {
            if previous == nil {
                Text("The first release: nothing to compare it with.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else if let problem {
                Text(problem).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            } else if let commits {
                if commits.isEmpty { Text("No commits between the two tags.").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(commits) { commit in
                        HStack(spacing: 8) {
                            Text(String(commit.sha.prefix(8))).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.tertiary)
                            Text(commit.subject).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(commit.commit.author?.name ?? commit.author?.login ?? "").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        .font(.system(size: 12.5))
                        .frame(height: 26)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func load() async {
        guard let previous else { return }
        do {
            commits = try await model.commits(of: repo, from: previous.tagName, to: release.tagName)
        } catch {
            problem = "Cannot compare \(previous.tagName) with \(release.tagName): \(error.localizedDescription)"
        }
    }

    private func copy(_ text: String, _ note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.toast(note)
    }
}

/// Release notes in Markdown: headings, list items and paragraphs, with
/// bold, code and links inside a line.
private struct ReleaseNotes: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty {
                    Color.clear.frame(height: 2)
                } else if line.hasPrefix("#") {
                    inline(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                } else if let item = ["- ", "* ", "+ "].first(where: line.hasPrefix) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(Theme.tertiary)
                        inline(String(line.dropFirst(item.count)))
                    }
                    .padding(.leading, raw.prefix { $0 == " " }.count >= 2 ? 16 : 0)
                } else {
                    inline(line)
                }
            }
        }
        .font(.system(size: 12.5))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ line: String) -> Text {
        Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
    }
}
