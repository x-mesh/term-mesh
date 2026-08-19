import XCTest

#if canImport(term_mesh_DEV)
@testable import term_mesh_DEV
#elseif canImport(term_mesh)
@testable import term_mesh
#endif

/// The redactor is the only thing standing between a diagnostics bundle and a
/// public issue tracker, so these tests care about two failure directions
/// equally: leaking something identifying, and mangling something that was
/// never sensitive. The second is easy to overlook and just as damaging — a
/// version string eaten by an over-eager IP pattern sends the reader chasing a
/// defect the redactor invented.
@MainActor
final class DiagnosticsRedactorTests: XCTestCase {
    private func makeRedactor(
        home: String = "/Users/testuser",
        user: String = "testuser",
        localHost: String = "test-macbook.local",
        seedHosts: [String] = []
    ) -> DiagnosticsRedactor {
        DiagnosticsRedactor(
            homeDirectory: home,
            userName: user,
            localHostName: localHost,
            seedHosts: seedHosts
        )
    }

    // MARK: - Host aliasing

    /// The same machine reached three ways is one machine. If each spelling
    /// got its own alias the bundle would read as a three-host deployment,
    /// which is precisely the misreading that costs an investigation its first
    /// hour.
    func test_sameHostGetsOneAliasAcrossSpellings() {
        let redactor = makeRedactor()
        let output = redactor.redact(
            """
            ssh root@203.0.113.10
            control 203.0.113.10:22
            peer 203.0.113.10
            """
        )
        XCTAssertFalse(output.contains("203.0.113.10"))
        XCTAssertEqual(output.components(separatedBy: "<host-1>").count - 1, 3)
        XCTAssertFalse(output.contains("<host-2>"))
    }

    /// Two different hosts must stay distinguishable — aliasing removes the
    /// name, not the fact that these are separate machines.
    func test_distinctHostsGetDistinctAliases() {
        let redactor = makeRedactor()
        let output = redactor.redact("a=203.0.113.10 b=198.51.100.7")
        XCTAssertTrue(output.contains("<host-1>"))
        XCTAssertTrue(output.contains("<host-2>"))
    }

    /// Seeding fixes the numbering to the caller's order (the peer host list)
    /// rather than to whichever section happened to mention a host first.
    func test_seedOrderDeterminesAliasNumbering() {
        let redactor = makeRedactor(seedHosts: ["198.51.100.7", "203.0.113.10"])
        let output = redactor.redact("first mention 203.0.113.10 then 198.51.100.7")
        XCTAssertTrue(output.contains("<host-2>"))
        XCTAssertTrue(output.contains("<host-1>"))
        // The seeded first host keeps alias 1 even though it appears second.
        XCTAssertTrue(output.hasSuffix("<host-1>"))
    }

    /// A seeded short hostname that is a suffix of a longer one must not be
    /// substituted inside it, or the long name ends up spliced
    /// (`api.<host-1>`) and still carries the identifying prefix.
    func test_longerHostNameIsReplacedBeforeItsSuffix() {
        let redactor = makeRedactor(seedHosts: ["example.com", "api.example.com"])
        let output = redactor.redact("host api.example.com")
        XCTAssertFalse(output.contains("api.<host-"))
        XCTAssertFalse(output.contains("example.com"))
    }

    /// Aliasing the host is only half the job — `alice@<host-1>` still names
    /// a person.
    func test_personalAccountOnAnAliasedHostIsRedacted() {
        let redactor = makeRedactor()
        let output = redactor.redact("ssh alice@203.0.113.10")
        XCTAssertFalse(output.contains("alice"))
        XCTAssertEqual(output, "ssh <user>@<host-1>")
    }

    /// `root` names a role, not a person, and "runs as root" is the signal
    /// that separates a system-scope install from a user-scope one — the
    /// exact distinction a peer-host report is read for.
    func test_systemAccountSurvivesOnAnAliasedHost() {
        let redactor = makeRedactor()
        let output = redactor.redact("ssh root@203.0.113.10")
        XCTAssertEqual(output, "ssh root@<host-1>")
    }

