import XCTest

/// Clicks through the real app the way a user does, against a test server
/// (never one that matters: the app is started in its development mode
/// with the token from the environment, its own preferences and no
/// Keychain). Skipped unless the environment names the server:
///
///     GNV_UI_HOST, GNV_UI_TOKEN, GNV_UI_WORKDIR, GNV_UI_WORKSPACE, GNV_UI_LOGIN
///     GNV_UI_PULL_REPO   a repository whose open pull request changes a file
///     GNV_UI_TF_REPO     a cloned repository with Terraform resources
///
/// Nothing here sends anything to the server: forms are opened and closed.
final class ClickThroughTests: XCTestCase {
    private var app: XCUIApplication!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard let host = env["GNV_UI_HOST"], let token = env["GNV_UI_TOKEN"], let workdir = env["GNV_UI_WORKDIR"] else {
            throw XCTSkip("no test server configured")
        }
        if name.contains("ReleaseFirstRun") {
            // Only when asked: it drives the copy in /Applications and its Keychain.
            guard env["GNV_UI_RELEASE"] == "1" else { throw XCTSkip("GNV_UI_RELEASE=1 is not set") }
            // The release build as a user gets it: installed in /Applications,
            // its real identity, the Keychain, no development switches.
            app = XCUIApplication(bundleIdentifier: "pl.paksonite.gitnest-view")
            let folder = (env["GNV_UI_TMP"] ?? NSTemporaryDirectory()) + "/release-\(Int(Date().timeIntervalSince1970))/GitNest"
            app.launchEnvironment = ["GNV_SUGGESTED_WORKDIR": folder]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            return
        }
        app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        if name.contains("FirstRun") {
            // A first launch: nothing connected, its own preferences, a folder of its own.
            let folder = (env["GNV_UI_TMP"] ?? NSTemporaryDirectory()) + "/wizard-\(Int(Date().timeIntervalSince1970))/GitNest"
            app.launchEnvironment = ["GNV_DEV_ONBOARDING": "1", "GNV_SUGGESTED_WORKDIR": folder]
            app.launch()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
            return
        }
        app.launchEnvironment = [
            "GNV_DEV_OPEN": name.contains("MenuBar") ? "menubar" : "",
            "GNV_DEV_HOST": host, "GNV_DEV_TOKEN": token, "GNV_DEV_WORKDIR": workdir, "GNV_DEV_NOFETCH": "1",
            "GNV_DEV_WORKSPACE": env["GNV_UI_WORKSPACE"] ?? "", "GNV_DEV_LOGIN": env["GNV_UI_LOGIN"] ?? "",
        ]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    // MARK: Helpers

    /// A picture of the window, kept with the test's result
    /// (xcrun xcresulttool export attachments).
    private func shot(_ name: String, of window: XCUIElement? = nil) {
        let attachment = XCTAttachment(screenshot: (window ?? app.windows.firstMatch).screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR title CONTAINS[c] %@", text, text, text)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "\"\(text)\" is not on screen", file: file, line: line)
        return found
    }

    private func button(_ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let found = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@ OR title CONTAINS[c] %@", text, text)).firstMatch
        XCTAssertTrue(found.waitForExistence(timeout: timeout), "no button \"\(text)\"", file: file, line: line)
        return found
    }

    private func gone(_ text: String, timeout: TimeInterval = 5) -> Bool {
        let found = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR placeholderValue CONTAINS[c] %@", text, text)).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while found.exists, Date() < deadline { usleep(100_000) }
        return !found.exists
    }

    private func openRepository(_ name: String) {
        // The sidebar dims the shared prefix; the row's label still holds the name's end.
        let tail = name.split(separator: "-").last.map(String.init) ?? name
        button(tail, timeout: 25).click()
    }

    // MARK: Tests

