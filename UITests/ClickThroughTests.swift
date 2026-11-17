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
