package com.discflightschool.app.data

import java.io.IOException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

/**
 * Runs the call on OkHttp's own threads and returns its status and body.
 * Cancelling the caller cancels the request, so leaving the screen doesn't
 * leave a request running.
 */
internal suspend fun Call.await(): Pair<Int, String> = suspendCancellableCoroutine { continuation ->
    continuation.invokeOnCancellation { cancel() }
    enqueue(
        object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                continuation.resumeWith(Result.failure(e))
            }

            override fun onResponse(call: Call, response: Response) {
                continuation.resumeWith(
                    runCatching { response.use { it.code to it.body?.string().orEmpty() } },
                )
            }
        },
    )
}
