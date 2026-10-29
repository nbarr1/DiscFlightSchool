package com.discflightschool.app.data

import android.graphics.Bitmap
import android.util.Log
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.KeyframeData
import com.discflightschool.core.data.TrainingDataRepository
import com.discflightschool.core.model.TrainingSample
import java.io.File
import java.time.Instant
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody

/**
 * Turns user-marked keyframes into labelled training images, uploads them, and
 * keeps the on-device detector up to date.
 *
 * Every network path here is origin-checked before a byte is sent: the upload
 * carries the user's API key, and the model download replaces the file the
 * detector will execute.
 */
class TrainingDataCollector(
    private val repository: TrainingDataRepository,
    private val frameExtractor: FrameExtractor,
    private val dataDir: File,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .build(),
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private val imagesDir get() = File(dataDir, "images")
    private val labelsDir get() = File(dataDir, "labels")

    /**
     * Save one training sample per keyframe, returning how many were written.
     *
     * [trimStartMs] is where the marked range begins in the file.
     * `KeyframeData.frameIndex` counts from the trim start, while frame
     * extraction seeks by absolute time — without the offset, every sample
     * would pair an image from the wrong moment with a correct-looking label,
     * which is worse than collecting nothing at all.
     */
    suspend fun collectFromKeyframes(
        keyframes: List<KeyframeData>,
        videoPath: String,
        fps: Double,
        trimStartMs: Long = 0,
    ): Int = withContext(Dispatchers.IO) {
        if (!repository.isOptedIn.value || keyframes.isEmpty() || fps <= 0) return@withContext 0

        imagesDir.mkdirs()
        labelsDir.mkdirs()

        val saved = ArrayList<TrainingSample>()

        for (keyframe in keyframes) {
            runCatching {
                val id = generateId()
                val timeMs = trimStartMs + (keyframe.frameIndex / fps * 1000).roundToInt()

                val bitmap = frameExtractor.frameBitmapAt(videoPath, timeMs)
                    ?: return@runCatching

                val fullFile = File(imagesDir, "${id}_full.jpg")
                fullFile.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 90, it) }

                val imgW = bitmap.width
                val imgH = bitmap.height

                // Crop the disc region, keeping the bounds valid even on an
                // unusually small frame.
                val cropSize = min(TrainingDataRepository.CROP_PIXELS, min(imgW, imgH))
                if (cropSize <= 0) {
                    bitmap.recycle()
                    return@runCatching
                }
                val halfCrop = cropSize / 2
                val cropX = ((keyframe.x.coerceIn(0.0, 1.0) * imgW).roundToInt() - halfCrop)
                    .coerceIn(0, (imgW - cropSize).coerceAtLeast(0))
                val cropY = ((keyframe.y.coerceIn(0.0, 1.0) * imgH).roundToInt() - halfCrop)
                    .coerceIn(0, (imgH - cropSize).coerceAtLeast(0))
                val cropW = min(cropSize, imgW - cropX)
                val cropH = min(cropSize, imgH - cropY)

                val crop = Bitmap.createBitmap(bitmap, cropX, cropY, cropW, cropH)
                val cropFile = File(imagesDir, "${id}_crop.jpg")
                cropFile.outputStream().use { crop.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                crop.recycle()
                bitmap.recycle()

                val sample = TrainingSample(
                    id = id,
                    imagePath = fullFile.absolutePath,
                    cropPath = cropFile.absolutePath,
                    centerX = keyframe.x,
                    centerY = keyframe.y,
                    boxWidth = keyframe.boxWidth ?: TrainingDataRepository.DEFAULT_BOX_SIZE,
                    boxHeight = keyframe.boxHeight ?: TrainingDataRepository.DEFAULT_BOX_SIZE,
                    frameIndex = keyframe.frameIndex,
                    imageWidth = imgW,
                    imageHeight = imgH,
                    createdAt = Instant.now(),
                )

                File(labelsDir, "$id.txt").writeText(sample.toYoloLabel())
                saved += sample
            }.onFailure { Log.w(TAG, "Failed to save a training sample", it) }
        }

        repository.addSamples(saved)
        saved.size
    }

    /** Upload every sample not yet sent, returning how many the server accepted. */
    suspend fun uploadPending(): Int = withContext(Dispatchers.IO) {
        val uploadUri = repository.endpoint("/api/training/upload") ?: run {
            Log.w(TAG, "No usable training server URL configured for upload")
            return@withContext 0
        }
        val apiKey = repository.apiKey
        if (apiKey.isEmpty()) {
            Log.w(TAG, "No training API key configured for upload")
            return@withContext 0
        }

        val pending = repository.samples.value.filterNot { it.uploaded }
        if (pending.isEmpty()) return@withContext 0

        val uploaded = LinkedHashSet<String>()

        for (sample in pending) {
            runCatching {
                val fullFile = File(sample.imagePath)
                val cropFile = File(sample.cropPath)
                if (!fullFile.exists() || !cropFile.exists()) {
                    Log.w(TAG, "Skipping ${sample.id}: image files are missing")
                    return@runCatching
                }

                val body = MultipartBody.Builder()
                    .setType(MultipartBody.FORM)
                    .addFormDataPart("sample_id", sample.id)
                    .addFormDataPart("label", sample.toYoloLabel())
                    .addFormDataPart("image_width", sample.imageWidth.toString())
                    .addFormDataPart("image_height", sample.imageHeight.toString())
                    .addFormDataPart("app_version", APP_VERSION)
                    .addFormDataPart(
                        "full_image",
                        "${sample.id}_full.jpg",
                        fullFile.asRequestBody(JPEG),
                    )
                    .addFormDataPart(
                        "crop_image",
                        "${sample.id}_crop.jpg",
                        cropFile.asRequestBody(JPEG),
                    )
                    .build()

                val request = Request.Builder()
                    .url(uploadUri.toURL())
                    .addHeader("X-App-Key", apiKey)
                    .post(body)
                    .build()

                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful || isAlreadyStored(response.code, response.body?.string())) {
                        uploaded += sample.id
                    }
                }
            }.onFailure { Log.w(TAG, "Failed to upload sample ${sample.id}", it) }
        }

        repository.markUploaded(uploaded)
        uploaded.size
    }

    /** Write every stored sample and its label into one ZIP, or null on failure. */
    suspend fun exportTrainingData(outputDir: File): File? = withContext(Dispatchers.IO) {
        val samples = repository.samples.value
        if (samples.isEmpty()) return@withContext null

        runCatching {
            outputDir.mkdirs()
            val zipFile = File(outputDir, "disc_training_${System.currentTimeMillis()}.zip")

            ZipOutputStream(zipFile.outputStream().buffered()).use { zip ->
                fun addFile(file: File, entryPath: String) {
                    if (!file.exists()) return
                    zip.putNextEntry(ZipEntry(entryPath))
                    file.inputStream().use { it.copyTo(zip) }
                    zip.closeEntry()
                }

                for (sample in samples) {
                    addFile(File(sample.imagePath), "images/${sample.id}_full.jpg")
                    addFile(File(sample.cropPath), "images/${sample.id}_crop.jpg")
                    // Named after the image it labels: YOLO pairs images/X.jpg
                    // with labels/X.txt, and the server stores it the same way.
                    addFile(File(labelsDir, "${sample.id}.txt"), "labels/${sample.id}_full.txt")
                }

                val manifest = buildString {
                    append("{\n")
                    append("  \"exported_at\": \"${Instant.now()}\",\n")
                    append("  \"sample_count\": ${samples.size},\n")
                    append("  \"samples\": [")
                    append(samples.joinToString(",") { it.toJson().toString() })
                    append("]\n}")
                }
                zip.putNextEntry(ZipEntry("manifest.json"))
                zip.write(manifest.toByteArray())
                zip.closeEntry()
            }

            zipFile
        }.onFailure { Log.w(TAG, "Failed to export training data", it) }.getOrNull()
    }

    /**
     * Delete every collected sample, along with any detector model an earlier
     * version of the app downloaded into the data directory.
     */
    suspend fun clearAllData() = withContext(Dispatchers.IO) {
        runCatching {
            dataDir.listFiles()?.forEach { it.deleteRecursively() }
        }.onFailure { Log.w(TAG, "Failed to clear training data", it) }
        repository.clearSamples()
    }

    /**
     * Whether the server rejected an upload only because it already has the
     * sample — an earlier attempt that succeeded after its response was lost.
     * Treating that as a failure would retry the sample on every upload,
     * forever.
     */
    private fun isAlreadyStored(code: Int, body: String?): Boolean {
        if (code != 400 || body == null) return false
        val error = runCatching {
            json.parseToJsonElement(body).jsonObject["error"]?.jsonPrimitive?.content
        }.getOrNull()
        return error == SAMPLE_EXISTS_ERROR
    }

    private fun generateId(): String {
        val suffix = Random.nextInt(0, 100_000).toString().padStart(5, '0')
        return "${System.currentTimeMillis()}_$suffix"
    }

    private companion object {
        const val TAG = "TrainingDataCollector"
        const val APP_VERSION = "1.0.0"

        /**
         * The server's message for a sample it has already stored. Its
         * "already exists or is being uploaded" variant is deliberately not
         * matched: that upload may still fail.
         */
        const val SAMPLE_EXISTS_ERROR = "sample_id already exists"
        val JPEG = "image/jpeg".toMediaType()
    }
}
