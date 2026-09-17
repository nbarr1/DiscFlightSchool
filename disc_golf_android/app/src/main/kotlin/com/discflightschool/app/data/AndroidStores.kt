package com.discflightschool.app.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.discflightschool.core.data.FlutterPreferences
import com.discflightschool.core.data.KeyValueStore
import com.discflightschool.core.data.ManifestStore
import com.discflightschool.core.data.SecretStore
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream
import java.io.ObjectInputStream
import java.io.ObjectStreamClass

/** [KeyValueStore] backed by `SharedPreferences`. */
class SharedPreferencesStore(private val prefs: SharedPreferences) : KeyValueStore {

    override fun getString(key: String): String? = prefs.getString(key, null)

    override fun putString(key: String, value: String) {
        prefs.edit().putString(key, value).apply()
    }

    /**
     * Stored as one delimited blob rather than a `StringSet`: a set has no
     * order, and every history list here is ordered newest-first.
     */
    override fun getStringList(key: String): List<String>? {
        val raw = prefs.getString(listKey(key), null) ?: return null
        if (raw.isEmpty()) return emptyList()
        return raw.split(LIST_SEPARATOR)
    }

    override fun putStringList(key: String, value: List<String>) {
        prefs.edit().putString(listKey(key), value.joinToString(LIST_SEPARATOR)).apply()
    }

    override fun getBoolean(key: String): Boolean? =
        if (prefs.contains(key)) prefs.getBoolean(key, false) else null

    override fun putBoolean(key: String, value: Boolean) {
        prefs.edit().putBoolean(key, value).apply()
    }

    override fun getDouble(key: String): Double? =
        if (prefs.contains(key)) {
            java.lang.Double.longBitsToDouble(prefs.getLong(key, 0L))
        } else {
            null
        }

    override fun putDouble(key: String, value: Double) {
        prefs.edit().putLong(key, java.lang.Double.doubleToRawLongBits(value)).apply()
    }

    override fun remove(key: String) {
        prefs.edit().remove(key).remove(listKey(key)).apply()
    }

    private fun listKey(key: String) = "$key.list"

    private companion object {
        /**
         * The ASCII record separator, so a stored JSON document can never be
         * mistaken for a list delimiter.
         */
        const val LIST_SEPARATOR = ""
    }
}

/**
 * [SecretStore] backed by `EncryptedSharedPreferences`.
 *
 * Falls back to an in-memory store when the keystore is unavailable. On a
 * device with a broken keystore, losing the key for this session is better than
 * writing it somewhere unencrypted, and far better than crashing on launch.
 */
class EncryptedSecretStore(context: Context) : SecretStore {

    private val prefs: SharedPreferences? = runCatching {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            "disc_flight_school_secrets",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.onFailure {
        Log.w(TAG, "Encrypted storage unavailable; secrets will not persist", it)
    }.getOrNull()

    private val fallback = LinkedHashMap<String, String>()

    override fun read(key: String): String? = prefs?.getString(key, null) ?: fallback[key]

    override fun write(key: String, value: String) {
        if (prefs != null) prefs.edit().putString(key, value).apply() else fallback[key] = value
    }

    override fun delete(key: String) {
        prefs?.edit()?.remove(key)?.apply()
        fallback.remove(key)
    }

    private companion object {
        const val TAG = "EncryptedSecretStore"
    }
}

/** [ManifestStore] backed by a file in the app's private storage. */
class FileManifestStore(private val file: File) : ManifestStore {

    override fun read(): String? = runCatching {
        if (file.exists()) file.readText() else null
    }.getOrNull()

    override fun write(content: String) {
        runCatching {
            file.parentFile?.mkdirs()
            file.writeText(content)
        }.onFailure { Log.w("FileManifestStore", "Failed to write ${file.name}", it) }
    }
}

/**
 * Carry an earlier Flutter install's preferences into [store], once.
 *
 * Runs before any repository reads the store, because the first read is what
 * decides whether onboarding is shown and what history exists. The marker is
 * written even when the legacy file is empty, so a fresh install pays the cost
 * exactly once rather than on every launch.
 */
fun migrateFlutterPreferences(context: Context, store: KeyValueStore) {
    if (store.getBoolean(FLUTTER_MIGRATION_KEY) == true) return

    runCatching {
        val legacy = context.getSharedPreferences(
            FlutterPreferences.FILE_NAME,
            Context.MODE_PRIVATE,
        )
        val entries = legacy.all
        if (entries.isNotEmpty()) {
            val copied = FlutterPreferences.migrate(
                legacy = entries,
                into = store,
                platformListDecoder = ::decodeSerializedStringList,
            )
            Log.i(STORE_TAG, "Carried $copied preferences over from the Flutter install")
        }
    }.onFailure { error ->
        Log.w(STORE_TAG, "Could not read the Flutter preferences file", error)
    }

    store.putBoolean(FLUTTER_MIGRATION_KEY, true)
}

/**
 * Decode the older base64 list form, which is a serialized `ArrayList<String>`.
 *
 * Deserialization is restricted to the two classes that form can legitimately
 * contain. The file is the app's own, but a decoder that will instantiate
 * whatever it is handed is not worth keeping around for a legacy format.
 */
private fun decodeSerializedStringList(encoded: String): List<String>? = runCatching {
    val bytes = Base64.decode(encoded, Base64.DEFAULT)
    StringListObjectInputStream(ByteArrayInputStream(bytes)).use { stream ->
        (stream.readObject() as? List<*>)?.filterIsInstance<String>()
    }
}.getOrNull()

private class StringListObjectInputStream(source: InputStream) : ObjectInputStream(source) {
    override fun resolveClass(description: ObjectStreamClass): Class<*> =
        when (description.name) {
            ArrayList::class.java.name -> ArrayList::class.java
            String::class.java.name -> String::class.java
            else -> throw java.io.InvalidClassException(
                description.name,
                "Not part of a stored string list",
            )
        }
}

private const val FLUTTER_MIGRATION_KEY = "flutter_preferences_migrated"
private const val STORE_TAG = "AndroidStores"
