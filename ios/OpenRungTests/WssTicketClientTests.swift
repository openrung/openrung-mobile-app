import Foundation
import XCTest

final class WssTicketClientTests: XCTestCase {
    private static let frontURL = "wss://a.cdn.example/connect"

    override func tearDown() {
        TicketURLProtocol.handler = nil
        super.tearDown()
    }

    func testFixedEndpointPreservesBasePathAndRejectsDowngradeCredentialsQueryAndFragment() throws {
        XCTAssertEqual(
            try WssTicketClient.ticketEndpoint(
                for: URL(string: "https://broker.example/base/?old=1#discarded")!
            ).absoluteString,
            "https://broker.example/base/api/v1/wss/tickets"
        )
        XCTAssertEqual(
            try WssTicketClient.ticketEndpoint(for: URL(string: "http://127.0.0.1:8080/")!).absoluteString,
            "http://127.0.0.1:8080/api/v1/wss/tickets"
        )
        XCTAssertEqual(
            try WssTicketClient.ticketEndpoint(for: URL(string: "http://[::1]:8080/dev")!).absoluteString,
            "http://[::1]:8080/dev/api/v1/wss/tickets"
        )

        XCTAssertThrowsError(
            try WssTicketClient.ticketEndpoint(for: URL(string: "http://broker.example/")!)
        )
        XCTAssertThrowsError(
            try WssTicketClient.ticketEndpoint(for: URL(string: "https://user@broker.example/")!)
        )
        XCTAssertThrowsError(
            try WssTicketClient.ticketEndpoint(for: URL(string: "ftp://broker.example/")!)
        )
    }

