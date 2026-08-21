package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import java.io.File

/**
 * The sing-box binding fixtures shared by the three platform suites and `android/punchbridge`'s
 * Go tests: one `<scenario>.input.json` per platform scenario (the binding input the assembly
 * must produce), and one frozen `<scenario>.golden.json` holding the bound builder's output.
 * The Go suite is the only writer of the goldens and pins input→config through the real binding;
 * the suites here pin platform state→input and re-run this platform's structural emission
 * assertions against the goldens — so the existing expectations hold against the bound output
 * without the JVM loading the gomobile engine.
 */
object SingBoxBindingFixtures {
    private val directory: File = File(
        requireNotNull(System.getProperty("openrung.contractVectors")) {
            "openrung.contractVectors is unset; the Gradle unit-test task should supply it"
        },
    ).parentFile.resolve("singbox-binding")

    fun input(scenario: String): JsonObject = parse("$scenario.input.json")

    fun golden(scenario: String): JsonObject = parse(goldenText(scenario))

    fun goldenText(scenario: String): String =
        directory.resolve("$scenario.golden.json").readText()

    /** Scenario names for this platform, derived from the checked-in input files. */
    fun scenarios(platform: String): List<String> =
        requireNotNull(directory.list()) { "missing fixture directory $directory" }
            .filter { it.startsWith("$platform-") && it.endsWith(".input.json") }
            .map { it.removeSuffix(".input.json") }
            .sorted()

    private fun parse(nameOrText: String): JsonObject {
        val text = if (nameOrText.endsWith(".json")) directory.resolve(nameOrText).readText() else nameOrText
        return Json.parseToJsonElement(text).jsonObject
    }

    /**
     * The relay every scenario input carries. The connection identity fields must match the
     * fixtures' `relay` object byte-for-byte; the remaining fields exist only to satisfy the
     * model and are never assembled into the binding input.
     */
    fun relay(): RelayDescriptor = RelayDescriptor(
        id = "relay-1",
        label = "test-relay",
        publicHost = "203.0.113.10",
        publicPort = 443,
        relayProtocol = "vless-reality-vision",
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "reality-key",
        shortId = "abcd1234",
        serverName = "www.example.com",
        flow = "xtls-rprx-vision",
        exitMode = "direct",
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        transport = "tunnel",
        punchCapable = true,
        punchEndpoint = "https://203.0.113.10:9444",
        registeredAt = "2026-01-01T00:00:00Z",
        lastHeartbeatAt = "2026-01-01T00:00:00Z",
        expiresAt = "2026-01-01T01:00:00Z",
    )
}
