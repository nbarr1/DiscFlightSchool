package com.discflightschool.app.data

import android.graphics.Bitmap
import android.util.Log
import com.discflightschool.app.video.FrameExtractor
import com.discflightschool.core.data.KeyframeData
import com.discflightschool.core.data.TrainingDataRepository
import com.discflightschool.core.model.DetectorModelVersion
import com.discflightschool.core.model.TrainingSample
import com.discflightschool.core.net.ServerUris
import java.io.File
import java.net.URI
import java.security.MessageDigest
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
    private val modelsDir get() = File(dataDir, "models")

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
                    if (response.isSuccessful) uploaded += sample.id
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
                    addFile(File(labelsDir, "${sample.id}.txt"), "labels/${sample.id}.txt")
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

    /** Delete every collected sample, keeping any downloaded model. */
    suspend fun clearAllData() = withContext(Dispatchers.IO) {
        runCatching {
            dataDir.listFiles()?.forEach { entry ->
                if (entry.name != "models") entry.deleteRecursively()
            }
        }.onFailure { Log.w(TAG, "Failed to clear training data", it) }
        repository.clearSamples()
    }

    /** The server's advertised model version, or null when it cannot be read. */
    suspend fun remoteModelVersion(): DetectorModelVersion? = withContext(Dispatchers.IO) {
        val uri = repository.endpoint("/api/model/version") ?: return@withContext null
        runCatching {
            client.newCall(Request.Builder().url(uri.toURL()).build()).execute().use { response ->
                if (!response.isSuccessful) return@runCatching null
                val body = response.body?.string() ?: return@runCatching null
                DetectorModelVersion.fromJson(json.parseToJsonElement(body).jsonObject)
            }
        }.onFailure { Log.w(TAG, "Failed to check the model version", it) }.getOrNull()
    }

    /** Whether the server advertises a model other than the installed one. */
    suspend fun checkForModelUpdate(): Boolean {
        val remote = remoteModelVersion() ?: return false
        return remote.hasModel && remote.version != repository.modelVersion
    }

    /**
     * Download the advertised model, verifying its hash before installing it.
     *
     * The server normally returns a relative path. An absolute URL pointing
     * anywhere other than the configured origin is refused: this file is handed
     * straight to the interpreter, so a redirect to another host — or to another
     * port on the same host — is a code-execution path, not a convenience.
     */
    suspend fun downloadModel(): Boolean = withContext(Dispatchers.IO) {
        val remote = remoteModelVersion() ?: return@withContext false
        if (!remote.hasModel) return@withContext false

        val serverUri = runCatching { URI(repository.serverUrl.value.trim()) }.getOrNull()
            ?: return@withContext false
        val modelUri = runCatching { serverUri.resolve(remote.url) }.getOrNull()
            ?: return@withContext false

        if (!ServerUris.isSameOrigin(serverUri, modelUri)) {
            Log.w(TAG, "Rejected a model URL outside the configured server: $modelUri")
            return@withContext false
        }

        runCatching {
            client.newCall(Request.Builder().url(modelUri.toURL()).build()).execute().use { response ->
                if (!response.isSuccessful) return@runCatching false
                val bytes = response.body?.bytes() ?: return@runCatching false

                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(bytes)
                    .joinToString("") { "%02x".format(it) }
                if (!digest.equals(remote.sha256, ignoreCase = true)) {
                    Log.w(TAG, "Downloaded model hash mismatch: $digest")
                    return@runCatching false
                }

                modelsDir.mkdirs()
                File(modelsDir, "disc_detector.tflite").writeBytes(bytes)
                repository.modelVersion = remote.version
                Log.i(TAG, "Installed detector model version ${remote.version}")
                true
            }
        }.onFailure { Log.w(TAG, "Failed to download the model", it) }.getOrDefault(false)
    }

    private fun generateId(): String {
        val suffix = Random.nextInt(0, 100_000).toString().padStart(5, '0')
        return "${System.currentTimeMillis()}_$suffix"
    }

    private companion object {
        const val TAG = "TrainingDataCollector"
        const val APP_VERSION = "1.0.0"
        val JPEG = "image/jpeg".toMediaType()
    }
}
