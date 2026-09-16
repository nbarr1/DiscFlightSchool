package com.discflightschool.core

import com.discflightschool.core.data.AppPreferences
import com.discflightschool.core.data.FlutterPreferences
import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.ScoringRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Upgrading from the Flutter client.
 *
 * The encodings under test are the plugin's, so these cases are written the way
 * `FlutterSharedPreferences` actually looks on a device that ran the old app.
 */
class FlutterPreferencesTest {

    private fun legacy(vararg pairs: Pair<String, Any?>) =
        pairs.associate { (key, value) -> "${FlutterPreferences.KEY_PREFIX}$key" to value }

    @Test
    fun `carries over a finished onboarding`() {
        val store = InMemoryKeyValueStore()
        val copied = FlutterPreferences.migrate(legacy("onboarding_complete" to true), store)

        assertEquals(1, copied)
        assertTrue(AppPreferences(store).onboardingComplete)
    }

    @Test
    fun `carries over saved rounds as a JSON-encoded list`() {
        val store = InMemoryKeyValueStore()
        val rounds = listOf("""{"id":"a"}""", """{"id":"b"}""")
        val encoded = FlutterPreferences.JSON_LIST_PREFIX +
            """["{\"id\":\"a\"}","{\"id\":\"b\"}"]"""

        val copied = FlutterPreferences.migrate(legacy(ScoringRepository.KEY to encoded), store)

        assertEquals(1, copied)
        assertEquals(rounds, store.getStringList(ScoringRepository.KEY))
    }

    @Test
    fun `carries over the older platform-encoded list through the supplied decoder`() {
        val store = InMemoryKeyValueStore()
        val encoded = FlutterPreferences.LIST_PREFIX + "c29tZS1iYXNlNjQ="

        val copied = FlutterPreferences.migrate(
            legacy = legacy("form_session_history" to encoded),
            into = store,
            platformListDecoder = { payload ->
                assertEquals("c29tZS1iYXNlNjQ=", payload)
                listOf("one", "two")
            },
        )

        assertEquals(1, copied)
        assertEquals(listOf("one", "two"), store.getStringList("form_session_history"))
    }

    @Test
    fun `a list the decoder cannot read is skipped without losing the rest`() {
        val store = InMemoryKeyValueStore()
        val copied = FlutterPreferences.migrate(
            legacy = legacy(
                "form_session_history" to FlutterPreferences.LIST_PREFIX + "broken",
                "training_server_url" to "https://example.test",
            ),
            into = store,
            platformListDecoder = { null },
        )

        assertEquals(1, copied)
        assertNull(store.getStringList("form_session_history"))
        assertEquals("https://example.test", store.getString("training_server_url"))
    }

    @Test
    fun `decodes a tagged double`() {
        val store = InMemoryKeyValueStore()
        val encoded = FlutterPreferences.DOUBLE_PREFIX + "0.35"

        FlutterPreferences.migrate(legacy("disc_confidence_threshold" to encoded), store)

        assertEquals(0.35, store.getDouble("disc_confidence_threshold")!!, 1e-9)
    }

    @Test
    fun `a malformed double is skipped rather than stored as text`() {
        val store = InMemoryKeyValueStore()
        val encoded = FlutterPreferences.DOUBLE_PREFIX + "not-a-number"

        val copied = FlutterPreferences.migrate(legacy("disc_confidence_threshold" to encoded), store)

        assertEquals(0, copied)
        assertNull(store.getDouble("disc_confidence_threshold"))
        assertNull(store.getString("disc_confidence_threshold"))
    }

    @Test
    fun `plain strings come across unchanged`() {
        val store = InMemoryKeyValueStore()
        FlutterPreferences.migrate(legacy("preferred_throw_type" to "FH"), store)

        assertEquals("FH", store.getString("preferred_throw_type"))
    }

    @Test
    fun `ignores keys the Dart side did not write`() {
        val store = InMemoryKeyValueStore()
        val copied = FlutterPreferences.migrate(
            mapOf("some_other_library_key" to "value", "flutter." to "empty key"),
            store,
        )

        assertEquals(0, copied)
        assertNull(store.getString("some_other_library_key"))
    }

    @Test
    fun `ignores a value type no repository reads`() {
        val store = InMemoryKeyValueStore()
        // Flutter writes ints as longs; nothing here reads one.
        val copied = FlutterPreferences.migrate(legacy("some_counter" to 7L), store)

        assertEquals(0, copied)
    }

    @Test
    fun `a fresh install migrates nothing and still reads as new`() {
        val store = InMemoryKeyValueStore()
        val copied = FlutterPreferences.migrate(emptyMap(), store)

        assertEquals(0, copied)
        assertFalse(AppPreferences(store).onboardingComplete)
    }
}
