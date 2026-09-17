package com.discflightschool.core

import com.discflightschool.core.data.InMemoryKeyValueStore
import com.discflightschool.core.data.InMemoryManifestStore
import com.discflightschool.core.data.InMemorySecretStore
import com.discflightschool.core.data.TrainingDataRepository
import com.discflightschool.core.net.ServerUris
import java.net.URI
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerUriTest {

    // ── isAllowedServerUri ───────────────────────────────────────────────

    @Test
    fun `allows any https origin`() {
        assertTrue(ServerUris.isAllowedServerUri(URI("https://discflightschool.onrender.com")))
        assertTrue(ServerUris.isAllowedServerUri(URI("https://example.com:8443/base")))
    }

    @Test
    fun `allows plain http only on loopback`() {
        assertTrue(ServerUris.isAllowedServerUri(URI("http://localhost:8000")))
        assertTrue(ServerUris.isAllowedServerUri(URI("http://127.0.0.1:8000")))
    }

    @Test
    fun `rejects cleartext http to a remote host`() {
        // Uploads carry the API key; cleartext to a remote host would leak it.
        assertFalse(ServerUris.isAllowedServerUri(URI("http://example.com")))
        assertFalse(ServerUris.isAllowedServerUri(URI("http://192.168.1.10:8000")))
    }

    @Test
    fun `rejects non-http schemes`() {
        for (uri in listOf("ftp://example.com", "file:///etc/passwd", "ws://example.com")) {
            assertFalse("$uri should be rejected", ServerUris.isAllowedServerUri(URI(uri)))
        }
    }

    // ── isSameOrigin ─────────────────────────────────────────────────────

    private val base = URI("https://server.example.com/api")

    @Test
    fun `accepts the same origin`() {
        assertTrue(
            ServerUris.isSameOrigin(base, URI("https://server.example.com/api/model/download")),
        )
    }

    @Test
    fun `treats an explicit default port as equal to an omitted one`() {
        assertTrue(ServerUris.isSameOrigin(base, URI("https://server.example.com:443/x")))
    }

    @Test
    fun `is case insensitive for scheme and host`() {
        assertTrue(ServerUris.isSameOrigin(base, URI("HTTPS://SERVER.EXAMPLE.COM/x")))
    }

    @Test
    fun `rejects a different host`() {
        assertFalse(ServerUris.isSameOrigin(base, URI("https://evil.com/x")))
    }

    @Test
    fun `rejects a different port on the same host`() {
        // A server-supplied URL must not be able to redirect the model download
        // to another service on the same box.
        assertFalse(ServerUris.isSameOrigin(base, URI("https://server.example.com:9000/x")))
    }

    @Test
    fun `rejects a scheme downgrade`() {
        assertFalse(ServerUris.isSameOrigin(base, URI("http://server.example.com/x")))
    }

    @Test
    fun `rejects a subdomain`() {
        assertFalse(ServerUris.isSameOrigin(base, URI("https://evil.server.example.com/x")))
    }

    // ── originOf ─────────────────────────────────────────────────────────

    @Test
    fun `normalizes scheme and host case and fills the default port`() {
        assertEquals(
            ServerUris.originOf("https://example.com/other"),
            ServerUris.originOf("HTTPS://Example.COM/path"),
        )
    }

    @Test
    fun `distinguishes ports`() {
        assertNotEquals(
            ServerUris.originOf("https://example.com"),
            ServerUris.originOf("https://example.com:8443"),
        )
    }

    @Test
    fun `ignores path, query and fragment`() {
        assertEquals(
            ServerUris.originOf("https://example.com/"),
            ServerUris.originOf("https://example.com/a?b=c#d"),
        )
    }

    @Test
    fun `tolerates surrounding whitespace`() {
        assertEquals(
            ServerUris.originOf("https://example.com"),
            ServerUris.originOf("  https://example.com  "),
        )
    }

    @Test
    fun `returns null for input with no host`() {
        assertNull(ServerUris.originOf(""))
        assertNull(ServerUris.originOf("not a url"))
        assertNull(ServerUris.originOf("/relative/path"))
    }

    @Test
    fun `endpoint refuses a server the app may not talk to`() {
        assertNull(ServerUris.endpoint("http://example.com", "/api/model/version"))
        assertEquals(
            URI("https://example.com/api/model/version"),
            ServerUris.endpoint("https://example.com", "/api/model/version"),
        )
    }

    // ── server URL changes and the stored API key ────────────────────────

    private fun repository() = TrainingDataRepository(
        store = InMemoryKeyValueStore(),
        secrets = InMemorySecretStore(),
        manifestStore = InMemoryManifestStore(),
    )

    @Test
    fun `changing the origin clears the stored API key`() {
        // The key was issued by the previous server; forwarding it to a new host
        // would hand the user's credential to whoever they just pointed at.
        val repository = repository()
        repository.setApiKey("secret-key")
        assertTrue(repository.hasApiKey)

        repository.setServerUrl("https://someone-elses-server.example.com")

        assertFalse(repository.hasApiKey)
    }

    @Test
    fun `editing the path on the same origin keeps the key`() {
        val repository = repository()
        repository.setServerUrl("https://server.example.com/api")
        repository.setApiKey("secret-key")

        repository.setServerUrl("https://server.example.com/api/v2")

        assertTrue(repository.hasApiKey)
    }

    @Test
    fun `changing only the port is treated as a new origin`() {
        val repository = repository()
        repository.setServerUrl("https://server.example.com")
        repository.setApiKey("secret-key")

        repository.setServerUrl("https://server.example.com:9443")

        assertFalse(repository.hasApiKey)
    }

    @Test
    fun `setting the same URL again is a no-op for the key`() {
        val repository = repository()
        repository.setServerUrl("https://server.example.com")
        repository.setApiKey("secret-key")

        repository.setServerUrl("https://server.example.com")

        assertTrue(repository.hasApiKey)
    }
}
