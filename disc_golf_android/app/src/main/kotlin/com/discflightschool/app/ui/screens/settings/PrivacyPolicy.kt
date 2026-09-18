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
                "your device. A video is uploaded only when you explicitly choose cloud " +
                "flight tracing or training data collection (below).",
        ),
        Section(
            title = "On-device analysis",
            body = "Pose detection (Form Coach) and the Flight Tracker's on-device option run " +
                "entirely on your device using bundled machine-learning models. Your video " +
                "is not sent to a server when you choose the on-device tracker.",
        ),
        Section(
            title = "Optional: cloud flight tracing",
            body = "When you tap \"Trace in cloud,\" the selected video is sent to the Disc " +
                "Flight School server, which securely submits it to Roboflow to detect and " +
                "draw the disc trajectory. The source upload is removed after processing or " +
                "cancellation. The annotated result remains on the server so your device can " +
                "download it; contact the server operator for its retention and deletion " +
                "policy. Do not use cloud tracing if you do not want the video processed by " +
                "these services.",
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
            title = "Optional: AI Search (Anthropic)",
            body = "The Knowledge Base screen offers an \"AI Search\" feature that you can " +
                "enable by adding your own Anthropic API key in Training Settings. If you use " +
                "it, your search question is sent directly from your device to Anthropic's " +
                "Claude API to generate an answer. Your API key is stored only in your " +
                "device's secure credential storage, never on our servers. Anthropic's " +
                "handling of that request is governed by Anthropic's own privacy policy, not " +
                "this one.",
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
