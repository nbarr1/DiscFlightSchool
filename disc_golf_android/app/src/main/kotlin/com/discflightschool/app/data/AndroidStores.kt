package com.discflightschool.app.data

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.discflightschool.core.data.KeyValueStore
import com.discflightschool.core.data.ManifestStore
import com.discflightschool.core.data.SecretStore
import java.io.File
import org.json.JSONArray

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
/** Copies Flutter's shared_preferences store into the native store exactly once. */
fun migrateFlutterPreferences(context: Context, destination: SharedPreferences) {
    val marker = "native_preferences_migrated"
    if (destination.getBoolean(marker, false)) return
    val legacy = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    val editor = destination.edit()
    legacy.all.forEach { (encodedKey, value) ->
        val key = encodedKey.removePrefix("flutter.")
        if (destination.contains(key)) return@forEach
        when (value) {
            is String -> when {
                value.startsWith(FLUTTER_LIST_PREFIX) -> {
                    val array = JSONArray(value.removePrefix(FLUTTER_LIST_PREFIX))
                    val items = (0 until array.length()).map { array.getString(it) }
                    editor.putString("$key.list", items.joinToString("\u001e"))
                }
                value.startsWith(FLUTTER_DOUBLE_PREFIX) -> {
                    val doubleValue = value.removePrefix(FLUTTER_DOUBLE_PREFIX).toDoubleOrNull()
                    if (doubleValue != null) {
                        editor.putLong(key, java.lang.Double.doubleToRawLongBits(doubleValue))
                    }
                }
                else -> editor.putString(key, value)
            }
            is Boolean -> editor.putBoolean(key, value)
            is Int -> editor.putInt(key, value)
            is Long -> editor.putLong(key, value)
            is Float -> if (key == "disc_confidence_threshold") {
                editor.putLong(key, java.lang.Double.doubleToRawLongBits(value.toDouble()))
            } else {
                editor.putFloat(key, value)
            }
            // Flutter StringList values are StringSets in the Android backing
            // file. Native ordered lists use the store's encoded list key.
            is Set<*> -> editor.putString(
                "$key.list",
                value.filterIsInstance<String>().joinToString("\u001e"),
            )
        }
    }
    editor.putBoolean(marker, true).commit()
}

private const val FLUTTER_LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"
private const val FLUTTER_DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGRvdWJsZS4="

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
