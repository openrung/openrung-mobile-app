import XCTest

final class PunchFallbackPolicyTests: XCTestCase {
    private let policy = PunchFallbackPolicy()

    func testUnavailablePunchUsesRelayHub() async throws {
        var attempts: [String] = []

        let result: String = try await policy.connect(
            attemptPunch: {
                attempts.append("punch")
                return nil
            },
            attemptRelayHub: {
                attempts.append("hub")
                return "hub"
            },
            onPunchFallback: { _ in
                XCTFail("an unavailable punch is not an established-path failure")
            }
        )

        XCTAssertEqual(result, "hub")
        XCTAssertEqual(attempts, ["punch", "hub"])
    }

    func testRemoteFailureOnEstablishedPunchUsesRelayHub() async throws {
        var attempts: [String] = []
        var recordedStage: String?

        let result: String = try await policy.connect(
            attemptPunch: {
                attempts.append("punch")
                throw DirectPathError(stage: "internet_probe", underlying: URLError(.timedOut))
            },
            attemptRelayHub: {
                attempts.append("hub")
                return "hub"
            },
            onPunchFallback: { failure in
                recordedStage = failure.stage
            }
        )

        XCTAssertEqual(result, "hub")
        XCTAssertEqual(attempts, ["punch", "hub"])
        XCTAssertEqual(recordedStage, "internet_probe")
    }

    func testLocalFailureDoesNotUseRelayHub() async {
        var attemptedHub = false

        do {
            let _: String = try await policy.connect(
                attemptPunch: {
                    throw LocalTunnelError(
                        stage: "engine_start",
                        underlying: URLError(.cannotCreateFile)
                    )
                },
                attemptRelayHub: {
                    attemptedHub = true
                    return "hub"
                },
                onPunchFallback: { _ in }
            )
            XCTFail("expected the local failure")
        } catch let error as LocalTunnelError {
            XCTAssertEqual(error.stage, "engine_start")
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(attemptedHub)
    }

    func testNestedCancellationDoesNotUseRelayHub() async {
        var attemptedHub = false

        do {
            let _: String = try await policy.connect(
                attemptPunch: {
                    throw DirectPathError(
                        stage: "internet_probe",
                        underlying: CancellationError()
                    )
                },
                attemptRelayHub: {
                    attemptedHub = true
                    return "hub"
                },
                onPunchFallback: { _ in }
            )
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertFalse(attemptedHub)
    }
}
