package com.discflightschool.core.data

/**
 * The small slice of key-value storage the repositories need.
 *
 * On a device this is backed by `SharedPreferences`; in tests it is a map. The
 * repositories themselves stay free of Android types, so the rules about what
 * is saved, when, and how corrupt records are handled can be exercised on the
 * JVM instead of only on a device.
 */
interface KeyValueStore {
    fun getString(key: String): String?
    fun putString(key: String, value: String)
    fun getStringList(key: String): List<String>?
    fun putStringList(key: String, value: List<String>)
    fun getBoolean(key: String): Boolean?
    fun putBoolean(key: String, value: Boolean)
    fun getDouble(key: String): Double?
    fun putDouble(key: String, value: Double)
    fun remove(key: String)
}

/** An in-memory [KeyValueStore], for tests and for a store that fails to open. */
class InMemoryKeyValueStore(
    initial: Map<String, Any> = emptyMap(),
) : KeyValueStore {
    private val values = LinkedHashMap<String, Any>(initial)

    override fun getString(key: String): String? = values[key] as? String

    override fun putString(key: String, value: String) {
        values[key] = value
    }

    @Suppress("UNCHECKED_CAST")
    override fun getStringList(key: String): List<String>? = values[key] as? List<String>

    override fun putStringList(key: String, value: List<String>) {
        values[key] = value
    }

    override fun getBoolean(key: String): Boolean? = values[key] as? Boolean

    override fun putBoolean(key: String, value: Boolean) {
        values[key] = value
    }

    override fun getDouble(key: String): Double? = values[key] as? Double

    override fun putDouble(key: String, value: Double) {
        values[key] = value
    }

    override fun remove(key: String) {
        values.remove(key)
    }
}

/**
 * Secret storage, kept separate from [KeyValueStore] so an API key can never be
 * written to ordinary preferences by accident.
 */
interface SecretStore {
    fun read(key: String): String?
    fun write(key: String, value: String)
    fun delete(key: String)
}

/** An in-memory [SecretStore] for tests. */
class InMemorySecretStore : SecretStore {
    private val values = LinkedHashMap<String, String>()

    override fun read(key: String): String? = values[key]

    override fun write(key: String, value: String) {
        values[key] = value
    }

    override fun delete(key: String) {
        values.remove(key)
    }
}
