package com.openrung.state

import android.content.Context
import java.io.File
import java.io.FileWriter
import java.time.LocalDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * File-backed runtime log that survives restarts (contract §3 getPersistedLog):
 * every line the live 80-line console sees is ALSO scrubbed and appended here,
 * capped at [MAX_LINES] with amortized compaction (append-only writes; the file
 * is only rewritten when it overshoots to [COMPACT_THRESHOLD], not per append).
 *
 * Scrubbing happens BEFORE a line ever hits disk: proxy URIs, URLs, IPs (v4+v6),
 * UUIDs (the relay clientId is a credential) and credential-shaped key=value
 * pairs become placeholder tokens, bare domains last. Shared design with the
 * iOS RuntimeLogStore — keep the two scrubbers in sync.
 */
object RuntimeLogStore {
    private const val MAX_LINES = 1000
    private const val COMPACT_THRESHOLD = 1200
    private const val MAX_LINE_LENGTH = 600

    private val timeFormatter = DateTimeFormatter.ofPattern("MM-dd HH:mm:ss")
    private val lock = Any()
    private val executor: ExecutorService = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "openrung-runtime-log").apply { isDaemon = true }
    }
    private var logFile: File? = null
    private var lineCount = -1

    fun initialize(context: Context) {
        synchronized(lock) {
            if (logFile != null) return
            val directory = File(context.filesDir, "openrung_logs").apply { mkdirs() }
            logFile = File(directory, "runtime.log")
        }
    }

    /** Scrubs + appends one line (async, off the caller's thread). */
    fun append(message: String) {
        val timestamp = LocalDateTime.now().format(timeFormatter)
        val line = "[$timestamp] ${scrub(message)}"
        executor.execute {
            synchronized(lock) {
                val file = logFile ?: return@execute
                runCatching {
                    if (lineCount < 0) lineCount = countLines(file)
                    FileWriter(file, true).use { it.write(line + "\n") }
                    lineCount++
                    if (lineCount > COMPACT_THRESHOLD) compact(file)
                }
            }
        }
    }

    /** Full persisted log, oldest first (call off the main thread). */
    fun readLines(): List<String> =
        synchronized(lock) {
            val file = logFile ?: return emptyList()
            runCatching { file.readLines().takeLast(MAX_LINES) }.getOrDefault(emptyList())
        }

    fun clear() {
        synchronized(lock) {
            runCatching { logFile?.delete() }
            lineCount = 0
        }
    }

    private fun countLines(file: File): Int =
        runCatching { if (file.exists()) file.readLines().size else 0 }.getOrDefault(0)

    private fun compact(file: File) {
        val kept = file.readLines().takeLast(MAX_LINES)
        file.writeText(kept.joinToString("\n", postfix = "\n"))
        lineCount = kept.size
    }

    // --- Scrubber ---

    private val PROXY_URI = Regex("(?i)\\b(?:vless|vmess|trojan|ss|socks[45]?|hysteria2?|hy2|tuic|wireguard|anytls|naive\\+https)://\\S+")
    private val HTTP_URL = Regex("(?i)\\bhttps?://\\S+")
    private val GENERIC_URI = Regex("(?i)\\b[a-z][a-z0-9+.-]{1,20}://\\S+")
    private val UUID = Regex("(?i)\\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\b")
    private val KEY_VALUE = Regex("(?i)\\b(server|host|sni|server_name|uuid|password|token|secret|public_key|private_key|short_id|client_id)\\s*[=:]\\s*\\S+")
    private val IPV4 = Regex("\\b(?:\\d{1,3}\\.){3}\\d{1,3}(?::\\d+)?\\b")
    // Conservative IPv6: full/near-full groups, or a compressed form containing "::" —
    // deliberately does NOT match "HH:mm:ss"-style two-colon runs.
    private val IPV6 = Regex("\\[?(?:(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}|[0-9a-fA-F]{1,4}::[0-9a-fA-F:]{0,34}|::(?:[0-9a-fA-F]{1,4}:?){1,7})]?(?::\\d+)?")
    // Bare domains LAST, or it would eat the hosts inside URLs before their whole match runs.
    private val DOMAIN = Regex("(?i)\\b(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,}\\b")
    private val WHITESPACE = Regex("\\s+")

    internal fun scrub(message: String): String =
        message
            .replace(PROXY_URI, "<proxy-link>")
            .replace(HTTP_URL, "<url>")
            .replace(GENERIC_URI, "<uri>")
            .replace(KEY_VALUE) { match -> "${match.groupValues[1]}=<redacted>" }
            .replace(UUID, "<uuid>")
            .replace(IPV4, "<ip>")
            .replace(IPV6, "<ip>")
            .replace(DOMAIN, "<domain>")
            .replace(WHITESPACE, " ")
            .trim()
            .take(MAX_LINE_LENGTH)
}
