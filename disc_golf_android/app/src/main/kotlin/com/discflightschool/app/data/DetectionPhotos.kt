package com.discflightschool.app.data

import android.content.ContentResolver
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import java.io.ByteArrayOutputStream
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** A picked photo scaled for upload, and the JPEG that is sent. */
class DetectionPhoto(val bitmap: Bitmap, val jpeg: ByteArray)

/**
 * Decode the photo at [uri] with its longer side at most [maxSide], and encode
 * it as JPEG. Returns null when the photo can't be read.
 *
 * Re-encoding means the server always receives a JPEG it accepts, even when
 * the gallery hands back HEIC, and keeps the upload well below its size limit.
 */
suspend fun loadDetectionPhoto(
    resolver: ContentResolver,
    uri: Uri,
    maxSide: Int = 1280,
): DetectionPhoto? = withContext(Dispatchers.IO) {
    runCatching {
        val bitmap = decodeScaled(resolver, uri, maxSide) ?: return@runCatching null
        val jpeg = ByteArrayOutputStream().use { out ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 90, out)
            out.toByteArray()
        }
        DetectionPhoto(bitmap, jpeg)
    }.getOrNull()
}

private fun decodeScaled(resolver: ContentResolver, uri: Uri, maxSide: Int): Bitmap? {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
        // ImageDecoder applies the photo's EXIF rotation. Older releases skip
        // that, but the boxes are drawn on the same bitmap that was sent, so
        // they line up either way.
        return ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            // Software, because the JPEG encoder and Compose both read the pixels.
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            val scale = min(1.0, maxSide.toDouble() / max(info.size.width, info.size.height))
            decoder.setTargetSize(
                max(1, (info.size.width * scale).roundToInt()),
                max(1, (info.size.height * scale).roundToInt()),
            )
        }
    }
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
    val longest = max(bounds.outWidth, bounds.outHeight)
    if (longest <= 0) return null
    // Subsample by powers of two while decoding, then scale the rest exactly.
    var sample = 1
    while (longest / (sample * 2) >= maxSide) sample *= 2
    val options = BitmapFactory.Options().apply { inSampleSize = sample }
    val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) }
        ?: return null
    val scale = maxSide.toDouble() / max(decoded.width, decoded.height)
    if (scale >= 1.0) return decoded
    val scaled = Bitmap.createScaledBitmap(
        decoded,
        max(1, (decoded.width * scale).roundToInt()),
        max(1, (decoded.height * scale).roundToInt()),
        true,
    )
    if (scaled !== decoded) decoded.recycle()
    return scaled
}
