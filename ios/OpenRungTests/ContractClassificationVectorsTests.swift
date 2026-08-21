import Foundation
import NetworkExtension
import XCTest

/// The Swift half of the shared failure-classification contract.
///
/// The rows come from testdata/contract/classification.json, vendored from openrung/openrung and
/// checked against the pinned ref by `npm run contract:check`. Since the classifier policy moved
/// into the shared Go implementation behind the libbox binding, this suite pins the adapter half:
/// the platform error built for each row must extract to the exact binding input recorded in
/// testdata/classification-binding-inputs.json. The other half — those same inputs classifying to
/// each row's expected token through the real binding — runs in android/punchbridge's Go tests
/// (failure_binding_test.go), so the two suites compose into the rows running end-to-end against
/// the one classifier every OpenRung client shares. This test bundle deliberately compiles without
/// the engine (see project.yml), which is why the chain is split exactly at the binding's wire
/// format.
final class ContractClassificationVectorsTests: XCTestCase {

    /// The version this suite was written against; a bump upstream means revisiting it.
    private static let expectedVersion = 1

    /// This suite's identifier in the file's `suites` declaration.
    private static let suite = "swift"

    /// Resolved from this file's own path rather than a bundle resource, so the vectors stay a
    /// plain checked-in file that every suite reads the same way and the Xcode target needs no
    /// resource wiring.
    private static let testdataDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OpenRungTests
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("testdata", isDirectory: true)

    private var vectors: [String: Any] = [:]
    private var bindingInputs: [String: Any] = [:]

    override func setUpWithError() throws {
        vectors = try Self.jsonObject(at: Self.testdataDirectory
            .appendingPathComponent("contract/classification.json"))
        bindingInputs = try Self.jsonObject(at: Self.testdataDirectory
            .appendingPathComponent("classification-binding-inputs.json"))
    }

