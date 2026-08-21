import XCTest

/// Preferences for a test, held in memory.
///
/// `swift test` was leaving a plist per suite per run in `~/Library/Preferences`. On the machine
/// this was found on there were 11,029 of them — 92% of everything in that folder — in two flavours:
/// twenty-two call sites removed their domain and still left a 42-byte husk, because emptying a
/// domain does not delete its file, and eleven more removed nothing at all and left the test's own
/// data sitting in the user's preferences.
///
/// Removing the file after each test is not enough and was measured not to be: the preferences
/// daemon holds the suite and writes it back out on its own schedule, after the test that removed it
/// and after the process that made it. Sweeping again when the bundle finished still left 33 to 61
/// files a run. So a test is given no suite at all — nothing on disk means nothing to clean up.
///
/// `object`, `set` and `removeObject` are the primitives every other accessor is documented to funnel
/// through, which is why overriding these three is enough for `data(forKey:)`, `integer(forKey:)` and
/// the rest. `TestDefaultsHygieneTests` checks that rather than trusting it.
final class InMemoryDefaults: UserDefaults {
    private var storage: [String: Any] = [:]
    private let lock = NSLock()

    override init?(suiteName: String?) {
        super.init(suiteName: nil)
    }

    override func object(forKey key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    override func set(_ value: Any?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    override func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    override func synchronize() -> Bool { true }
}

extension XCTestCase {
    /// Preferences a test can write to freely, backed by memory rather than by a file in the user's
    /// home. The name is kept only so a failure reads like the suite it replaced.
    func makeTestDefaults(
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> UserDefaults {
        guard let defaults = InMemoryDefaults(suiteName: name) else {
            XCTFail("could not make in-memory defaults for \(name)", file: file, line: line)
            return .standard
        }
        return defaults
    }
}

/// Keeps the leak from coming back one call site at a time.
final class TestDefaultsHygieneTests: XCTestCase {
    /// Opening a suite directly is what left those 11,029 files. The helper exists so a test cannot
    /// forget; asserting it keeps the helper the only door.
    func testNoTestOpensAPreferencesSuiteDirectly() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sources = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "TestDefaults.swift" }
        XCTAssertGreaterThan(sources.count, 10)

        for source in sources {
            let body = try String(contentsOf: source, encoding: .utf8)
            XCTAssertFalse(
                body.contains("UserDefaults(suiteName:"),
                "\(source.lastPathComponent) opens a preferences suite directly — use makeTestDefaults"
            )
        }
    }

    /// The whole point: a test writes preferences and the user's home is untouched.
    func testWritingPreferencesLeavesNothingOnDisk() throws {
        let before = try plistCount()
        let defaults = makeTestDefaults("TokenPilotHygieneProbe")

        defaults.set(Data("payload".utf8), forKey: "blob")
        defaults.set(42, forKey: "answer")
        _ = defaults.synchronize()

        XCTAssertEqual(try plistCount(), before, "a test must not add files to ~/Library/Preferences")
    }

    /// The three overridden primitives have to carry every typed accessor the app uses, or a store
    /// would silently read through to the real preferences. Checked rather than assumed.
    func testTheTypedAccessorsAllGoThroughTheOverriddenPrimitives() {
        let defaults = makeTestDefaults("TokenPilotAccessorProbe")

        defaults.set(Data("payload".utf8), forKey: "blob")
        defaults.set(42, forKey: "answer")
        defaults.set(true, forKey: "flag")
        defaults.set("text", forKey: "words")

        XCTAssertEqual(defaults.data(forKey: "blob"), Data("payload".utf8))
        XCTAssertEqual(defaults.integer(forKey: "answer"), 42)
        XCTAssertTrue(defaults.bool(forKey: "flag"))
        XCTAssertEqual(defaults.string(forKey: "words"), "text")
        XCTAssertEqual(defaults.object(forKey: "answer") as? Int, 42)

        defaults.removeObject(forKey: "answer")
        XCTAssertNil(defaults.object(forKey: "answer"))
        XCTAssertEqual(defaults.integer(forKey: "answer"), 0)
    }

    /// Two tests must not see each other's values, and neither may reach the real preferences.
    func testEachTestGetsItsOwnPreferences() {
        let first = makeTestDefaults("TokenPilotIsolationProbe")
        let second = makeTestDefaults("TokenPilotIsolationProbe")

        first.set("mine", forKey: "shared-key")

        XCTAssertNil(second.object(forKey: "shared-key"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "shared-key"))
    }

    private func plistCount() throws -> Int {
        let preferences = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
        return try FileManager.default
            .contentsOfDirectory(at: preferences, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "plist" }
            .count
    }
}
