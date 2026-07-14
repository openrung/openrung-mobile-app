package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope

/**
 * Client-side latency ranking for the relay connect ladder.
 *
 * The broker already orders relays by a composite score (load headroom, success rate, latency,
 * speed) from its own vantage; the one signal it cannot know is THIS client's network path. The
 * ranker probes TCP connect latency to the head of the candidate list in parallel and reorders by
 * latency BUCKET with a stable sort, so broker order — and with it the broker's load balancing —
 * still decides among relays whose measured latency is within [DEFAULT_BUCKET_MS] of each other.
 * Only humanly meaningful differences (a bucket boundary) override the broker.
 *
 * Ranking is fail-open by design: it reorders candidates but never drops one. A failed or
 * timed-out probe sinks that relay below the reachable ones (the connect ladder's own 5s
 * reachability gate may still succeed where a short probe gave up), and candidates beyond
 * [DEFAULT_MAX_PROBES] keep broker order after the probed head.
 *
 * The probe targets [RelayDescriptor.publicHost], which is the actual exit for the `direct`
 * relays that pass `isUsable` today. If tunnel (CGNAT) relays ever become usable, publicHost is
 * the relay hub — TCP latency to it would not measure the exit path (same trap as geolocating
 * publicHost; see RelayDescriptor).
 */
object RelayRanker {
    const val DEFAULT_MAX_PROBES = 8
    const val DEFAULT_PROBE_TIMEOUT_MS = 1_500

    /** Bucket width: within one bucket, broker order is preserved (stable sort). */
    const val DEFAULT_BUCKET_MS = 30L

    data class RankedRelay(val relay: RelayDescriptor, val probeMs: Long?)

    suspend fun rankByTcpLatency(
        candidates: List<RelayDescriptor>,
        maxProbes: Int = DEFAULT_MAX_PROBES,
        probeTimeoutMillis: Int = DEFAULT_PROBE_TIMEOUT_MS,
        bucketMs: Long = DEFAULT_BUCKET_MS,
        probe: suspend (RelayDescriptor, Int) -> Long = { relay, timeout ->
            RelayReachability.checkTcp(relay, timeout)
        },
    ): List<RankedRelay> {
        // Nothing to reorder: skip the probes (and their radio wake) entirely.
        if (candidates.size < 2) return candidates.map { RankedRelay(it, null) }

        val head = candidates.take(maxProbes)
        val tail = candidates.drop(maxProbes)
        val probed = coroutineScope {
            head.map { relay ->
                async {
                    val ms = try {
                        probe(relay, probeTimeoutMillis)
                    } catch (error: CancellationException) {
                        // A racing disconnect cancels the connect coroutine; propagate instead of
                        // treating cancellation as an unreachable relay.
                        throw error
                    } catch (_: Throwable) {
                        null
                    }
                    RankedRelay(relay, ms)
                }
            }.awaitAll()
        }
        val (reachable, failed) = probed.partition { it.probeMs != null }
        // sortedBy is stable: equal buckets keep broker order.
        return reachable.sortedBy { it.probeMs!! / bucketMs } + failed + tail.map { RankedRelay(it, null) }
    }
}
