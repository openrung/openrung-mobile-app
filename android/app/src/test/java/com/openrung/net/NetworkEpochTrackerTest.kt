package com.openrung.net

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NetworkEpochTrackerTest {
    @Test
    fun `only a new physical snapshot advances the network epoch`() {
        val wifi = setOf("wifi:7:dns-a")
        val cellular = setOf("cellular:9:dns-b")
        val tracker = NetworkEpochTracker(wifi)

        assertFalse(tracker.update(wifi))
        assertTrue(tracker.update(cellular))
        assertFalse(tracker.update(cellular))
        assertTrue(tracker.update(emptySet()))
        assertFalse(tracker.update(emptySet()))
    }

    @Test
    fun `snapshot input is copied instead of retained`() {
        val mutable = linkedSetOf("wifi")
        val tracker = NetworkEpochTracker(mutable)
        mutable += "cellular"

        assertTrue(tracker.update(mutable))
        assertFalse(tracker.update(setOf("wifi", "cellular")))
    }
}