    func testRepositoryTabsAndPullRequest() throws {
        let repo = try XCTUnwrap(env["GNV_UI_PULL_REPO"], "GNV_UI_PULL_REPO")
        openRepository(repo)
        _ = element(repo)
        shot("01-overview")
        for tab in ["Changes", "History", "Resources", "Pull requests", "Actions", "Overview"] {
            button(tab).click()
            usleep(500_000)
            shot("02-tab-\(tab.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }

        // Overview says what runs and what waits; the pull request itself is in Pull requests.
        button("Overview").click()
        _ = element("Open pull requests")
        shot("01a-overview")
        button("Pull requests").click()
        // The conversation and the people are on the pull request; the menu
        // offers the rest (nothing is chosen here).
        _ = element("Conversation")
        _ = element("People and labels")
        button("More actions").click()
        _ = button("Edit Title and Description")
        shot("01b-pull-menu")
        app.typeKey(.escape, modifierFlags: [])
        if app.buttons.matching(NSPredicate(format: "label CONTAINS 'Edit Title'")).firstMatch.exists { button("More actions").click() }

        // A changed file's name answers the pointer, and a click shows its changes.
        let files = element("Files ·")
        XCTAssertTrue(files.exists)
        let file = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] '.tf' OR label CONTAINS[c] '.tfvars' OR label CONTAINS[c] '.yaml'")).firstMatch
        XCTAssertTrue(file.waitForExistence(timeout: 10), "no changed file listed")
        file.hover()
        _ = element("Show changes", timeout: 3)
        shot("03-file-hover")
        file.click()
        _ = button("Close")
        shot("04-file-diff")
        app.typeKey(.escape, modifierFlags: [])

        // The merge form opens with the plan and closes without merging.
        if app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merge'")).firstMatch.waitForExistence(timeout: 3) {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Merge'")).firstMatch.click()
            _ = button("Cancel")
            shot("05-merge-sheet")
            button("Cancel").click()
        }
    }

    func testResourcesOpenInTheBuiltInViewer() throws {
        let repo = try XCTUnwrap(env["GNV_UI_TF_REPO"], "GNV_UI_TF_REPO")
        openRepository(repo)
        button("Resources").click()
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'module.' OR label CONTAINS[c] 'google_'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no resource listed")

        // The history button shows under the pointer and opens the commits.
        row.hover()
        let history = button("History of ", timeout: 3)
        shot("06-resource-hover")
        history.click()
        sleep(2)
        shot("07-resource-history")
        app.typeKey(.escape, modifierFlags: [])

        // A click shows the file beside the list, not in an editor and not over it.
        row.click()
        let close = button("Close File")
        XCTAssertTrue(row.exists, "the list stays beside the file")
        shot("08-file-pane")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(gone("Close File"), "Escape must close the file pane")
        row.click()
        _ = button("Close File")
        close.click()
        XCTAssertTrue(gone("Close File"), "the pane's own button must close it")
        shot("09-file-pane-closed")
    }

