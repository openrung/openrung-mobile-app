import Foundation

/// A correctly prepared direct Reality path failed on the remote network/data path. Only this error
/// may unlock WSS fallback; configuration, engine, permission, platform and cancellation failures
/// use separate types and remain terminal.
struct DirectPathError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? {
        "Direct Reality path failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct LocalTunnelError: LocalizedError {
    let stage: String
    let underlying: Error

    var errorDescription: String? {
        "Local tunnel setup failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct WssTransportError: LocalizedError {
    let stage: String
    let frontID: String
    let underlying: Error

    var errorDescription: String? {
        "WSS front \(frontID) failed at \(stage): \(underlying.localizedDescription)"
    }
}

struct RelayFailureAlreadyRecordedError: LocalizedError {
    let directFailure: DirectPathError
    let wssFailures: [WssTransportError]

    var errorDescription: String? {
        wssFailures.last?.localizedDescription ?? directFailure.localizedDescription
    }
}

/// The native implementation delegates strict URL/version/order validation to wsscore. Swift never
/// reproduces those rules and never rewrites signed input.
protocol WssFrontSetValidating {
    func validateExact(_ fronts: [WssFrontDescriptor]) throws
}

struct WssFallbackPolicy {
    let validator: WssFrontSetValidating

    func supportedFronts(for relay: RelayDescriptor) -> [WssFrontDescriptor] {
        let transport = relay.transport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard
            transport.isEmpty || transport == RelayConstants.transportDirect,
            relay.nodeClass == RelayConstants.nodeClassFoundation,
            relay.exitMode == RelayConstants.exitModeDirect,
            relay.publicPort == 443,
            relay.wssFronts.isEmpty == false
        else {
            return []
        }

        do {
            try validator.validateExact(relay.wssFronts)
            return relay.wssFronts
        } catch {
            return []
        }
    }

    /// Runs direct exactly once. Front attempts preserve the signed order, and their failures are
    /// reported only through the transport callback rather than relay-health accounting.
    func connect<T>(
        relay: RelayDescriptor,
        attemptDirect: () async throws -> T,
        attemptWss: (WssFrontDescriptor) async throws -> T,
        onDirectFallback: (DirectPathError) async -> Void,
        onWssFailure: (WssFrontDescriptor, WssTransportError) async -> Void
    ) async throws -> T {
        let directFailure: DirectPathError
        do {
            return try await attemptDirect()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DirectPathError {
            if containsCancellation(error) { throw CancellationError() }
            directFailure = error
        } catch {
            throw error
        }

        let fronts = supportedFronts(for: relay)
        guard fronts.isEmpty == false else { throw directFailure }
        await onDirectFallback(directFailure)

        var failures: [WssTransportError] = []
        for front in fronts {
            do {
                return try await attemptWss(front)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LocalTunnelError {
                if containsCancellation(error) { throw CancellationError() }
                throw error
            } catch let error as WssTransportError {
                if containsCancellation(error) { throw CancellationError() }
                failures.append(error)
                await onWssFailure(front, error)
            }
        }
        throw RelayFailureAlreadyRecordedError(directFailure: directFailure, wssFailures: failures)
    }
}

private func containsCancellation(_ error: Error, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    if error is CancellationError { return true }
    if let direct = error as? DirectPathError {
        return containsCancellation(direct.underlying, depth: depth + 1)
    }
    if let local = error as? LocalTunnelError {
        return containsCancellation(local.underlying, depth: depth + 1)
    }
    if let wss = error as? WssTransportError {
        return containsCancellation(wss.underlying, depth: depth + 1)
    }
    if let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? Error {
        return containsCancellation(underlying, depth: depth + 1)
    }
    return false
}

func relayFailureAlreadyRecorded(_ error: Error) -> Bool {
    var current: Error? = error
    var depth = 0
    while let item = current, depth < 8 {
        if item is RelayFailureAlreadyRecordedError { return true }
        current = (item as NSError).userInfo[NSUnderlyingErrorKey] as? Error
        depth += 1
    }
    return false
}

/// Centralizes the security-sensitive teardown order: stop Reality/libbox before retiring the
/// loopback adapter it is using.
enum TunnelTransportCleanup {
    /// Drains task ownership in call-site order. stopTunnel uses this for connection-bearing tasks
    /// before engine teardown, and again for observers after teardown has unblocked their streams.
    static func drain(_ tasks: [Task<Void, Never>]) async {
        for task in tasks { await task.value }
    }

    static func run(
        stopEngine: () -> Void,
        closeNetworkMonitor: () -> Void,
        closeWss: () -> Void
    ) {
        stopEngine()
        closeNetworkMonitor()
        closeWss()
    }
}
