/// Canonical privacy policy copy for Disc Flight School.
///
/// This is the single source of truth for the policy text — the in-app
/// screen (`screens/settings/privacy_policy_screen.dart`) renders it
/// directly, and any future public web page should reuse these same
/// constants rather than maintaining a second copy that can drift.
library;

const String kPrivacyPolicyLastUpdated = 'August 2026';

const String kPrivacyPolicyIntro =
    'Disc Flight School is a coaching and analysis tool. This policy '
    'explains what the app accesses on your device, what it sends '
    'elsewhere, and what choices you have.';

class PrivacyPolicySection {
  final String title;
  final String body;

  const PrivacyPolicySection({required this.title, required this.body});
}

const List<PrivacyPolicySection> kPrivacyPolicySections = [
  PrivacyPolicySection(
    title: 'Camera, microphone, and photo library access',
    body:
        'Disc Flight School asks for camera and microphone access so you '
        'can record your throws for Form Coach and Flight Tracker, and for '
        'photo library access so you can pick an existing video or save an '
        'analyzed one. By default, recorded video, extracted frames, and '
        'analysis results stay on your device — the app does not upload '
        'them anywhere unless you explicitly opt in to training data '
        'collection (below).',
  ),
  PrivacyPolicySection(
    title: 'On-device analysis',
    body:
        'Pose detection (Form Coach) and disc detection (Flight Tracker) '
        'both run entirely on your device using a bundled machine-learning '
        'model. Your video is not sent to a server for this analysis.',
  ),
  PrivacyPolicySection(
    title: 'Optional: training data collection',
    body:
        'In Training Settings, you can opt in to "Help improve disc '
        'tracking." When enabled, still frames you manually mark during '
        'flight tracking are saved on your device. You can then choose to '
        'upload them to the Disc Flight School training server to help '
        'improve the disc-detection model, or export them yourself as a '
        'ZIP file to share however you like. Uploads only happen when you '
        'tap "Upload," only over an encrypted (HTTPS) connection, and only '
        'once you have set a training API key. Uploaded images are used to '
        'train future versions of the on-device detection model. '
        '"Clear all training data" in Training Settings deletes the '
        'locally stored copies immediately, but does not retract copies '
        'already uploaded to the server.',
  ),
  PrivacyPolicySection(
    title: 'Optional: AI Search (Anthropic)',
    body:
        'The Knowledge Base screen offers an "AI Search" feature that you '
        'can enable by adding your own Anthropic API key in Training '
        'Settings. If you use it, your search question is sent directly '
        'from your device to Anthropic\'s Claude API to generate an '
        'answer. Your API key is stored only in your device\'s secure '
        'credential storage, never on our servers. Anthropic\'s handling '
        'of that request is governed by Anthropic\'s own privacy policy, '
        'not this one.',
  ),
  PrivacyPolicySection(
    title: 'What we don\'t collect',
    body:
        'Disc Flight School has no account system, no login, and no '
        'analytics or advertising SDKs. We don\'t collect your name, '
        'email, or location, and we don\'t track you across other apps or '
        'websites.',
  ),
  PrivacyPolicySection(
    title: 'Data retention and deletion',
    body:
        'Locally stored recordings, analysis results, and training '
        'samples remain on your device until you delete them yourself '
        '(via your device\'s storage/gallery, or "Clear all training '
        'data" in Training Settings) or uninstall the app. Training '
        'samples you have uploaded are retained on the training server to '
        'improve future model versions.',
  ),
  PrivacyPolicySection(
    title: 'Contact',
    body:
        'Disc Flight School is developed in the open. Questions or '
        'requests about this policy — including requests about '
        'previously uploaded training data — can be raised as an issue on '
        'the project\'s GitHub repository.',
  ),
];
