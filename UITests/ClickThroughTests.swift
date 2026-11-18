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
        // Recording a demo: the app shows GNV_UI_ALIAS's first name and talks to the second.
        if let alias = env["GNV_UI_ALIAS"], let real = alias.split(separator: "=").last, let shown = alias.split(separator: "=").first {
            app.launchEnvironment.merge(["GNV_DEV_ALIAS": alias, "GIT_CONFIG_COUNT": "1",
                                         "GIT_CONFIG_KEY_0": "url.https://\(real)/.insteadOf", "GIT_CONFIG_VALUE_0": "https://\(shown)/"]) { $1 }
        }
        if name.contains("Jira") {
            guard let site = env["GNV_UI_JIRA_SITE"], let email = env["GNV_UI_JIRA_EMAIL"], let jira = env["GNV_UI_JIRA_TOKEN"], let issue = env["GNV_UI_JIRA_ISSUE"] else {
                throw XCTSkip("no test Jira configured (GNV_UI_JIRA_SITE, _EMAIL, _TOKEN, _ISSUE)")
            }
            app.launchEnvironment.merge(["GNV_DEV_JIRA_SITE": site, "GNV_DEV_JIRA_EMAIL": email, "GNV_DEV_JIRA_TOKEN": jira, "GNV_DEV_TICKET": issue]) { $1 }
        }
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

    /// A walk through the app for the README's animation, filmed from
    /// outside (scripts/demo-gif.sh). Only when GNV_UI_DEMO=1; the demo
    /// server's workspace has its own repositories (GNV_UI_DEMO_REPO is one
    /// with local changes, GNV_UI_DEMO_ACTIONS one with pipeline runs).
    func testDemoTour() throws {
        guard env["GNV_UI_DEMO"] == "1", let work = env["GNV_UI_DEMO_REPO"], let actions = env["GNV_UI_DEMO_ACTIONS"] else {
            throw XCTSkip("GNV_UI_DEMO=1, GNV_UI_DEMO_REPO, GNV_UI_DEMO_ACTIONS")
        }
        func pause(_ seconds: Double) { usleep(UInt32(seconds * 1_000_000)) }
        // The button named exactly so first (a folder "modules" is not
        // "terraform-modules"), then one whose name begins so.
        func tap(_ text: String, timeout: TimeInterval = 10) {
            let exact = app.buttons.matching(NSPredicate(format: "label ==[c] %@ OR title ==[c] %@", text, text)).firstMatch
            let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", text)).firstMatch
            let found = exact.waitForExistence(timeout: timeout) ? exact : start
            if found.waitForExistence(timeout: 2) { found.hover(); pause(0.4); found.click() }
        }
        func tapContaining(_ text: String, timeout: TimeInterval = 10) {
            let found = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
            if found.waitForExistence(timeout: timeout) { found.hover(); pause(0.4); found.click() }
        }
        let window = app.windows.firstMatch
        // Repositories by ⌘K: what a user types, and the palette on film.
        func goTo(_ repo: String) {
            window.typeKey("k", modifierFlags: .command)
            pause(0.8)
            let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Jump'")).firstMatch
            guard field.waitForExistence(timeout: 5) else { return }
            field.click()
            for character in repo { field.typeText(String(character)); usleep(90_000) }
            pause(1.2)
            field.typeKey(.return, modifierFlags: [])
        }
        _ = button("Home", timeout: 25)
        tap("Home")
        _ = app.staticTexts["Waiting for your review"].waitForExistence(timeout: 20)
        try? "start".write(toFile: (env["GNV_UI_TMP"] ?? NSTemporaryDirectory()) + "/demo-start", atomically: true, encoding: .utf8)
        pause(4)
        // A repository with work in progress: its overview, the changes, the tree.
        goTo(work)
        pause(3.5)
        tap("Changes")
        pause(3)
        tap("Files")
        pause(2)
        tap("modules")
        pause(1)
        tap("rules")
        pause(2.5)
        // Pull requests with their checks and reviews.
        tap("Pull requests")
        pause(2.5)
        tapContaining("OPS-")
        pause(4)
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.6)).scroll(byDeltaX: 0, deltaY: -300)
        pause(2.5)
        // A pipeline's log, step by step.
        goTo(actions)
        pause(2)
        tap("Actions")
        pause(3)
        tapContaining("ci: run")
        pause(2.5)
        tapContaining("single state")
        pause(5)
        // The Inbox: what waits for the user on every server.
        tap("Inbox")
        pause(3)
        tap("All servers")
        pause(2)
        app.typeKey(.escape, modifierFlags: [])
        pause(1)
        // Search across every clone.
        tap("Search")
        pause(1)
        let field = app.textFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.click()
            field.typeText("rules\r")
        }
        pause(4)
        tap(work)
        pause(3)
        tap("Home")
        pause(3)
    }

    /// The ticket window over the app: status menu, assignee, comments,
    /// time. Logs 15 minutes on the test ticket (GNV_UI_JIRA_ISSUE); the
    /// caller removes the worklog afterwards.
    func testJiraTicketWindow() throws {
        let issue = try XCTUnwrap(env["GNV_UI_JIRA_ISSUE"])
        _ = element(issue, timeout: 30)
        let status = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Status: '")).firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20), "no status menu")
        shot("30-ticket")
        // The status lists Jira's moves; Escape leaves it as it was.
        status.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Workflow: '")).firstMatch.waitForExistence(timeout: 5), "the status menu lists no move")
        shot("31-ticket-status")
        element("TIME TRACKING").click() // a click beside it closes the list
        // The assignee: people to hand it to.
        let assignee = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Assignee: '")).firstMatch
        XCTAssertTrue(assignee.exists, "no assignee picker")
        assignee.click()
        XCTAssertTrue(app.textFields["Search people"].firstMatch.waitForExistence(timeout: 5), "no people search")
        sleep(2)
        shot("32-ticket-assignee")
        element("TIME TRACKING").click()
        // Time: a wrong one is explained, not silently refused.
        let spent = app.textFields["Time spent"].firstMatch
        XCTAssertTrue(spent.waitForExistence(timeout: 5), "no time field")
        spent.click()
        spent.typeText("abc")
        _ = element("Write the time as Jira does")
        let log = button("Log Time")
        XCTAssertTrue(log.isEnabled, "Log Time must stay clickable")
        shot("33-ticket-time-wrong")
        button("Time: 15m").click()
        log.click()
        _ = element("Logged 15m on \(issue)", timeout: 15)
        shot("34-ticket-logged")
    }

    /// The sidebar after a pull and a change of repository: one row lit
    /// (the selected one), and the pulled one without its ↓. Needs a clone
    /// of GNV_UI_BEHIND_REPO that is behind its upstream, and GNV_UI_OTHER_REPO.
    func testSidebarAfterPullAndSwitch() throws {
        // Steps the caller photographs from outside (screenshots fail on some Macs).
        func mark(_ step: String) {
            try? step.write(toFile: (env["GNV_UI_TMP"] ?? NSTemporaryDirectory()) + "/step", atomically: true, encoding: .utf8)
            sleep(3)
        }
        guard let behind = env["GNV_UI_BEHIND_REPO"], let other = env["GNV_UI_OTHER_REPO"] else { throw XCTSkip("GNV_UI_BEHIND_REPO, GNV_UI_OTHER_REPO") }
        button(behind, timeout: 25).click()
        sleep(2)
        mark("50")
        let pull = app.buttons.matching(NSPredicate(format: "label MATCHES 'Pull [0-9]+'")).firstMatch
        XCTAssertTrue(pull.waitForExistence(timeout: 15), "no Pull button for a clone that is behind")
        pull.click()
        _ = element("Pulled", timeout: 30)
        sleep(1)
        mark("51")
        button(other).click()
        sleep(1)
        // The pointer away from the list, over the content.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).hover()
        sleep(2)
        mark("52")
        button(behind).hover()
        sleep(1)
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)).hover()
        sleep(1)
        mark("53")
    }

    /// A diff with a long line scrolls sideways to the line's end. Needs a
    /// clone of GNV_UI_LONG_REPO with an uncommitted GNV_UI_LONG_FILE whose
    /// long line ends in "END-OF-LINE".
    func testLongDiffLineScrollsToItsEnd() throws {
        guard let repo = env["GNV_UI_LONG_REPO"], let file = env["GNV_UI_LONG_FILE"] else { throw XCTSkip("GNV_UI_LONG_REPO, GNV_UI_LONG_FILE") }
        let window = app.windows.firstMatch
        window.typeKey("k", modifierFlags: .command)
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue BEGINSWITH 'Jump'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText(repo + "\r")
        button("Changes", timeout: 15).click()
        element(file, timeout: 15).click()
        let end = app.staticTexts.matching(NSPredicate(format: "value CONTAINS 'END-OF-LINE' OR label CONTAINS 'END-OF-LINE'")).firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 10), "the long line is not in the diff")
        let pane = window.frame
        // Far to the right: the end of the line comes into the window.
        let diff = window.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5))
        for _ in 0..<12 { diff.scroll(byDeltaX: -800, deltaY: 0) }
        sleep(1)
        XCTAssertLessThanOrEqual(end.frame.maxX, pane.maxX, "the end of the long line cannot be scrolled into view")
    }

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
