package com.discflightschool.core.net

import java.net.URI

/**
 * Which training-server URLs the app is willing to talk to, and when a URL edit
 * has crossed a trust boundary.
 *
 * Plain HTTP is allowed only against loopback, so a typo in the server field
 * cannot quietly send a user's throws and API key over the network in clear.
 */
object ServerUris {

    /** Scheme, host, and port, or null when [url] does not parse. */
    fun originOf(url: String): String? {
        val uri = runCatching { URI(url.trim()) }.getOrNull() ?: return null
        val host = uri.host ?: return null
        if (host.isEmpty()) return null
        return "${uri.scheme.orEmpty().lowercase()}://${host.lowercase()}:${effectivePort(uri)}"
    }

    /** Whether [uri] is an origin the app will send requests to at all. */
    fun isAllowedServerUri(uri: URI): Boolean {
        val scheme = uri.scheme?.lowercase() ?: return false
        if (scheme == "https") return true
        if (scheme != "http") return false
        val host = uri.host?.lowercase() ?: return false
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    /**
     * Whether [candidate] is on the same origin as [base] (scheme, host, port).
     *
     * The scheme default is resolved first, so an explicit `:443` on an https
     * URL compares equal to an omitted port.
     */
    fun isSameOrigin(base: URI, candidate: URI): Boolean =
        candidate.scheme?.lowercase() == base.scheme?.lowercase() &&
            candidate.host?.lowercase() == base.host?.lowercase() &&
            effectivePort(candidate) == effectivePort(base)

    /**
     * Resolve [path] against [serverUrl], or null when the server URL is not one
     * the app is allowed to use.
     */
    fun endpoint(serverUrl: String, path: String): URI? {
        val serverUri = runCatching { URI(serverUrl.trim()) }.getOrNull() ?: return null
        if (!isAllowedServerUri(serverUri)) return null
        return runCatching { serverUri.resolve(path) }.getOrNull()
    }

    private fun effectivePort(uri: URI): Int {
        if (uri.port != -1) return uri.port
        return when (uri.scheme?.lowercase()) {
            "https" -> 443
            "http" -> 80
            else -> -1
        }
    }
}
