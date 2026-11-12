import XCTest
@testable import WickbarCore

final class ConfigTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("wickbar-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRoundTrip() throws {
        let config = ConfigFile(
            settings: AppSettings(autoStartOnLaunch: false, mcpEnabled: true, mcpPort: 9500, restoreAfterCrash: .always),
            commands: [
                CommandConfig(name: "api", command: "npm run dev", workingDirectory: "~/code/api",
                              environment: ["PORT": "3000", "A": "b=c"], autoStart: true, restartPolicy: .always),
                CommandConfig(name: "tunnel", command: "tailscale serve 3000", restartPolicy: .never),
            ])
        let data = try config.encoded()
        let decoded = try ConfigFile.decode(data)
        XCTAssertEqual(decoded, config)
    }

    func testEncodingIsPrettyAndSorted() throws {
        let config = ConfigFile(commands: [CommandConfig(name: "x", command: "y")])
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        XCTAssertTrue(text.contains("\n  \"commands\""))
        // sorted keys: "commands" before "settings"; inside settings autoStartOnLaunch < mcpEnabled < mcpPort < restoreAfterCrash
        XCTAssertLessThan(text.range(of: "\"commands\"")!.lowerBound, text.range(of: "\"settings\"")!.lowerBound)
        XCTAssertLessThan(text.range(of: "\"mcpEnabled\"")!.lowerBound, text.range(of: "\"restoreAfterCrash\"")!.lowerBound)
        XCTAssertTrue(text.contains("\"restartPolicy\" : \"onFailure\""))
    }

    func testDecodesSpecExample() throws {
        let json = """
        {
          "settings": { "autoStartOnLaunch": true, "mcpEnabled": true, "mcpPort": 9425, "restoreAfterCrash": "ask" },
          "commands": [
            { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "name": "kanzo", "command": "kanzo", "workingDirectory": "~",
              "environment": {"KEY": "VALUE"}, "autoStart": true, "restartPolicy": "onFailure" }
          ]
        }
        """
        let c = try ConfigFile.decode(Data(json.utf8))
        XCTAssertEqual(c.settings, AppSettings())
        XCTAssertEqual(c.commands.count, 1)
        XCTAssertEqual(c.commands[0].id.uuidString, "6F9619FF-8B86-D011-B42D-00C04FC964FF")
        XCTAssertEqual(c.commands[0].environment, ["KEY": "VALUE"])
        XCTAssertEqual(c.commands[0].restartPolicy, .onFailure)
    }

    func testLenientDecodingFillsDefaults() throws {
        let c = try ConfigFile.decode(Data(#"{"commands":[{"command":"sleep 10"}]}"#.utf8))
        XCTAssertEqual(c.settings, AppSettings())
        XCTAssertEqual(c.commands[0].name, "sleep 10")
        XCTAssertEqual(c.commands[0].workingDirectory, "~")
        XCTAssertEqual(c.commands[0].restartPolicy, .onFailure)
        XCTAssertFalse(c.commands[0].autoStart)
    }

    func testInvalidPortFallsBackToDefault() throws {
        let c = try ConfigFile.decode(Data(#"{"settings":{"mcpPort":99999}}"#.utf8))
        XCTAssertEqual(c.settings.mcpPort, 9425)
    }

    func testStoreCreatesEmptyConfigAndSavesAtomically() throws {
        let store = ConfigStore(directory: tempDir)
        let initial = try store.loadOrCreate()
        XCTAssertEqual(initial, ConfigFile())
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.configURL.path))

        var updated = initial
        updated.commands.append(CommandConfig(name: "a", command: "b"))
        let written = try store.save(updated)
        XCTAssertEqual(store.rawData(), written)
        XCTAssertEqual(try store.load(), updated)
    }

    func testRuntimeStateRoundTrip() {
        let store = RuntimeStateStore(directory: tempDir)
        XCTAssertNil(store.load())
        let id = UUID()
        store.save(RuntimeState(cleanShutdown: false, runningIds: [id]))
        XCTAssertEqual(store.load(), RuntimeState(cleanShutdown: false, runningIds: [id]))
    }

    func testTildeExpansion() {
        XCTAssertEqual(CommandConfig.expandTilde("~", home: "/Users/me"), "/Users/me")
        XCTAssertEqual(CommandConfig.expandTilde("", home: "/Users/me"), "/Users/me")
        XCTAssertEqual(CommandConfig.expandTilde("~/code", home: "/Users/me"), "/Users/me/code")
        XCTAssertEqual(CommandConfig.expandTilde("/tmp", home: "/Users/me"), "/tmp")
    }

    func testRuntimeDiffers() {
        let a = CommandConfig(name: "a", command: "x")
        var b = a
        b.name = "renamed"
        b.autoStart = true
        b.restartPolicy = .always
        XCTAssertFalse(b.runtimeDiffers(from: a))
        b.environment = ["K": "V"]
        XCTAssertTrue(b.runtimeDiffers(from: a))
    }

    func testEnvironmentText() {
        let env = EnvironmentText.parse("A=1\n# comment\n\nexport B = two=2\nbad line\nC=")
        XCTAssertEqual(env, ["A": "1", "B": " two=2", "C": ""])
        XCTAssertEqual(EnvironmentText.format(["B": "2", "A": "1"]), "A=1\nB=2")
    }
}
