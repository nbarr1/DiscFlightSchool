package com.discflightschool.core.data

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * Reading what the Flutter build of this app left behind.
 *
 * The application ID did not change, so an install upgrading to the native
 * client keeps the Flutter version's data directory — but not its data, unless
 * it is copied across. Flutter's `shared_preferences` writes to its own
 * `FlutterSharedPreferences` file, prefixes every key with `flutter.`, and
 * encodes doubles and string lists as tagged strings. Without this the upgrade
 * looks like a fresh install: onboarding runs again, and saved rounds, form
 * history, and the training opt-in appear to be gone.
 *
 * The prefixes and encodings below are taken from the plugin the Flutter client
 * pinned (`shared_preferences_android` 2.4.21), not guessed.
 */
object FlutterPreferences {

    /** The preferences file the Flutter plugin writes to. */
    const val FILE_NAME = "FlutterSharedPreferences"

    /** Every key the Dart side writes carries this prefix. */
    const val KEY_PREFIX = "flutter."

    /** Tag for a double, followed by its `Double.toString` form. */
    const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"

    /** Tag for a string list serialized on the platform side, then base64'd. */
    const val LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

    /**
     * Tag for a string list encoded as JSON in Dart, which is what current
     * plugin versions write. The `!` cannot appear in base64, which is what
     * keeps the two list forms apart.
     */
    const val JSON_LIST_PREFIX = LIST_PREFIX + "!"

    /** Tag for a BigInteger. Nothing in this app ever stored one. */
    const val BIG_INTEGER_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBCaWdJbnRlZ2Vy"

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Copy [legacy] — the raw contents of the Flutter preferences file — into
     * [into], returning how many entries were carried across.
     *
     * [platformListDecoder] handles the older base64 list form, which needs
     * Java deserialization and so is supplied by the caller. Returning null
     * from it skips that entry rather than failing the whole migration: one
     * unreadable value should not cost a user the rest of their history.
     */
    fun migrate(
        legacy: Map<String, Any?>,
        into: KeyValueStore,
        platformListDecoder: (String) -> List<String>? = { null },
    ): Int {
        var copied = 0

        for ((prefixedKey, rawValue) in legacy) {
            if (!prefixedKey.startsWith(KEY_PREFIX)) continue
            val key = prefixedKey.removePrefix(KEY_PREFIX)
            if (key.isEmpty()) continue

            when (rawValue) {
                is Boolean -> {
                    into.putBoolean(key, rawValue)
                    copied++
                }

                is String -> when {
                    rawValue.startsWith(JSON_LIST_PREFIX) -> {
                        decodeJsonList(rawValue.removePrefix(JSON_LIST_PREFIX))?.let { list ->
                            into.putStringList(key, list)
                            copied++
                        }
                    }

                    rawValue.startsWith(LIST_PREFIX) -> {
                        platformListDecoder(rawValue.removePrefix(LIST_PREFIX))?.let { list ->
                            into.putStringList(key, list)
                            copied++
                        }
                    }

                    rawValue.startsWith(DOUBLE_PREFIX) -> {
                        rawValue.removePrefix(DOUBLE_PREFIX).toDoubleOrNull()?.let { value ->
                            into.putDouble(key, value)
                            copied++
                        }
                    }

                    // Nothing in this app stored a BigInteger, and there is no
                    // typed slot to put one in.
                    rawValue.startsWith(BIG_INTEGER_PREFIX) -> Unit

                    else -> {
                        into.putString(key, rawValue)
                        copied++
                    }
                }

                // Flutter stores ints as longs. No repository reads an int, so
                // there is nothing to carry across.
                else -> Unit
            }
        }

        return copied
    }

    private fun decodeJsonList(encoded: String): List<String>? = runCatching {
        json.parseToJsonElement(encoded).jsonArray.map { it.jsonPrimitive.content }
    }.getOrNull()
}
