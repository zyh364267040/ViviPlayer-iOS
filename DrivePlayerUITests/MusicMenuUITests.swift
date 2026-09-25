import XCTest

/// Uses only the installed app's system accessibility hierarchy and real touch events.
/// The parent supplies the visible title of an existing synthetic track on the dedicated sim.
final class MusicMenuUITests: XCTestCase {
    @MainActor
    func testRealMusicPageOpensCompletionMenu() throws {
        continueAfterFailure = false
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["VIVI_SYNTHETIC_TRACK_TITLE"],
                                  "Set TEST_RUNNER_VIVI_SYNTHETIC_TRACK_TITLE to the existing synthetic track's visible title")
        XCTAssertFalse(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let app = XCUIApplication(bundleIdentifier: "com.example.DrivePlayer")
        defer {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "real-app-final-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "real-app-final-screen"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        app.launch()
        tapCenter(app.tabBars.buttons["音乐"], named: "音乐 tab")
        let library = app.descendants(matching: .any)["music-library-filter"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "真实音乐页未出现")

        // The song row is inside the list; the root mini is outside the list.
        let titlePredicate = NSPredicate(format: "label CONTAINS %@", title)
        let rowTitle = app.cells.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        tapCenter(rowTitle, named: "合成歌曲行标题")
        // Locate the mini title next to its dedicated playback control. At large
        // accessibility sizes the library row may extend beneath the mini.
        let miniQuery = app.buttons.matching(titlePredicate)
        let miniControl = app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["pause.fill", "play.fill"])).firstMatch
        XCTAssertTrue(miniControl.waitForExistence(timeout: 10))
        let miniReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            miniQuery.allElementsBoundByIndex.filter {
                $0.isHittable && abs($0.frame.midY - miniControl.frame.midY) < 30
                    && $0.frame.maxY <= app.tabBars.firstMatch.frame.minY
            }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [miniReady], timeout: 10), .completed,
                       "须唯一定位 mini 主控旁、tab 上方的真实 mini 标题按钮")
        let miniButton = try XCTUnwrap(miniQuery.allElementsBoundByIndex.first {
            $0.isHittable && abs($0.frame.midY - miniControl.frame.midY) < 30
                && $0.frame.maxY <= app.tabBars.firstMatch.frame.minY
        })
        tapCenter(miniButton, named: "mini 详情入口")
        let menu = app.buttons["music-completion-mode-menu"]
        tapCenter(menu, named: "真实循环菜单")
        for (identifier, label) in [("repeatAll", "列表循环"), ("repeatOne", "单曲循环"), ("stopAtEnd", "播完停止")] {
            let option = app.buttons["music-completion-mode-\(identifier)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5), "原生菜单缺少 \(label)")
            let frame = option.frame
            // Native menus can remain visibly onscreen while XCTest's animation
            // monitor reports isHittable=false during a long UI batch. The
            // separate selection tests perform actual taps on all three rows.
            XCTAssertGreaterThan(frame.width, 0, "菜单项缺少有效宽度：\(label)")
            XCTAssertGreaterThan(frame.height, 0, "菜单项缺少有效高度：\(label)")
            XCTAssertTrue(app.frame.contains(frame), "菜单项在屏幕外：\(label), \(frame)")
            XCTAssertEqual(option.label, label)
        }
    }


    private let modes = [(id: "repeatAll", label: "列表循环"),
                         (id: "repeatOne", label: "单曲循环"),
                         (id: "stopAtEnd", label: "播完停止")]

    @MainActor
    func testCompletionRepeatAllRealSelection() throws { try exerciseCompletion("repeatAll") }

    @MainActor
    func testCompletionRepeatOneRealSelection() throws { try exerciseCompletion("repeatOne") }

    @MainActor
    func testCompletionStopAtEndRealSelection() throws { try exerciseCompletion("stopAtEnd") }

    @MainActor
    private func exerciseCompletion(_ target: String, recordLargeTextGeometry: Bool = false) throws {
        let app = try launchSyntheticDetail()
        let paused = try pausedDetailSnapshot(app)
        let initial = try completionID(app)
        let shuffle = app.buttons["music-shuffle-toggle"]
        let initialShuffle = shuffle.isSelected
        let initialShuffleValue = shuffle.value as? String
        defer {
            // The reopened menu is still visible, including after selected-trait failures.
            tapCenter(app.buttons["music-completion-mode-\(initial)"], named: "恢复初始 completion")
            assertPausedDetailUnchanged(app, paused, after: "恢复初始 completion")
            XCTAssertEqual(app.buttons["music-completion-mode-menu"].value as? String,
                           modes.first { $0.id == initial }?.label)
            XCTAssertEqual(shuffle.isSelected, initialShuffle)
            XCTAssertEqual(shuffle.value as? String, initialShuffleValue)
            if recordLargeTextGeometry {
                tapCenter(app.buttons["music-completion-mode-menu"], named: "大字号恢复后重开 completion")
                assertUniqueSelection(app, expected: initial)
                tapCenter(app.buttons["music-completion-mode-\(initial)"], named: "关闭恢复后的大字号菜单")
                assertPausedDetailUnchanged(app, paused, after: "关闭恢复后的大字号菜单")
            }
            record(app, "restored-completion")
        }
        tapCenter(app.buttons["music-completion-mode-menu"], named: "completion 菜单")
        record(app, "before-completion-choice")
        if recordLargeTextGeometry {
            assertUniqueSelection(app, expected: initial)
            let rows = modes.map { mode in
                "\(mode.id): \(app.buttons["music-completion-mode-\(mode.id)"].frame)"
            }.joined(separator: "\n")
            let geometry = XCTAttachment(string:
                "Parent-confirmed system content size: accessibility-extra-extra-extra-large\n" +
                "App frame (points): \(app.frame)\nMenu row AX frames (points):\n\(rows)\n" +
                "Popup outer bounds must be measured from the attached screen; row bounds are not popup bounds. No 320pt assertion.")
            geometry.name = "large-text-real-screen-and-menu-geometry"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        tapCenter(app.buttons["music-completion-mode-\(target)"], named: target)
        assertPausedDetailUnchanged(app, paused, after: "completion \(target)")
        XCTAssertEqual(try completionID(app), target)
        XCTAssertEqual(shuffle.isSelected, initialShuffle)
        XCTAssertEqual(shuffle.value as? String, initialShuffleValue)
        tapCenter(app.buttons["music-completion-mode-menu"], named: "重新打开 completion")
        assertUniqueSelection(app, expected: target)
    }

    @MainActor
    func testShuffleIndependentOfCompletion() throws {
        let app = try launchSyntheticDetail()
        let paused = try pausedDetailSnapshot(app)
        let initial = try completionID(app)
        let shuffle = app.buttons["music-shuffle-toggle"]
        let selected = shuffle.isSelected
        XCTAssertEqual(shuffle.value as? String, selected ? "已选择" : "未选择")
        defer {
            if shuffle.isSelected != selected {
                tapCenter(shuffle, named: "恢复随机播放")
                assertPausedDetailUnchanged(app, paused, after: "恢复随机播放")
            }
            XCTAssertEqual(shuffle.isSelected, selected)
            XCTAssertEqual(shuffle.value as? String, selected ? "已选择" : "未选择")
            record(app, "restored-shuffle")
        }
        tapCenter(shuffle, named: "切换随机播放")
        assertPausedDetailUnchanged(app, paused, after: "切换随机播放")
        XCTAssertEqual(shuffle.isSelected, !selected)
        XCTAssertEqual(shuffle.value as? String, selected ? "未选择" : "已选择")
        XCTAssertEqual(try completionID(app), initial)
        tapCenter(app.buttons["music-completion-mode-menu"], named: "随机切换后 completion")
        assertUniqueSelection(app, expected: initial)
        tapCenter(app.buttons["music-completion-mode-\(initial)"], named: "关闭 completion 菜单")
        assertPausedDetailUnchanged(app, paused, after: "shuffle 后重选初始 completion")
    }

    @MainActor
    func testSleepEndOfTrackPreservesCompletion() throws {
        try exerciseSleep("本曲结束后停止")
    }

    @MainActor
    func testSleepOffPreservesCompletion() throws {
        try exerciseSleep("关闭")
    }

    @MainActor
    func testSleep15MinutesRealSelectionAndRestore() throws {
        try exerciseSleep("15 分钟", minutes: 15)
    }

    @MainActor
    func testSleep30MinutesRealSelectionAndRestore() throws {
        try exerciseSleep("30 分钟", minutes: 30)
    }

    @MainActor
    func testSleep60MinutesRealSelectionAndRestore() throws {
        try exerciseSleep("60 分钟", minutes: 60)
    }

    @MainActor
    func testLargeTextCompletionOptionsReachableAndSelected() throws {
        // A runner acknowledgement, not an app override or proof of actual system size.
        // Parent must attach simctl's readback and restore the previous size (README).
        let size = try XCTUnwrap(ProcessInfo.processInfo.environment["VIVI_SYSTEM_CONTENT_SIZE"])
        guard size == "accessibility-extra-extra-extra-large" else {
            XCTFail("父流程须先设置并记录专用 sim 的系统大字号")
            return
        }
        try exerciseCompletion("repeatOne", recordLargeTextGeometry: true)
    }

    @MainActor
    private func exerciseSleep(_ option: String, minutes: Int? = nil) throws {
        let app = try launchSyntheticDetail()
        let paused = try pausedDetailSnapshot(app)
        let initial = try completionID(app)
        tapCenter(app.buttons["music-player-more-entry"], named: "更多")
        let timer = app.buttons["music-sleep-timer-menu"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let initialStatus = try XCTUnwrap(timer.value as? String)
        let initialOption: String
        switch initialStatus {
        case "睡眠定时：关闭": initialOption = "关闭"
        case "睡眠定时：本曲结束后停止": initialOption = "本曲结束后停止"
        default:
            // A running countdown cannot be restored exactly through the real UI.
            record(app, "unsupported-initial-sleep-state")
            XCTFail("初始睡眠状态无法精确恢复：\(initialStatus)；未更改睡眠设置")
            return
        }
        defer {
            tapCenter(app.buttons["music-player-more-entry"], named: "恢复时打开更多")
            chooseSleep(app, initialOption)
            XCTAssertEqual(timer.value as? String, initialStatus)
            record(app, "restored-sleep")
            tapUnique(app.navigationBars.matching(identifier: "更多").buttons.matching(NSPredicate(format: "label == %@", "完成")),
                      in: app, named: "更多 sheet 完成")
            assertPausedDetailUnchanged(app, paused, after: "恢复 sleep \(initialOption)")
        }
        // Off must be exercised from end-of-track, not merely reselect an off label.
        if option == "关闭" {
            chooseSleep(app, "本曲结束后停止")
            XCTAssertEqual(timer.value as? String, "睡眠定时：本曲结束后停止")
            record(app, "sleep-off-precondition")
            closeMore(app)
            assertPausedDetailUnchanged(app, paused, after: "sleep 关闭前置：本曲结束后停止")
            tapCenter(app.buttons["music-player-more-entry"], named: "前置检查后重开更多")
        }
        chooseSleep(app, option)
        if let minutes {
            assertMinuteStatus(timer, minutes: minutes)
        } else {
            XCTAssertEqual(timer.value as? String, "睡眠定时：\(option)")
        }
        XCTAssertFalse(app.switches["蓝牙车载歌词（实验）"].exists)
        record(app, "sleep-\(option)")
        tapUnique(app.navigationBars.matching(identifier: "更多").buttons.matching(NSPredicate(format: "label == %@", "完成")),
                  in: app, named: "更多 sheet 完成")
        assertPausedDetailUnchanged(app, paused, after: "sleep \(option)")
        XCTAssertEqual(try completionID(app), initial)
        tapCenter(app.buttons["music-completion-mode-menu"], named: "睡眠选择后 completion")
        assertUniqueSelection(app, expected: initial)
        tapCenter(app.buttons["music-completion-mode-\(initial)"], named: "关闭 completion 菜单")
        assertPausedDetailUnchanged(app, paused, after: "sleep 后重选初始 completion")
        if let minutes {
            tapCenter(app.buttons["music-player-more-entry"], named: "重开更多核对分钟定时")
            assertMinuteStatus(timer, minutes: minutes)
            record(app, "reopened-sleep-\(minutes)-minutes")
            closeMore(app)
        }
    }

    @MainActor
    private func assertMinuteStatus(_ timer: XCUIElement, minutes: Int) {
        let status = timer.value as? String ?? ""
        let prefix = "睡眠定时：\(minutes) 分钟（"
        XCTAssertTrue(status.hasPrefix(prefix) && status.hasSuffix("）"), "实际定时状态：\(status)")
        guard status.hasPrefix(prefix), status.hasSuffix("）") else { return }
        let countdown = status.dropFirst(prefix.count).dropLast()
        let fields = countdown.split(separator: ":", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        XCTAssertTrue((fields.count == 2 || fields.count == 3) && numbers.count == fields.count,
                      "倒计时必须是 mm:ss 或 h:mm:ss：\(status)")
        guard (fields.count == 2 || fields.count == 3), numbers.count == fields.count else { return }
        XCTAssertTrue(numbers.allSatisfy { $0 >= 0 })
        XCTAssertLessThan(numbers.last!, 60)
        if numbers.count == 3 { XCTAssertLessThan(numbers[1], 60) }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        XCTAssertGreaterThan(seconds, minutes * 60 - 180, "单项预算内应仍在所选倒计时范围")
        XCTAssertLessThanOrEqual(seconds, minutes * 60)
    }

    @MainActor
    private func closeMore(_ app: XCUIApplication) {
        tapUnique(app.navigationBars.matching(identifier: "更多").buttons.matching(NSPredicate(format: "label == %@", "完成")),
                  in: app, named: "更多 sheet 完成")
    }

    @MainActor
    func testMoreOmitsBluetoothSwitchWithSynchronizedLyrics() throws {
        let app = try launchSyntheticDetail(titleEnvironment: "VIVI_SYNTHETIC_LYRICS_TRACK_TITLE")
        let initialCompletion = try completionID(app)
        let shuffle = app.buttons["music-shuffle-toggle"]
        let initialShuffle = shuffle.isSelected
        let initialShuffleValue = shuffle.value as? String
        tapCenter(app.buttons["music-player-more-entry"], named: "同步歌词歌曲更多")
        let timer = app.buttons["music-sleep-timer-menu"]
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let initialSleep = timer.value as? String
        XCTAssertFalse(app.switches["蓝牙车载歌词（实验）"].exists)
        XCTAssertFalse(app.staticTexts["蓝牙车载歌词（实验）"].exists)
        XCTAssertTrue(app.staticTexts["播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。"].exists)
        XCTAssertFalse(app.staticTexts["当前歌曲无可用同步歌词"].exists)
        record(app, "bluetooth-switch-removed-with-synthetic-lrc")
        closeMore(app)
        XCTAssertEqual(try completionID(app), initialCompletion)
        XCTAssertEqual(shuffle.isSelected, initialShuffle)
        XCTAssertEqual(shuffle.value as? String, initialShuffleValue)
        tapCenter(app.buttons["music-player-more-entry"], named: "重开更多")
        XCTAssertFalse(app.switches["蓝牙车载歌词（实验）"].exists)
        XCTAssertEqual(timer.value as? String, initialSleep)
        closeMore(app)
    }

    @MainActor
    func testMoreOmitsBluetoothSwitchWithoutSynchronizedLyrics() throws {
        let app = try launchSyntheticDetail()
        let initialCompletion = try completionID(app)
        tapCenter(app.buttons["music-player-more-entry"], named: "无同步歌词歌曲更多")
        XCTAssertTrue(app.buttons["music-sleep-timer-menu"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["蓝牙车载歌词（实验）"].exists)
        XCTAssertTrue(app.staticTexts["当前歌曲无可用同步歌词"].exists)
        record(app, "bluetooth-switch-removed-without-synthetic-lrc")
        closeMore(app)
        XCTAssertEqual(try completionID(app), initialCompletion)
        tapCenter(app.buttons["music-player-more-entry"], named: "重开更多")
        XCTAssertFalse(app.switches["蓝牙车载歌词（实验）"].exists)
        closeMore(app)
    }

    @MainActor
    private func chooseSleep(_ app: XCUIApplication, _ label: String) {
        tapCenter(app.buttons["music-sleep-timer-menu"], named: "睡眠定时")
        // No sleep-menu subtree was captured before the failed pause precondition.
        // Require a unique target; capture diagnostics instead of choosing firstMatch.
        tapUnique(app.buttons.matching(NSPredicate(format: "label == %@", label)),
                  in: app, named: "睡眠选项 \(label)")
    }

    @MainActor
    private func completionID(_ app: XCUIApplication) throws -> String {
        let entry = app.buttons["music-completion-mode-menu"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        let value = try XCTUnwrap(entry.value as? String)
        return try XCTUnwrap(modes.first { $0.label == value }?.id,
                             "必须从真实 AX value 读取当前 completion：\(value)")
    }

    @MainActor
    private func assertUniqueSelection(_ app: XCUIApplication, expected: String) {
        var selected: [String] = []
        for mode in modes {
            let option = app.buttons["music-completion-mode-\(mode.id)"]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            XCTAssertTrue(option.isHittable)
            XCTAssertEqual(option.label, mode.label)
            if option.isSelected { selected.append(mode.id) }
        }
        record(app, "reopened-completion-selected-\(selected.joined(separator: "-"))")
        // No inference from label, entry value, expected mode, or checkmark artwork.
        XCTAssertEqual(selected.count, 1, "原生菜单必须暴露唯一 selected 语义；checkmark 不等于 selected")
        XCTAssertEqual(selected, [expected])
    }

    @MainActor
    private func record(_ app: XCUIApplication, _ name: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-AX"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name)-screen"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func launchSyntheticDetail(titleEnvironment: String = "VIVI_SYNTHETIC_TRACK_TITLE") throws -> XCUIApplication {
        // Keep semantic failures visible while allowing real-UI restoration to execute.
        continueAfterFailure = true
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment[titleEnvironment],
                                  "Set TEST_RUNNER_\(titleEnvironment) to the synthetic track's visible title")
        XCTAssertFalse(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let otherEnvironment = titleEnvironment == "VIVI_SYNTHETIC_TRACK_TITLE"
            ? "VIVI_SYNTHETIC_LYRICS_TRACK_TITLE" : "VIVI_SYNTHETIC_TRACK_TITLE"
        let otherTitle = try XCTUnwrap(ProcessInfo.processInfo.environment[otherEnvironment],
                                       "Set TEST_RUNNER_\(otherEnvironment) to the other synthetic track's visible title")
        guard !otherTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              otherTitle != title else {
            XCTFail("重置 fixture 必须提供另一首非空且不同标题的合成歌曲")
            throw NSError(domain: "MusicMenuFixture", code: 1)
        }
        let app = XCUIApplication(bundleIdentifier: "com.example.DrivePlayer")
        app.launch()
        tapCenter(app.tabBars.buttons["音乐"], named: "音乐 tab")
        let library = app.descendants(matching: .any)["music-library-filter"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10), "真实音乐页未出现")

        // Same-item taps resume the saved position. Select the other fixture through
        // its real row first so the target is installed fresh, even across a long suite.
        let otherRowTitle = app.cells.staticTexts.matching(NSPredicate(format: "label == %@", otherTitle)).firstMatch
        tapCenter(otherRowTitle, named: "重置播放位置前先选择另一首合成歌曲")
        // The song row is inside the list; the root mini is outside the list.
        let titlePredicate = NSPredicate(format: "label CONTAINS %@", title)
        let rowTitle = app.cells.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch
        tapCenter(rowTitle, named: "合成歌曲行标题")
        // Assert selection immediately, before any mini wait or detail-entry tap.
        // Locate the production title independently of the expected fixture label;
        // library row buttons span past the playback control and are not the mini.
        let selectionControl = app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["pause.fill", "play.fill"])).firstMatch
        XCTAssertTrue(selectionControl.exists, "歌曲行点击后必须立即出现生产 mini 主控")
        if selectionControl.exists {
            let controlFrame = selectionControl.frame
            let tabTop = app.tabBars.firstMatch.frame.minY
            let selectionButtons = app.buttons.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return $0.isHittable && abs(frame.midY - controlFrame.midY) < 30
                    && frame.maxY <= tabTop && frame.maxX <= controlFrame.minX
            }
            XCTAssertEqual(selectionButtons.count, 1, "歌曲行点击后生产 mini 标题按钮必须唯一")
            if let selectedMini = selectionButtons.first, selectionButtons.count == 1 {
                XCTAssertEqual(selectedMini.label, title,
                               "歌曲行点击后生产 mini 必须立即显示所选 fixture，不能保留或切换到另一首歌")
            }
        }
        // Locate the mini title next to its dedicated playback control. At large
        // accessibility sizes the library row may extend beneath the mini.
        let miniQuery = app.buttons.matching(titlePredicate)
        let miniControl = app.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["pause.fill", "play.fill"])).firstMatch
        XCTAssertTrue(miniControl.waitForExistence(timeout: 10))
        let miniReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            miniQuery.allElementsBoundByIndex.filter {
                $0.isHittable && abs($0.frame.midY - miniControl.frame.midY) < 30
                    && $0.frame.maxY <= app.tabBars.firstMatch.frame.minY
            }.count == 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [miniReady], timeout: 10), .completed,
                       "须唯一定位 mini 主控旁、tab 上方的真实 mini 标题按钮")
        let miniButton = try XCTUnwrap(miniQuery.allElementsBoundByIndex.first {
            $0.isHittable && abs($0.frame.midY - miniControl.frame.midY) < 30
                && $0.frame.maxY <= app.tabBars.firstMatch.frame.minY
        })
        tapCenter(miniButton, named: "mini 详情入口")
        XCTAssertTrue(app.buttons["music-completion-mode-menu"].waitForExistence(timeout: 10))
        // The captured detail AX has pause.circle.fill; pause.fill belongs to the mini.
        let detail = app.windows.children(matching: .other)
            .containing(.navigationBar, identifier: "正在播放")
        let controls = detail.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["pause.circle.fill", "play.circle.fill"]))
        let control = try XCTUnwrap(uniqueTarget(controls, in: app, named: "详情播放主控"))
        let wasPlaying = control.identifier == "pause.circle.fill"
        if wasPlaying { tapCenter(control, named: "暂停合成歌曲以避免 120 秒自然结束") }
        addTeardownBlock { @MainActor in
            defer { self.record(app, "action-test-final") }
            if wasPlaying {
                let control = try XCTUnwrap(self.uniqueTarget(controls, in: app, named: "恢复时详情播放主控"))
                if control.identifier == "play.circle.fill" {
                    self.tapCenter(control, named: "恢复进入详情时的播放状态")
                }
            }
        }
        let pausedReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controls.count == 1 && controls.element.identifier == "play.circle.fill"
                && controls.element.label == "播放" && controls.element.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pausedReady], timeout: 3), .completed,
                       "真实暂停后详情主控必须变为播放；不能由 teardown 接受意外恢复")
        XCTAssertEqual(detail.staticTexts.matching(NSPredicate(format: "label == %@", title)).count, 1,
                       "菜单断言前已暂停的详情必须显示目标 fixture 标题，不能保留或切换到另一首歌")
        record(app, "action-test-initial")
        return app
    }

    private struct PausedDetailSnapshot {
        let title: String
        let progress: String
    }

    @MainActor
    private func pausedDetailSnapshot(_ app: XCUIApplication) throws -> PausedDetailSnapshot {
        let title = try XCTUnwrap(ProcessInfo.processInfo.environment["VIVI_SYNTHETIC_TRACK_TITLE"])
        let detail = app.windows.children(matching: .other)
            .containing(.navigationBar, identifier: "正在播放")
        // The production footer has one native Slider and no custom progress identifier.
        // Compare its actual AX value without inventing seconds or a percent conversion.
        guard detail.sliders.count == 1,
              let progress = detail.sliders.element.value as? String,
              !progress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              progress.rangeOfCharacter(from: .decimalDigits) != nil else {
            record(app, "paused-progress-AX-blocker")
            XCTFail("BLOCKER：详情唯一 Slider 未公开可观察数值进度；不得用 setter 或预期值替代")
            throw NSError(domain: "MusicMenuProgressAX", code: 1)
        }
        let snapshot = PausedDetailSnapshot(title: title, progress: progress)
        assertPausedDetailUnchanged(app, snapshot, after: "真实暂停后的基线")
        return snapshot
    }

    @MainActor
    private func assertPausedDetailUnchanged(_ app: XCUIApplication, _ baseline: PausedDetailSnapshot,
                                            after action: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let detail = app.windows.children(matching: .other)
            .containing(.navigationBar, identifier: "正在播放")
        let controls = detail.buttons.matching(NSPredicate(
            format: "identifier IN %@", ["pause.circle.fill", "play.circle.fill"]))
        let titles = detail.staticTexts.matching(NSPredicate(format: "label == %@", baseline.title))
        let sliders = detail.sliders
        XCTAssertEqual(controls.count, 1, "\(action)：详情主控须唯一", file: file, line: line)
        XCTAssertEqual(titles.count, 1, "\(action)：须仍为同一合成歌曲标题", file: file, line: line)
        XCTAssertEqual(sliders.count, 1, "\(action)：BLOCKER：详情进度须可观察且唯一", file: file, line: line)
        guard controls.count == 1, titles.count == 1, sliders.count == 1 else {
            record(app, "paused-detail-AX-blocker")
            return
        }
        XCTAssertEqual(controls.element.identifier, "play.circle.fill", "\(action)：须保持暂停", file: file, line: line)
        XCTAssertEqual(controls.element.label, "播放", "\(action)：须保持暂停", file: file, line: line)
        XCTAssertEqual(sliders.element.value as? String, baseline.progress,
                       "\(action)：实际 AX 进度不得变化", file: file, line: line)
        // Observe for two seconds, rather than succeeding at the first paused snapshot.
        // More must already be closed so the detail timeline is active again.
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            controls.count != 1 || titles.count != 1 || sliders.count != 1
                || controls.element.identifier != "play.circle.fill"
                || controls.element.label != "播放"
                || (sliders.element.value as? String) != baseline.progress
        }, object: nil)
        changed.isInverted = true
        let result = XCTWaiter.wait(for: [changed], timeout: 2)
        XCTAssertEqual(result, .completed, "\(action)：2 秒观察内暂停/同曲/AX 进度必须保持", file: file, line: line)
        record(app, "paused-detail-after-\(action)")
    }

    private var recordedQueryFailure = false

    @MainActor
    private func uniqueTarget(_ query: XCUIElementQuery, in app: XCUIApplication, named name: String,
                              file: StaticString = #filePath, line: UInt = #line) -> XCUIElement? {
        let count = query.count
        guard count == 1 else {
            recordQueryFailure(app, name)
            XCTFail("\(name) 必须唯一匹配，实际 \(count) 个", file: file, line: line)
            return nil
        }
        let target = query.element
        guard target.isHittable else {
            recordQueryFailure(app, name)
            XCTFail("\(name) 唯一 target 不可交互", file: file, line: line)
            return nil
        }
        return target
    }

    @MainActor
    private func recordQueryFailure(_ app: XCUIApplication, _ name: String) {
        guard !recordedQueryFailure else { return }
        recordedQueryFailure = true
        record(app, "ambiguous-or-unreachable-\(name)")
    }

    @MainActor
    private func tapUnique(_ query: XCUIElementQuery, in app: XCUIApplication, named name: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        guard let target = uniqueTarget(query, in: app, named: name, file: file, line: line) else { return }
        tapCenter(target, named: name, file: file, line: line)
    }

    @MainActor
    private func tapCenter(_ element: XCUIElement, named name: String,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "未找到 \(name)", file: file, line: line)
        XCTAssertTrue(element.isHittable, "不可点击 \(name)", file: file, line: line)
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
