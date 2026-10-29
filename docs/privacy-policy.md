# Disc Flight School privacy policy

Last updated: October 2026

Disc Flight School is a coaching and analysis tool. This policy explains what the app accesses on your device, what it sends elsewhere, and what choices you have.

## Camera and photo library access

Disc Flight School asks for camera access so you can record your throws for Form Coach and Flight Tracker. Your device's camera app makes the recording, including its sound. The app uses the system photo picker so you can choose an existing video, and saves analyzed videos to your gallery. By default, recorded video, extracted frames, and analysis results stay on your device. A video is uploaded only when you choose Auto-detect or cloud flight tracing, or opt in to training data collection (below).

## On-device analysis

Pose detection (Form Coach) and marking the disc by hand in the Flight Tracker run entirely on your device, using bundled machine-learning models where needed. Your video is not sent to a server when you mark the disc by hand. When Auto-detect can't reach the server, it also runs on your device. Questions you ask in the Knowledge Base are answered from the research bundled with the app and never leave your device.

## Optional: cloud disc detection

When you tap "Auto-detect" in the flight tracker, or "Trace in cloud," the selected video is sent to the Disc Flight School server, which securely submits it to Roboflow to detect the disc. For Auto-detect, only the trimmed part of the video is processed, and your device receives the disc's position in each frame. The source upload is removed after processing or cancellation. The results, including an annotated copy of the video, remain on the server so your device can download them, and the server deletes them 24 hours after processing finishes. Roboflow handles the video under its own privacy policy and data retention terms. If you do not want the video processed by these services, mark the disc by hand instead.

## Optional: training data collection

In Training Settings, you can opt in to "Help improve disc tracking." When enabled, still frames you manually mark during flight tracking are saved on your device. You can then choose to upload them to the Disc Flight School training server to help improve the disc-detection model, or export them yourself as a ZIP file to share however you like. Uploads only happen when you tap "Upload," only over an encrypted (HTTPS) connection, and only once you have set a training API key. Uploaded images are used to train future versions of the on-device detection model. "Clear all training data" in Training Settings deletes the locally stored copies immediately, but does not retract copies already uploaded to the server.

## What we don't collect

Disc Flight School has no account system, no login, and no analytics or advertising SDKs. We don't collect your name, email, or location, and we don't track you across other apps or websites.

## Data retention and deletion

Locally stored recordings, analysis results, and training samples remain on your device until you delete them yourself (via your device's storage/gallery, or "Clear all training data" in Training Settings) or uninstall the app. Training samples you have uploaded are retained on the training server to improve future model versions.

## Contact

Questions or requests about this policy, including requests to delete previously uploaded training data, can be sent by email to comfreak455@gmail.com.
