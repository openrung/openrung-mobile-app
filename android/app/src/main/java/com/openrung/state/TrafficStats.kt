package com.openrung.state

/**
 * One live traffic sample (contract §3 `TrafficStats`): instantaneous rates in
 * bytes/second plus per-session cumulative totals. Produced by the libbox
 * CommandStatus stream while the tunnel is up; never persisted.
 */
data class TrafficStats(
    val upBps: Long,
    val downBps: Long,
    val upTotalBytes: Long,
    val downTotalBytes: Long,
    val updatedAtMs: Long,
)
