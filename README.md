# GitNest View

**GitNest Desktop for Mac** — [gitnest](https://github.com/Paksonite/gitnest)
as a native macOS app: every git repository on one screen, with the pull
requests, reviews, pipeline checks and live job logs of your Forgejo server.

GitNest View is gitnest: its engine is gitnest's own git code.

> Early development. There are no releases yet; when there are:
>
> ```sh
> brew install --cask paksonite/tap/gitnest-view
> ```
>
> or the DMG from [Releases](https://github.com/Paksonite/gitnest-view/releases).
> The app updates itself (GitNest View → Check for Updates…). Releasing:
> [docs/releasing.md](docs/releasing.md).

## What works

**Find your way.** Home shows what needs you across the workspace (a
failed pipeline on the default branch, your failing pull request, a review
asked of you, commits to pull or push, uncommitted work) with one button to
deal with each, your pull requests, the reviews waiting for you, and the
commit activity of the last two weeks. The sidebar lists the repositories
that need attention first. ⌘K jumps to any repository, pull request,
branch or workflow, or runs a command. A menu bar item and macOS
notifications (a review request, a failed pipeline of your pull request)
tell you without switching windows.

**Work on a clone** (gitnest's engine underneath):
- Changes: stage files or single lines, discard, commit or amend, push or
  publish a branch, then open its pull request; stashes; finishing or
  aborting a merge or rebase that stopped on conflicts; diverged branches
  rebase or merge.
- History: reword, squash, fixup, drop or revert a commit, with a second
  question for commits already on the server, and undo for every rewrite;
  branches: switch, create, rename, delete (also on the server), clean up
  the ones whose server branch is gone.
- Fetch all and pull all (fast-forward every branch that is behind, like
  gitnest's pull all), and a quiet fetch every 10 minutes.
- Clone one repository or all of a workspace with one click; open a clone
  in your editor or terminal.

**Pull requests and pipelines** on a connected Forgejo server: reviews
(with the approvals the branch protection requires), checks, commits,
files, the Terraform or OpenTofu plan read from the pipeline's log (or its
error, when it failed), the apply after the merge, and only the jobs that
matter (configurable) unless something else fails. Release opens the pull
request from develop into the default branch with the tickets found in
the commits. Actions lists the workflows, starts one by hand with its
inputs, re-runs and cancels, and shows a job's log step by step, coloured,
followed live while it runs.

Requires macOS 14 or later on Apple silicon, `git`, and Forgejo 16 or later.
The token needs read access to repositories, organisations, issues and your
user; opening a pull request, starting or re-running a workflow needs
write access to repositories. With HTTPS remotes the same token is used for
git, passed to git per command and never written into a clone.

## Build

Needs Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Go 1.25+
(`brew install xcodegen go`).

```sh
scripts/install.sh # build, sign with the GitNest View certificate, install into /Applications
scripts/build.sh   # → build.noindex/GitNest View.app
scripts/test.sh    # the engine's tests, then the app's
```

`GitNestView.xcodeproj` is generated from `project.yml` and is not committed;
run `xcodegen generate` to open it in Xcode.

## Layout

| Path | What |
|---|---|
| `App/` | the macOS app (Swift, SwiftUI with AppKit where it matters) |
| `App/Core` | talks to the engine: JSON-RPC over the engine's stdin/stdout |
| `App/Forge` | the Forgejo client, accounts, logs, Terraform plan and error parsing |
| `App/Model` | the app's state: `AppModel`, work on clones (`LocalWork`), what needs attention, notifications |
| `App/Views` | the window, Home, the repository tabs, ⌘K, sheets, menu bar item |
| `core/` | the engine, `gitnest-core` (Go): gitnest's `gitx`, `scan`, `config` and `state` packages plus `internal/rpc`, `internal/workflow` and the methods in `cmd/gitnest-core` |
| `design/` | the logo and the app icon (SVG); `scripts/make-icon.sh` renders them |
| `Tests/` | the app's tests; `LiveForgejoTests` run against a real server when `TEST_RUNNER_GNV_*` is set |

Signing: `scripts/sign.sh` uses `~/.config/paksonite-gitnest-view/signing.p12`
(or `SIGNING_P12_BASE64` in CI), a self-signed certificate, so the app keeps
one identity across builds and the Keychain does not ask again after each
update; without it the app is signed ad hoc.

The engine's packages were copied from gitnest v2.0.20.

## License

MIT
