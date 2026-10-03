import Testing

@testable import romsen

// Release builds stamp the version only while scripts/build-release runs, so the committed
// source must always report the development value.
@Test func versionFlagPrintsTheCommittedDevelopmentVersion() {
    do {
        _ = try Romsen.parseAsRoot(["--version"])
        Issue.record("--version should end parsing with a clean exit")
    } catch {
        #expect(Romsen.message(for: error) == "0.0.0-dev")
        #expect(Romsen.exitCode(for: error).isSuccess)
    }
}
