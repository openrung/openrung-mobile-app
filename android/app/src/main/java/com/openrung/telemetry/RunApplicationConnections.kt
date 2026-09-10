package com.openrung.telemetry

/** Native attribution/reduction belongs to one TUN attempt and its Go reporter. */
internal class RunApplicationConnections(
    private val ownPackage: String,
    elapsedMs: () -> Long,
    private val report: (String, Int, Long) -> Unit,
) {
    private val counts = ApplicationConnectionAggregator(15 * 60 * 1000L, elapsedMs)
    private var closed = false

    @Synchronized fun record(uid: Int, packages: List<String>, destinationPort: Int) {
        if (closed || destinationPort == 53) return
        packages.distinct().filter { it.isNotEmpty() && it != ownPackage }.forEach { name ->
            counts.recordFlow(name, uid).forEach { report(name, uid, it) }
        }
    }

    @Synchronized fun close() {
        if (closed) return
        closed = true
        counts.drainPending().forEach { report(it.packageName, it.uid, it.flows) }
    }
}
