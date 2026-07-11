package com.openrung.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NatPunchClientTest {
    @Test
    fun `accepts an advertised HTTPS coordinator and trims trailing slashes`() {
        assertEquals(
            "https://43.201.124.63:9444",
            NatPunchClient.validatedCoordinatorUrl(" https://43.201.124.63:9444/// "),
        )
        assertEquals(
            "https://hub.example.com/punch",
            NatPunchClient.validatedCoordinatorUrl("https://hub.example.com/punch"),
        )
    }

    @Test
    fun `rejects cleartext derived and malformed coordinator endpoints`() {
        assertNull(NatPunchClient.validatedCoordinatorUrl(""))
        assertNull(NatPunchClient.validatedCoordinatorUrl("http://43.201.124.63:9444"))
        assertNull(NatPunchClient.validatedCoordinatorUrl("https://user@hub.example.com:9444"))
        assertNull(NatPunchClient.validatedCoordinatorUrl("https://hub.example.com:9444?next=http://evil"))
        assertNull(NatPunchClient.validatedCoordinatorUrl("not a url"))
    }

    @Test
    fun `pins deployed IP coordinators and requires normal CA validation for hostnames`() {
        val deployed = NatPunchClient.coordinatorTls("https://43.201.124.63:9444")
        assertEquals(true, deployed?.allowSelfSigned)
        assertEquals(64, deployed?.certificateSha256?.length)

        val hostname = NatPunchClient.coordinatorTls("https://hub.example.com/punch")
        assertEquals(false, hostname?.allowSelfSigned)
        assertEquals("", hostname?.certificateSha256)

        assertNull(NatPunchClient.coordinatorTls("https://203.0.113.8:9444"))
        assertNull(NatPunchClient.coordinatorTls("https://999.1.1.1:9444"))
        assertNull(NatPunchClient.coordinatorTls("https://[2001:db8::1]:9444"))
    }
}