    private static func jsonObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(url.lastPathComponent) is not a JSON object"
        )
    }

    func testRunsTheVersionAndSuiteItWasWrittenFor() throws {
        XCTAssertEqual(vectors["version"] as? Int, Self.expectedVersion)
        XCTAssertEqual(bindingInputs["contract_version"] as? Int, Self.expectedVersion)
        let declared = try XCTUnwrap(vectors["suites"] as? [String])
        XCTAssertTrue(declared.contains(Self.suite), "the file must declare this suite as a consumer")
    }

    func testEveryClaimedRowExtractsToTheSharedBindingInput() throws {
        let cases = try XCTUnwrap(vectors["cases"] as? [[String: Any]])
        var ran = 0

        for row in cases {
            let id = try XCTUnwrap(row["id"] as? String)
            guard suites(for: row).contains(Self.suite) else { continue }
            // Winsock numbers only a Windows network stack produces; iOS never sees them.
            guard (row["platform"] as? String) != "windows" else { continue }
            guard let error = error(for: row) else { continue }

            ran += 1
            let facts = try XCTUnwrap(
                FailureClassifier.bindingInput(for: error),
                "vector \(id): the built error resolved to a pre-classified token, not binding facts"
            )
            XCTAssertEqual(
                facts as NSDictionary,
                try expectedBindingInput(for: id) as NSDictionary,
                "vector \(id)"
            )
        }

        // A suite that silently matched no row would pass while asserting nothing.
        XCTAssertGreaterThanOrEqual(ran, 15, "no rows ran; the vectors or the kind mapping changed shape")
    }

    /// The suites that must run a row: the kind's list, narrowed by the row's own when it has one.
    private func suites(for row: [String: Any]) -> [String] {
        if let own = row["suites"] as? [String] { return own }
        let kinds = vectors["kinds"] as? [String: Any] ?? [:]
        let kind = kinds[row["kind"] as? String ?? ""] as? [String: Any] ?? [:]
        return kind["suites"] as? [String] ?? []
    }

    /// The fixture entry for `id`, with `errno_symbol` resolved to this platform's number via
    /// `POSIXErrorCode` — the same transform the Go and Kotlin suites apply on their platforms.
    private func expectedBindingInput(for id: String) throws -> [String: Any] {
        let inputs = try XCTUnwrap(bindingInputs["inputs"] as? [String: Any])
        let entry = try XCTUnwrap(
            inputs[id] as? [String: Any],
            "\(id): no binding-input fixture entry; add it to classification-binding-inputs.json"
        )
        var expected: [String: Any] = [:]
        for (key, value) in entry {
            if key == "errno_symbol" {
                let symbol = try XCTUnwrap(value as? String)
                let code = try XCTUnwrap(posixCode(symbol), "\(id): unknown errno symbol \(symbol)")
                expected["errno"] = Int(code.rawValue)
            } else {
                expected[key] = value
            }
        }
        return expected
    }

    private func error(for row: [String: Any]) -> Error? {
        let input = row["input"] as? [String: Any] ?? [:]
        let wrapped = input["wrapped"] as? Bool ?? false
        // The shape the connect pipeline actually produces: the real cause under a wrapper the
        // classifier has to unwrap.
        func wrap(_ error: Error) -> Error {
            wrapped ? PacketTunnelError.allRelaysFailed(error) : error
        }

        switch row["kind"] as? String {
        case "cancellation":
            return wrap(CancellationError())
        case "selection":
            switch input["sentinel"] as? String {
            case "relay_not_in_list": return PacketTunnelError.relayNotAvailable
            case "no_relay_in_country": return PacketTunnelError.noRelayInCountry("Peru")
            case "no_usable_relay": return PacketTunnelError.noUsableRelay
            default: return nil
            }
        case "http_status":
            guard let status = input["status"] as? Int else { return nil }
            return wrap(BrokerClientError.httpStatus(status))
        case "errno":
            guard let code = posixCode(input["symbol"] as? String) else { return nil }
            let posix = POSIXError(code)
            return wrapped
                ? PacketTunnelError.relayUnreachable(host: "203.0.113.10", port: 443, underlying: posix)
                : posix
        case "dns":
            guard input["subkind"] as? String == "not_found" else { return nil }
            return wrap(URLError(.cannotFindHost))
        case "tls":
            switch input["subkind"] as? String {
            case "not_tls": return wrap(URLError(.secureConnectionFailed))
            case "unknown_authority": return wrap(URLError(.serverCertificateHasUnknownRoot))
            case "hostname_mismatch": return wrap(URLError(.serverCertificateUntrusted))
            case "cert_expired": return wrap(URLError(.serverCertificateHasBadDate))
            default: return nil
            }
        case "permission":
            return wrap(
                NSError(domain: NEVPNErrorDomain, code: NEVPNError.configurationReadWriteFailed.rawValue)
            )
        case "process_exit":
            return wrap(PacketTunnelProxyEngineError.engineStartFailed("engine failed"))
        case "timeout":
            return wrap(URLError(.timedOut))
        case "unrecognized":
            return NSError(
                domain: "OpenRungContractVectors",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: input["message"] as? String ?? ""]
            )
        // `none` (Swift's classify takes a non-optional Error), `deadline`, and `wss_reason` are
        // declared for other suites; `suites(for:)` already filtered them out.
        default:
            return nil
        }
    }

    private func posixCode(_ symbol: String?) -> POSIXErrorCode? {
        switch symbol {
        case "ECONNREFUSED": return .ECONNREFUSED
        case "ECONNRESET": return .ECONNRESET
        case "ENETUNREACH": return .ENETUNREACH
        case "EHOSTUNREACH": return .EHOSTUNREACH
        case "ETIMEDOUT": return .ETIMEDOUT
        case "EACCES": return .EACCES
        case "EPERM": return .EPERM
        case "EPIPE": return .EPIPE
        default: return nil
        }
    }
}
