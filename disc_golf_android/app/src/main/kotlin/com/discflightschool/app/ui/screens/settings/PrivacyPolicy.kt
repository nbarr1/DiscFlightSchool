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

/**
 * The canonical privacy policy copy.
 *
 * Kept as data rather than markup so the public copy in
 * `docs/privacy-policy.md`, which Google Play links to, can be checked
 * against it: PrivacyPolicyTest fails when the two differ.
 */
object PrivacyPolicy {

    const val LAST_UPDATED = "November 2026"

    const val INTRO = "Disc Flight School is a coaching and analysis tool. This policy " +
        "explains what the app accesses on your device, what it sends elsewhere, and " +
        "what choices you have."

    data class Section(val title: String, val body: String)

    val SECTIONS = listOf(
        Section(
            title = "Camera and photo library access",
            body = "Disc Flight School asks for camera access so you can record your " +
                "throws for Form Coach. Your device's camera app makes the recording, " +
                "including its sound. The app uses the system photo picker so you can " +
                "choose an existing video. Recorded video, extracted frames, and analysis " +
                "results stay on your device.",
        ),
        Section(
            title = "On-device analysis",
            body = "Pose detection (Form Coach) runs entirely on your device, using a " +
                "machine-learning model bundled with the app. Your video is not sent to a " +
                "server for analysis. " +
                "Questions you ask in the Knowledge Base are answered from the research " +
                "bundled with the app and never leave your device.",
        ),
        Section(
            title = "Training data from earlier versions",
            body = "Earlier versions of the app let you opt in to uploading still frames " +
                "from flight tracking to the Disc Flight School training server, to help " +
                "improve a disc-detection model. This version doesn't collect or upload " +
                "training data. Frames uploaded from an earlier version remain on the " +
                "training server until you ask for them to be deleted (see Contact).",
        ),
        Section(
            title = "What we don't collect",
            body = "Disc Flight School has no account system, no login, and no analytics or " +
                "advertising SDKs. We don't collect your name, email, or location, and we " +
                "don't track you across other apps or websites.",
        ),
        Section(
            title = "Data retention and deletion",
            body = "Locally stored recordings and analysis results remain on your device " +
                "until you delete them yourself (via your device's storage or gallery) or " +
                "uninstall the app.",
        ),
        Section(
            title = "Contact",
            body = "Questions or requests about this policy, including requests to delete " +
                "previously uploaded training data, can be sent by email to " +
                "comfreak455@gmail.com.",
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
                color = MaterialTheme.colorScheme.onSurfaceVariant,
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