    func testPostUsesExactBodyNoStoreHeadersAndCompleteIdentityPair() async throws {
        let now = Date(timeIntervalSince1970: 1_753_142_400)
        let body = ticketJSON(ticket: "opaque-ticket", expiresAt: now.addingTimeInterval(120))
        TicketURLProtocol.handler = { _ in (201, [:], Data(body.utf8)) }
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let result = try await WssTicketClient.requestOnce(
            session: session,
            brokerURL: URL(string: "http://127.0.0.1:8080/custom/")!,
            relayID: "relay-a",
            frontID: "front-a",
            clientID: "client-a",
            sessionID: "session-a",
            now: now
        )

        XCTAssertEqual(result.ticket, "opaque-ticket")
        XCTAssertEqual(result.url, Self.frontURL)
        let request = try WssTicketClient.ticketRequest(
            brokerURL: URL(string: "http://127.0.0.1:8080/custom/")!,
            relayID: "relay-a",
            frontID: "front-a",
            clientID: "client-a",
            sessionID: "session-a"
        )
        XCTAssertEqual(request.url?.path, "/custom/api/v1/wss/tickets")
        XCTAssertEqual(request.httpMethod, "POST")
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: String]
        )
        XCTAssertEqual(payload, ["relay_id": "relay-a", "front_id": "front-a"])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Pragma"), "no-cache")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRung-Client-ID"), "client-a")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRung-Session-ID"), "session-a")

        let unpaired = try WssTicketClient.ticketRequest(
            brokerURL: URL(string: "http://127.0.0.1:8080/")!,
            relayID: "relay-a",
            frontID: "front-a",
            clientID: "client-only",
            sessionID: nil
        )
        XCTAssertNil(unpaired.value(forHTTPHeaderField: "X-OpenRung-Client-ID"))
        XCTAssertNil(unpaired.value(forHTTPHeaderField: "X-OpenRung-Session-ID"))
    }

    func testRedirectIsRejectedAndStatusDoesNotRetainBody() async throws {
        let delegate = WssRedirectRejectingDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://broker.example/")!)
        let completion = expectation(description: "redirect decision")
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://broker.example/")!,
                statusCode: 307,
                httpVersion: nil,
                headerFields: ["Location": "https://sink.example/"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://sink.example/")!)
        ) { redirected in
            XCTAssertNil(redirected)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)
        task.cancel()
        session.invalidateAndCancel()

        TicketURLProtocol.handler = { _ in
            (307, ["Retry-After": "7", "Location": "https://sink.example/"], Data("secret-response".utf8))
        }
        let controlled = makeSession()
        defer { controlled.invalidateAndCancel() }
        do {
            _ = try await WssTicketClient.requestOnce(
                session: controlled,
                brokerURL: URL(string: "http://127.0.0.1/")!,
                relayID: "relay-a",
                frontID: "front-a",
                now: Date(timeIntervalSince1970: 0)
            )
            XCTFail("expected redirect status failure")
        } catch let error as WssTicketStatusError {
            XCTAssertEqual(error.status, 307)
            XCTAssertEqual(error.retryAfterMilliseconds, 7_000)
            XCTAssertFalse(String(describing: error).contains("secret-response"))
        }
    }

    func testResponseBoundsOpaqueTicketAndExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_753_142_400)

        for (index, body) in [
            String(repeating: "x", count: 64 * 1_024 + 1),
            ticketJSON(ticket: String(repeating: "t", count: 4_097), expiresAt: now.addingTimeInterval(60)),
            ticketJSON(ticket: "ticket\r\ninjected", expiresAt: now.addingTimeInterval(60)),
            ticketJSON(ticket: "ticket", expiresAt: now),
            ticketJSON(ticket: "ticket", expiresAt: now.addingTimeInterval(60), url: ""),
        ].enumerated() {
            XCTAssertThrowsError(
                try WssTicketClient.decodeTicketResponse(Data(body.utf8), now: now),
                "expected invalid ticket response at case \(index)"
            ) { error in
                XCTAssertTrue(error is URLError)
            }
        }
    }

    func testBrokerFrontFailoverAndBoundedSingleRetryRound() async throws {
        let primary = URL(string: "https://primary.example/")!
        let secondary = URL(string: "https://secondary.example/")!
        let state = TicketAttemptState()
        let clock = LockedBox<UInt64>(0)
        let ticket = WssSessionTicket(
            ticket: "retry-success",
            expiresAt: Date.distantFuture,
            url: Self.frontURL
        )

        let result = try await WssTicketClient.requestWithFailover(
            brokerURLs: [primary, secondary, primary],
            relayID: "relay-a",
            frontID: "front-a",
            clientID: nil,
            sessionID: nil,
            policy: WssTicketPolicy(
                totalDeadlineMilliseconds: 60_000,
                defaultRetryAfterMilliseconds: 10_000,
                maxRetryAfterMilliseconds: 30_000
            ),
            monotonicMilliseconds: { clock.get() },
            wait: { delay in
                state.recordWait(delay)
                clock.mutate { $0 += delay }
            },
            attempt: { broker, _, _, _, _, _ in
                let count = state.recordAttempt(broker)
                if count == 1 { throw WssTicketStatusError(status: 429, retryAfterMilliseconds: nil) }
                if count == 2 { throw WssTicketStatusError(status: 503, retryAfterMilliseconds: 120_000) }
                return ticket
            }
        )

        XCTAssertEqual(result, ticket)
        XCTAssertEqual(state.attempts, [primary, secondary, primary])
        XCTAssertEqual(state.waits, [30_000])
    }

    func testNonRetryableAllFailPreservesFirstBrokerDiagnostic() async {
        struct Diagnostic: Error, Equatable { let broker: String }
        let primary = URL(string: "https://primary.example/")!
        let secondary = URL(string: "https://secondary.example/")!
        let state = TicketAttemptState()
        do {
            _ = try await WssTicketClient.requestWithFailover(
                brokerURLs: [primary, secondary],
                relayID: "relay-a",
                frontID: "front-a",
                clientID: nil,
                sessionID: nil,
                policy: WssTicketPolicy(totalDeadlineMilliseconds: 20_000),
                monotonicMilliseconds: { 0 },
                wait: { _ in XCTFail("non-retryable failures must not wait") },
                attempt: { broker, _, _, _, _, _ in
                    _ = state.recordAttempt(broker)
                    throw Diagnostic(broker: broker.host ?? "")
                }
            )
            XCTFail("expected all broker fronts to fail")
        } catch let diagnostic as Diagnostic {
            XCTAssertEqual(diagnostic, Diagnostic(broker: "primary.example"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(state.attempts, [primary, secondary])
    }

    func testRetryAfterParsesDeltaAndHttpDate() {
        let now = Date(timeIntervalSince1970: 1_753_142_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"

        XCTAssertEqual(WssTicketClient.parseRetryAfterMilliseconds(" 12 ", now: now), 12_000)
        XCTAssertEqual(
            WssTicketClient.parseRetryAfterMilliseconds(
                formatter.string(from: now.addingTimeInterval(17)),
                now: now
            ),
            17_000
        )
        XCTAssertNil(WssTicketClient.parseRetryAfterMilliseconds("-1", now: now))
        XCTAssertNil(WssTicketClient.parseRetryAfterMilliseconds("not-a-date", now: now))
    }

    func testTicketFreshnessIsRecheckedAtNativeDialBoundary() {
        let expiry = Date(timeIntervalSince1970: 1_753_142_400)
        let ticket = WssSessionTicket(ticket: "opaque", expiresAt: expiry, url: Self.frontURL)
        XCTAssertTrue(ticket.isFresh(at: expiry.addingTimeInterval(-0.001)))
        XCTAssertFalse(ticket.isFresh(at: expiry))
        XCTAssertFalse(ticket.isFresh(at: expiry.addingTimeInterval(1)))
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TicketURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: WssRedirectRejectingDelegate(),
            delegateQueue: nil
        )
    }

    private func ticketJSON(ticket: String, expiresAt: Date, url: String = WssTicketClientTests.frontURL) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let object: [String: String] = [
            "ticket": ticket,
            "expires_at": formatter.string(from: expiresAt),
            "url": url,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

private final class TicketURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (status, headers, body) = try handler(request)
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            )
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        body(&value)
        lock.unlock()
    }
}

private final class TicketAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttempts: [URL] = []
    private var storedWaits: [UInt64] = []

    func recordAttempt(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedAttempts.append(url)
        return storedAttempts.count
    }

    func recordWait(_ delay: UInt64) {
        lock.lock()
        storedWaits.append(delay)
        lock.unlock()
    }

    var attempts: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedAttempts
    }

    var waits: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedWaits
    }
}
