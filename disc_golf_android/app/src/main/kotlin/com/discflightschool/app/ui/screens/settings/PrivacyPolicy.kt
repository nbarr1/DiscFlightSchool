package com.discflightschool.app.ui.screens.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.discflightschool.app.ui.components.AppTopBar
import com.discflightschool.app.ui.theme.AppColors

/**
 * The canonical privacy policy copy.
 *
 * Kept as data rather than markup so a future public web page can reuse the
 * same text instead of maintaining a second copy that drifts.
 */
object PrivacyPolicy {

    const val LAST_UPDATED = "September 2026"

    const val INTRO = "Disc Flight School is a coaching and analysis tool. This policy " +
        "explains what the app accesses on your device, what it sends elsewhere, and " +
        "what choices you have."

    data class Section(val title: String, val body: String)

    val SECTIONS = listOf(
        Section(
            title = "Camera, microphone, and photo library access",
            body = "Disc Flight School asks for camera and microphone access so you can " +
                "record your throws for Form Coach and Flight Tracker, and for photo " +
                "library access so you can pick an existing video or save an analyzed one. " +
                "By default, recorded video, extracted frames, and analysis results stay on " +
                "your device. A video is uploaded only when you choose Auto-detect or cloud " +
                "flight tracing, or opt in to training data collection (below).",
        ),
        Section(
            title = "On-device analysis",
            body = "Pose detection (Form Coach) and marking the disc by hand in the Flight " +
                "Tracker run entirely on your device, using bundled machine-learning models " +
                "where needed. Your video is not sent to a server when you mark the disc by " +
                "hand. When Auto-detect can't reach the server, it also runs on your device. " +
                "Questions you ask in the Knowledge Base are answered from the research " +
                "bundled with the app and never leave your device.",
        ),
        Section(
            title = "Optional: cloud disc detection",
            body = "When you tap \"Auto-detect\" in the flight tracker, or \"Trace in " +
                "cloud,\" the selected video is sent to the Disc Flight School server, which " +
                "securely submits it to Roboflow to detect the disc. For Auto-detect, only " +
                "the trimmed part of the video is processed, and your device receives the " +
                "disc's position in each frame. The source upload is removed after " +
                "processing or cancellation. The results, including an annotated copy of " +
                "the video, remain on the server so your device can download them, and the " +
                "server deletes them 24 hours after processing finishes. If you do not want " +
                "the video processed by these services, mark the disc by hand instead.",
        ),
        Section(
            title = "Optional: training data collection",
            body = "In Training Settings, you can opt in to \"Help improve disc tracking.\" " +
                "When enabled, still frames you manually mark during flight tracking are " +
                "saved on your device. You can then choose to upload them to the Disc Flight " +
                "School training server to help improve the disc-detection model, or export " +
                "them yourself as a ZIP file to share however you like. Uploads only happen " +
                "when you tap \"Upload,\" only over an encrypted (HTTPS) connection, and only " +
                "once you have set a training API key. Uploaded images are used to train " +
                "future versions of the on-device detection model. \"Clear all training data\" " +
                "in Training Settings deletes the locally stored copies immediately, but does " +
                "not retract copies already uploaded to the server.",
        ),
        Section(
            title = "What we don't collect",
            body = "Disc Flight School has no account system, no login, and no analytics or " +
                "advertising SDKs. We don't collect your name, email, or location, and we " +
                "don't track you across other apps or websites.",
        ),
        Section(
            title = "Data retention and deletion",
            body = "Locally stored recordings, analysis results, and training samples remain " +
                "on your device until you delete them yourself (via your device's " +
                "storage/gallery, or \"Clear all training data\" in Training Settings) or " +
                "uninstall the app. Training samples you have uploaded are retained on the " +
                "training server to improve future model versions.",
        ),
        Section(
            title = "Contact",
            body = "Disc Flight School is developed in the open. Questions or requests about " +
                "this policy — including requests about previously uploaded training data — " +
                "can be raised as an issue on the project's GitHub repository.",
        ),
    )
}

@Composable
fun PrivacyPolicyScreen(onBack: () -> Unit) {
    Scaffold(topBar = { AppTopBar(title = "Privacy policy", onBack = onBack) }) { padding ->
        Column(
            modifier = Modifier
                .padding(padding)
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
        ) {
            Text(
                "Last updated: ${PrivacyPolicy.LAST_UPDATED}",
                style = MaterialTheme.typography.labelMedium,
                color = AppColors.Muted,
            )
            Spacer(Modifier.height(12.dp))
            Text(PrivacyPolicy.INTRO, style = MaterialTheme.typography.bodyMedium)
            Spacer(Modifier.height(24.dp))

            PrivacyPolicy.SECTIONS.forEach { section ->
                Text(
                    section.title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.Bold,
                )
                Spacer(Modifier.height(6.dp))
                Text(section.body, style = MaterialTheme.typography.bodyMedium)
                Spacer(Modifier.height(20.dp))
            }
        }
    }
}