    /// The account rule anchors on an alias the redactor just emitted, so an
    /// ordinary `@` elsewhere in the bundle is untouched.
    func test_unrelatedAtSignIsUntouched() {
        let redactor = makeRedactor()
        let output = redactor.redact("selector foo@bar baz")
        XCTAssertEqual(output, "selector foo@bar baz")
    }

    func test_localHostNameIsRedacted() {
        let redactor = makeRedactor(localHost: "test-macbook.local")
        let output = redactor.redact("running on test-macbook.local")
        XCTAssertEqual(output, "running on <local-host>")
    }

    // MARK: - What must survive

    /// Loopback names no machine, and "the daemon listened on localhost"
    /// versus "on a routable address" is a distinction reports are read for.
    func test_loopbackSurvives() {
        let redactor = makeRedactor()
        let output = redactor.redact("bound 127.0.0.1:7777 and 0.0.0.0")
        XCTAssertTrue(output.contains("127.0.0.1"))
        XCTAssertTrue(output.contains("0.0.0.0"))
    }

    /// Three dotted components are a version, four are an address. Eating
    /// versions would strip the single most useful field in a bug report.
    func test_versionStringsSurvive() {
        let redactor = makeRedactor()
        let output = redactor.redact("App: 0.196.0 (264), daemon 0.196.0")
        XCTAssertTrue(output.contains("0.196.0"))
        XCTAssertTrue(output.contains("(264)"))
    }

    /// A short account name appears inside ordinary words. Substituting it
    /// globally would corrupt the bundle, so the redactor leaves it alone —
    /// a named short account is less harmful than an unreadable report.
    func test_shortUserNameIsLeftAlone() {
        let redactor = makeRedactor(home: "/Users/ci", user: "ci")
        // "specific" and "decision" both contain the account name as a
        // substring; a naive global swap would rewrite them into nonsense.
        let output = redactor.redact("specific decision for ci")
        XCTAssertEqual(output, "specific decision for ci")
    }

    // MARK: - Identity

    func test_homeDirectoryBecomesTilde() {
        let redactor = makeRedactor(home: "/Users/testuser", user: "testuser")
        let output = redactor.redact("log at /Users/testuser/Library/Logs/tm.log")
        XCTAssertEqual(output, "log at ~/Library/Logs/tm.log")
    }

    /// A username outside the home path — an ssh target, a `User=` directive —
    /// still has to go.
    func test_userNameOutsideHomePathIsRedacted() {
        let redactor = makeRedactor(home: "/Users/testuser", user: "testuser")
        let output = redactor.redact("User=testuser")
        XCTAssertEqual(output, "User=<user>")
    }

    // MARK: - Credentials

    /// The credential rules are `AgentSession`'s and are tested there; what
    /// this asserts is that the diagnostics path actually runs them. A bundle
    /// that skipped this step would look perfectly fine in every other test.
    func test_credentialsAreRedactedThroughThePipeline() {
        let redactor = makeRedactor()
        let output = redactor.redact("token=ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        XCTAssertFalse(output.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    /// Credentials run before host aliasing precisely so a secret embedded in
    /// a URI cannot be reshaped by the host rules into something the token
    /// patterns no longer recognise.
    func test_credentialInsideHostURIIsRemovedAndHostAliased() {
        let redactor = makeRedactor()
        // Deliberately not written as `url=…`: that key matches the sensitive
        // environment rule, which swallows the whole value and would make this
        // test pass without the URI and host rules ever running.
        let output = redactor.redact("endpoint https://admin:hunter2@203.0.113.10/api")
        XCTAssertFalse(output.contains("hunter2"))
        XCTAssertFalse(output.contains("203.0.113.10"))
        XCTAssertTrue(output.contains("<host-1>"))
    }
}