    /// A new pull request starts in the Pull requests tab, with the
    /// server's branches to choose from. Nothing is opened.
    func testNewPullRequestForm() throws {
        let repo = try XCTUnwrap(env["GNV_UI_PULL_REPO"], "GNV_UI_PULL_REPO")
        openRepository(repo)
        button("Pull requests").click()
        _ = element("Review required")
        shot("20-review-required")
        button("Changes").click()
        usleep(600_000)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pull Request'")).firstMatch.exists, "Changes must not offer pull requests")
        button("Pull requests").click()
        button("New").click()
        _ = element("New pull request in")
        sleep(2)
        shot("21-new-pull-request")
        let into = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Into branch'")).firstMatch
        XCTAssertTrue(into.waitForExistence(timeout: 5), "no list for the branch to merge into")
        into.click()
        // The list holds what the server has.
        let main = app.buttons.matching(NSPredicate(format: "label == 'main'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 8), "the server's branches are not listed")
        shot("22-branch-list")
        main.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Into branch: main'")).firstMatch.waitForExistence(timeout: 3))
        button("Cancel").click()
    }

    func testPaletteHomeAndSheets() throws {
        let repo = try XCTUnwrap(env["GNV_UI_TF_REPO"], "GNV_UI_TF_REPO")
        _ = button("Home", timeout: 25)
        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "⌘K must open the palette")
        field.click()
        field.typeText(repo)
        usleep(600_000)
        shot("10-palette")
        app.typeKey(.return, modifierFlags: [])
        _ = button("Fetch", timeout: 10) // the repository's header

        button("Home").click()
        _ = element("To do")
        shot("11-home")
        button("Releases").click()
        _ = button("Close")
        sleep(3)
        shot("12-releases")
        app.typeKey(.escape, modifierFlags: [])
        button("Inbox").click()
        usleep(600_000)
        shot("13-inbox")
        button("Search").click()
        usleep(600_000)
        shot("14-search")
    }

    /// A feature branch in a repository without develop: the form compares
    /// it with the default branch, lists its commit, and reports no error.
    func testNewPullRequestFromAFeatureBranch() throws {
        let repo = try XCTUnwrap(env["GNV_UI_FEATURE_REPO"], "GNV_UI_FEATURE_REPO")
        let branch = try XCTUnwrap(env["GNV_UI_FEATURE_BRANCH"], "GNV_UI_FEATURE_BRANCH")
        openRepository(repo)
        button("Pull requests").click()
        button("New").click()
        _ = element("New pull request in")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "From branch: \(branch)")).firstMatch.waitForExistence(timeout: 10),
                      "the form starts from the branch checked out")
        _ = element("1 commit", timeout: 15)
        sleep(3) // any second comparison has answered by now
        shot("23-feature-branch-form")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'Cannot compare' OR label CONTAINS 'Cannot compare'")).firstMatch.exists,
                       "a comparison error must not stand next to a good comparison")
        button("Cancel").click()
    }

    /// The installed release on a clean Mac: intro, wizard against a test
    /// server, the app at work, then a second launch straight into it. It
    /// must not stop at any point (0.1.0 did, right after the first launch).
    func testReleaseFirstRun() throws {
        let host = try XCTUnwrap(env["GNV_UI_HOST"]), token = try XCTUnwrap(env["GNV_UI_TOKEN"])
        let workspace = try XCTUnwrap(env["GNV_UI_WORKSPACE"])
        button("Get Started", timeout: 15).click()
        let server = app.textFields.firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.click()
        server.typeText(host)
        button("Continue").click()
        let secret = app.secureTextFields.firstMatch
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.click()
        secret.typeText(token)
        button("Connect").click()
        _ = element("Signed in as", timeout: 20)
        shot("50-release-token")
        button("Continue").click()
        button(workspace, timeout: 15).click()
        button("Continue").click()
        button("Use This Folder").click()
        _ = element("Ready")
        button("Skip the Tour").click()
        _ = button("Home", timeout: 15)
        // At work for a while: the inbox, notifications and pipelines are read meanwhile.
        sleep(20)
        XCTAssertEqual(app.state, .runningForeground, "the app stopped after the first launch")
        shot("51-release-home")

        // Again: no wizard, straight into the workspace, still alive.
        app.terminate()
        app.launch()
        _ = button("Home", timeout: 20)
        XCTAssertFalse(app.buttons["Get Started"].exists, "the setup was not remembered")
        sleep(15)
        XCTAssertEqual(app.state, .runningForeground, "the app stopped on the second launch")
        shot("52-release-second-launch")
        app.terminate()
    }

    /// The first launch from the intro to the tour, then the new Settings.
    func testFirstRunWizardTourAndSettings() throws {
        let host = try XCTUnwrap(env["GNV_UI_HOST"]), token = try XCTUnwrap(env["GNV_UI_TOKEN"])
        let workspace = try XCTUnwrap(env["GNV_UI_WORKSPACE"], "GNV_UI_WORKSPACE")

        // The intro: logo, slogan, and the way on.
        let start = button("Get Started", timeout: 15)
        _ = element("One place")
        shot("30-intro")
        start.click()

        // 1. The server.
        _ = element("Where is your Forgejo")
        let server = app.textFields.firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        server.click()
        server.typeText(host)
        shot("31-wizard-server")
        button("Continue").click()

        // 2. The token, and what it allows: one line per feature.
        _ = element("An access token")
        let secret = app.secureTextFields.firstMatch
        XCTAssertTrue(secret.waitForExistence(timeout: 10))
        secret.click()
        secret.typeText(token)
        button("Connect").click()
        _ = element("Signed in as", timeout: 20)
        _ = element("What this token allows")
        _ = element("List repositories, read pipelines and logs", timeout: 15)
        shot("32-wizard-token")
        button("Continue").click()

        // 3. The workspace.
        _ = element("Which workspace first")
        button(workspace, timeout: 15).click()
        shot("33-wizard-workspace")
        button("Continue").click()

        // 4. The folder: one for GitNest, the server inside it.
        _ = element("GitNest's working folder")
        _ = element(host + "/")
        shot("34-wizard-folder")
        button("Use This Folder").click()

        // 5. Done: the tour is offered, and can be refused.
        _ = element("Ready")
        _ = button("Skip the Tour")
        shot("35-wizard-finish")
        button("Show Me Around").click()

        // The tour describes; Next walks; Skip ends it.
        _ = element("The sidebar: what needs you first", timeout: 10)
        shot("36-tour-1")
        button("Next").click()
        _ = element("Home: your steps")
        shot("37-tour-2")
        for _ in 0..<5 { button("Next").click(); usleep(350_000) }
        shot("38-tour-7")
        button("Skip the Tour").click()
        XCTAssertTrue(gone("Skip the Tour"), "the tour must end when skipped")

        // Settings: tabs, the theme, the server with its permissions.
        app.buttons.matching(NSPredicate(format: "label == 'Settings'")).firstMatch.click()
        let settings = app.windows.element(boundBy: 0)
        // Settings open on the page used last: go to General.
        button("General", timeout: 15).click()
        func pick(_ name: String) {
            let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 10), "no \(name) in the theme picker")
            item.click()
        }
        shot("39-settings-general", of: settings.exists ? settings : nil)
        pick("Dark")
        usleep(500_000)
        pick("Light")
        usleep(700_000)
        shot("40-settings-light", of: settings.exists ? settings : nil)
        pick("System")
        button("Servers").click()
        _ = element("What this token allows", timeout: 10)
        _ = element("Notify me about this server")
        usleep(1_500_000)
        shot("41-settings-servers", of: settings.exists ? settings : nil)
        button("Integrations").click()
        _ = element("Jira (optional)")
        shot("42-settings-integrations", of: settings.exists ? settings : nil)
    }

    /// The menu bar panel, drawn in the window (the real one is not in the
    /// app's tree for the automation): a review row answers the pointer with
    /// Approve, and one click only arms it.
    func testMenuBarQuickAction() throws {
        _ = button("Home", timeout: 25)
        _ = element("Waiting for your review", timeout: 20)
        sleep(2) // the list settles once the inbox is read
        let window = app.windows.firstMatch.frame
        // The panel's rows (right half of the window); a review row offers Approve under the pointer.
        // Review rows, not the user's own ("your …"); the list fills as the inbox is read.
        var rows: [XCUIElement] = []
        for _ in 0..<15 where rows.isEmpty {
            let query = app.buttons.matching(NSPredicate(format: "label CONTAINS ' #'"))
            // The panel redraws when the inbox is read again: ask only once it has rows.
            guard query.firstMatch.waitForExistence(timeout: 2) else { continue }
            rows = query.allElementsBoundByIndex
                .filter { $0.frame.minX > window.midX && !$0.label.lowercased().contains("your") }
            if rows.isEmpty { sleep(1) }
        }
        XCTAssertFalse(rows.isEmpty, "no review row in the menu bar panel")
        shot("15-menubar")
        var approve = app.buttons["Approve"].firstMatch
        for candidate in rows.prefix(6) where !approve.exists {
            for _ in 0..<2 where !approve.exists {
                button("Home").hover()
                usleep(300_000)
                candidate.hover()
                approve = app.buttons["Approve"].firstMatch
                _ = approve.waitForExistence(timeout: 1.5)
            }
        }
        let row = rows.first
        _ = row
        shot("16-menubar-hover")
        print("MENU-DEBUG rows \(rows.count): \(rows.prefix(8).map { "\($0.label.prefix(40)) @\(Int($0.frame.minX)),\(Int($0.frame.minY))" })")
        XCTAssertTrue(approve.waitForExistence(timeout: 3), "no row shows Approve under the pointer")
        // One click only arms it ("Confirm"); nothing is sent without the second.
        approve.click()
        XCTAssertTrue(app.buttons["Confirm"].firstMatch.waitForExistence(timeout: 2), "the first click must ask for a second one")
        shot("17-menubar-armed")
        sleep(4)
        XCTAssertFalse(app.buttons["Confirm"].firstMatch.exists, "the armed button must stand down after three seconds")
    }
}
