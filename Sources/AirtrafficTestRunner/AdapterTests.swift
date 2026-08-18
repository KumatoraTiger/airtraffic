import AirtrafficCore
import Foundation

/// All fixtures are generated in temp directories with fictional data.
/// Never commit real transcripts: they may contain personal information.
final class AdapterTests {
    let now = Date()
    private var tempDir: URL!

    private func setUp() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("airtraffic-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    private func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func iso(_ secondsAgo: TimeInterval) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-secondsAgo))
    }

    /// Codex shards sessions into YYYY/MM/DD directories; the adapter only walks
    /// days inside the lookback window, so fixtures must live under today's shard.
    private func codexShardPath(_ fileName: String) -> URL {
        let parts = Calendar(identifier: .gregorian)
            .dateComponents([.year, .month, .day], from: now)
        return
            tempDir
            .appendingPathComponent(String(format: "%04d", parts.year ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.month ?? 0))
            .appendingPathComponent(String(format: "%02d", parts.day ?? 0))
            .appendingPathComponent(fileName)
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Claude Code fixtures

    private func claudeUserLine(_ text: String, secondsAgo: TimeInterval) -> String {
        """
        {"type":"user","sessionId":"s-1","cwd":"/Users/alex/src/demo","timestamp":"\(iso(secondsAgo))","message":{"role":"user","content":"\(text)"}}
        """
    }

    private func claudeAssistantLine(
        _ text: String, secondsAgo: TimeInterval, toolUse: String? = nil
    ) -> String {
        var blocks = ["{\"type\":\"text\",\"text\":\"\(text)\"}"]
        if let toolUse { blocks.append(toolUse) }
        return """
            {"type":"assistant","sessionId":"s-1","cwd":"/Users/alex/src/demo","timestamp":"\(iso(secondsAgo))","message":{"role":"assistant","content":[\(blocks.joined(separator: ","))]}}
            """
    }

    // MARK: - Tests

    func runAll() async {
        await TestKit.shared.run("claudeCode: parses session and todos") { [self] in
            try setUp()
            defer { tearDown() }
            let file = tempDir.appendingPathComponent("proj/s-1.jsonl")
            let todoToolUse = """
                {"type":"tool_use","id":"tu-1","name":"TodoWrite","input":{"todos":[{"content":"fix login bug","status":"completed"},{"content":"add tests","status":"in_progress"}]}}
                """
            try write(
                [
                    claudeUserLine("please fix the login bug", secondsAgo: 300),
                    claudeAssistantLine("working on it", secondsAgo: 290, toolUse: todoToolUse),
                    """
                    {"type":"user","sessionId":"s-1","timestamp":"\(iso(280))","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu-1"}]}}
                    """,
                    claudeAssistantLine("done, waiting for your review", secondsAgo: 120),
                ], to: file)

            let adapter = ClaudeCodeAdapter(root: tempDir, config: .default)
            let snapshots = try adapter.scan(now: now)
            expectEqual(snapshots.count, 1)
            let session = try unwrap(snapshots.first)
            expectEqual(session.id, "claude:s-1")
            expectEqual(session.cwd, "/Users/alex/src/demo")
            expectEqual(session.title, "please fix the login bug")
            expectEqual(session.todos.count, 2)
            expectEqual(session.todos.last?.status, .inProgress)
            // Last event is an assistant turn end 120s ago: waiting for user input.
            expectEqual(session.status, .waitingInput)
        }

        await TestKit.shared.run("claudeCode: pending tool_use means waitingApproval") { [self] in
            try setUp()
            defer { tearDown() }
            let file = tempDir.appendingPathComponent("proj/s-1.jsonl")
            let pendingTool = """
                {"type":"tool_use","id":"tu-9","name":"Bash","input":{"command":"make clean"}}
                """
            try write(
                [
                    claudeUserLine("clean the build dir", secondsAgo: 200),
                    claudeAssistantLine("running", secondsAgo: 190, toolUse: pendingTool),
                ], to: file)
            let adapter = ClaudeCodeAdapter(root: tempDir, config: .default)
            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.status, .waitingApproval)
        }

        await TestKit.shared.run("claudeCode: incremental scan picks up appended lines") { [self] in
            try setUp()
            defer { tearDown() }
            let file = tempDir.appendingPathComponent("proj/s-1.jsonl")
            try write([claudeUserLine("first message", secondsAgo: 300)], to: file)

            let adapter = ClaudeCodeAdapter(root: tempDir, config: .default)
            _ = try adapter.scan(now: now)

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((claudeUserLine("second message", secondsAgo: 10) + "\n").utf8))
            try handle.close()

            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.lastUserText, "second message")
            expectEqual(session.status, .running)
        }

        await TestKit.shared.run("claudeCode: skips sidechains") { [self] in
            try setUp()
            defer { tearDown() }
            let file = tempDir.appendingPathComponent("proj/s-2.jsonl")
            try write(
                [
                    """
                    {"type":"user","sessionId":"s-2","isSidechain":true,"timestamp":"\(iso(100))","message":{"role":"user","content":"subagent prompt"}}
                    """
                ], to: file)
            let adapter = ClaudeCodeAdapter(root: tempDir, config: .default)
            expect(try adapter.scan(now: now).isEmpty, "sidechain session should be skipped")
        }

        await TestKit.shared.run("claudeCode: old session is idle") { [self] in
            try setUp()
            defer { tearDown() }
            let file = tempDir.appendingPathComponent("proj/s-1.jsonl")
            try write(
                [
                    claudeUserLine("old question", secondsAgo: 6 * 3600),
                    claudeAssistantLine("old answer", secondsAgo: 6 * 3600 - 10),
                ], to: file)
            let adapter = ClaudeCodeAdapter(root: tempDir, config: .default)
            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.status, .idle)
        }

        await TestKit.shared.run("codex: parses session, plan, and status") { [self] in
            try setUp()
            defer { tearDown() }
            let file = codexShardPath("rollout-1.jsonl")
            let planArguments =
                "{\\\"plan\\\":[{\\\"step\\\":\\\"survey code\\\",\\\"status\\\":\\\"completed\\\"},{\\\"step\\\":\\\"write patch\\\",\\\"status\\\":\\\"in_progress\\\"}]}"
            try write(
                [
                    """
                    {"timestamp":"\(iso(400))","type":"session_meta","payload":{"id":"c-1","cwd":"/Users/alex/src/demo"}}
                    """,
                    """
                    {"timestamp":"\(iso(390))","type":"event_msg","payload":{"type":"user_message","message":"refactor the parser"}}
                    """,
                    """
                    {"timestamp":"\(iso(380))","type":"event_msg","payload":{"type":"task_started"}}
                    """,
                    """
                    {"timestamp":"\(iso(370))","type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"\(planArguments)"}}
                    """,
                    """
                    {"timestamp":"\(iso(360))","type":"response_item","payload":{"type":"function_call_output","output":"ok"}}
                    """,
                    """
                    {"timestamp":"\(iso(350))","type":"event_msg","payload":{"type":"task_complete"}}
                    """,
                    """
                    {"timestamp":"\(iso(340))","type":"event_msg","payload":{"type":"agent_message","message":"patch ready for review"}}
                    """,
                ], to: file)

            let adapter = CodexAdapter(root: tempDir, config: .default)
            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.id, "codex:c-1")
            expectEqual(session.title, "refactor the parser")
            expectEqual(session.todos.map(\.content), ["survey code", "write patch"])
            expectEqual(session.lastAssistantText, "patch ready for review")
            expectEqual(session.status, .waitingInput)
        }

        await TestKit.shared.run("codex: skips subagent rollouts") { [self] in
            try setUp()
            defer { tearDown() }
            let file = codexShardPath("rollout-2.jsonl")
            try write(
                [
                    """
                    {"timestamp":"\(iso(100))","type":"session_meta","payload":{"id":"c-2","cwd":"/tmp","thread_source":"subagent","source":{"subagent":{"other":"judge"}}}}
                    """
                ], to: file)
            let adapter = CodexAdapter(root: tempDir, config: .default)
            expect(try adapter.scan(now: now).isEmpty, "subagent rollout should be skipped")
        }

        await TestKit.shared.run("grok: live session waits for input") { [self] in
            try setUp()
            defer { tearDown() }
            try makeGrokSession(id: "g-1", updatedSecondsAgo: 300, summary: "Review PR 42")
            try writeGrokActive(sessionId: "g-1")
            let adapter = GrokAdapter(home: tempDir, config: .default, isProcessAlive: { _ in true })
            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.id, "grok:g-1")
            expectEqual(session.title, "Review PR 42")
            expectEqual(session.status, .waitingInput)
            expectEqual(session.lastAssistantText, "確認待ち")
        }

        await TestKit.shared.run("grok: dead process means idle") { [self] in
            try setUp()
            defer { tearDown() }
            try makeGrokSession(id: "g-2", updatedSecondsAgo: 300, summary: "Old work")
            try writeGrokActive(sessionId: "g-2")
            let adapter = GrokAdapter(home: tempDir, config: .default, isProcessAlive: { _ in false })
            let session = try unwrap(try adapter.scan(now: now).first)
            expectEqual(session.status, .idle)
        }

        await TestKit.shared.run("statusResolver: ordering") { [self] in
            let config = ScanConfig.default
            expectEqual(
                StatusResolver.resolve(
                    lastActivity: now.addingTimeInterval(-10), lastRoleIsAssistant: false,
                    hasPendingToolUse: false, now: now, config: config), .running)
            expectEqual(
                StatusResolver.resolve(
                    lastActivity: now.addingTimeInterval(-100), lastRoleIsAssistant: true,
                    hasPendingToolUse: true, now: now, config: config), .waitingApproval)
            expectEqual(
                StatusResolver.resolve(
                    lastActivity: now.addingTimeInterval(-100), lastRoleIsAssistant: true,
                    hasPendingToolUse: false, now: now, config: config), .waitingInput)
            expectEqual(
                StatusResolver.resolve(
                    lastActivity: now.addingTimeInterval(-5 * 3600), lastRoleIsAssistant: true,
                    hasPendingToolUse: false, now: now, config: config), .idle)
        }
    }

    // MARK: - Grok fixtures

    private func makeGrokSession(
        id: String, updatedSecondsAgo: TimeInterval, summary: String
    ) throws {
        let dir = tempDir.appendingPathComponent("sessions/%2FUsers%2Falex/\(id)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let summaryJSON = """
            {"info":{"id":"\(id)","cwd":"/Users/alex/src/demo"},"session_summary":"\(summary)","updated_at":"\(iso(updatedSecondsAgo))","last_turn_summary":"確認待ち"}
            """
        try summaryJSON.write(
            to: dir.appendingPathComponent("summary.json"),
            atomically: true, encoding: .utf8)
        try write(
            [
                #"{"type":"user","content":"review PR 42"}"#,
                #"{"type":"assistant","content":"looked at the diff"}"#,
            ], to: dir.appendingPathComponent("chat_history.jsonl"))
    }

    private func writeGrokActive(sessionId: String) throws {
        let active = """
            [{"session_id":"\(sessionId)","pid":12345,"cwd":"/Users/alex","opened_at":"\(iso(4000))"}]
            """
        try active.write(
            to: tempDir.appendingPathComponent("active_sessions.json"),
            atomically: true, encoding: .utf8)
    }
}
