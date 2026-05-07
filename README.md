# DiscFlightSchool

A multi-module Flutter application for disc golf players — combining on-device disc flight tracking, professional form analysis, and a continuously improving detection model trained on real tournament footage.

---

## Modules

### Flight Tracker
Real-time disc detection and flight path visualization using an on-device TFLite model. The model is trained on annotated JomezPro tournament footage and updated over-the-air as the training dataset grows.

### Form Coach
Biomechanics analysis of your throwing form. Record or upload a video, and the app detects your pose frame-by-frame using Google ML Kit, calculates joint angles, and compares them against a database of measured professional throws.

**Supported throw types:** Backhand (BH) · Forehand (FH)
**Left-handed support:** angle analysis mirrors automatically so the throwing arm is always scored as dominant

**Pro reference database (v4.0)** — manually annotated from 120fps slow-motion footage:
| Player | PDGA Rating | BH | FH |
|---|---|---|---|
| Paul McBeth | 1058 | ✓ | ✓ |
| Ricky Wysocki | 1051 | ✓ | ✓ |
| Calvin Heimburg | 1045 | ✓ | ✓ |
| Eagle McMahon | 1040 | ✓ | ✓ |
| Gannon Buhr | 1040 | ✓ | ✓ |

**Angles analyzed per phase:** elbow flexion · shoulder flexion · lead/trail knee flexion · trunk lateral tilt · X-factor (hip-shoulder separation) · off-arm position

**Throw phases:**
- Backhand: Reach Back → Power Pocket → Release → Follow Through
- Forehand: Wind Up → Power Pocket → Release → Follow Through

**Pose correction:** If the auto-detected skeleton is off, three correction modes let you fix it — individual joint drag, move-all skeleton shift, or guided sequential re-placement with Catmull-Rom interpolation between corrected frames.

### Knowledge Base
In-app articles on disc golf biomechanics, technique cues, and equipment. Articles are linked directly from coaching suggestions so you can read deeper on any flagged issue.

---

## Architecture

```
Flutter App (disc_golf_app/)
│
├── Flight Tracker          On-device TFLite inference
│   └── disc_detector.tflite   Updated via server OTA
│
├── Form Coach              Google ML Kit pose detection
│   └── Pro baseline DB     assets/data/pro_baseline_db.json (v4.0)
│
└── Knowledge Base          assets/data/knowledge_base.json

Python Server (server/)
├── Training data store     YOLO images + labels
├── Model versioning        .tflite served to app
└── Training runner         YOLOv8 → TFLite pipeline

Data Pipeline (Discandformdetection — separate repo)
├── JomezPro ingestion      yt-dlp, 2025 season
├── Shot segmentation       PySceneDetect + optical flow + audio
├── CVAT annotation         Bounding boxes → YOLO/COCO export
├── ViTPose-B extraction    Phase angles, X-factor, timing
└── sync_to_app.py          Pushes datasets to this server
```

---

## Server API

Run with: `uvicorn main:app --host 0.0.0.0 --port 8000`

### Model distribution
| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/model/version` | Current model version + SHA-256 |
| GET | `/api/model/download` | Download latest `.tflite` |

### Training data
| Method | Endpoint | Description | Auth |
|---|---|---|---|
| POST | `/api/training/upload` | Upload one validated JPEG/PNG sample plus one YOLO label row | `X-App-Key` |
| GET | `/api/training/stats` | Dataset counts | none |
| GET | `/api/training/export` | Download full dataset as ZIP | `X-App-Key` |
| POST | `/api/training/start` | Kick off YOLOv8 training run | `X-App-Key` |
| GET | `/api/training/status` | Training run status | none |

### Not currently implemented
The previous README mentioned bulk-import and biomechanics sync endpoints. They are not present in `server/main.py`; treat them as future work unless they are added with tests and OpenAPI documentation.

---

## Project Structure

```
DiscFlightSchool/
├── disc_golf_app/
│   ├── lib/
│   │   ├── models/
│   │   │   └── form_analysis.dart
│   │   ├── screens/
│   │   │   ├── form_coach/
│   │   │   │   ├── form_coach_screen.dart
│   │   │   │   ├── posture_analysis_screen.dart
│   │   │   │   ├── pose_correction_screen.dart
│   │   │   │   ├── phase_comparison_screen.dart
│   │   │   │   ├── phase_frame_selector_screen.dart
│   │   │   │   ├── form_history_screen.dart
│   │   │   │   ├── video_trim_screen.dart
│   │   │   │   └── comparison_screen.dart
│   │   │   └── knowledge_base/
│   │   ├── services/
│   │   │   ├── posture_analysis_service.dart
│   │   │   ├── disc_detection_service.dart
│   │   │   ├── training_data_service.dart
│   │   │   ├── video_service.dart
│   │   │   ├── video_frame_extractor.dart
│   │   │   ├── form_history_service.dart
│   │   │   ├── knowledge_base_service.dart
│   │   │   └── feedback_service.dart
│   │   ├── utils/
│   │   │   ├── pro_data_parser.dart
│   │   │   ├── angle_calculator.dart
│   │   │   └── constants.dart
│   │   └── widgets/
│   │       └── skeleton_overlay.dart
│   └── assets/
│       └── data/
│           ├── pro_baseline_db.json
│           └── knowledge_base.json
└── server/
    ├── main.py
    ├── dataset/
    │   ├── images/train/
    │   └── labels/train/
    └── models/
        └── disc_detector_v*.tflite
```

---

## Setup

### Flutter app

```bash
cd disc_golf_app
flutter pub get
flutter run
```

Requires Flutter 3.x. Tested on Android; iOS compatible.

### Server

```bash
cd server
pip install -r requirements.txt
export APP_API_KEY=replace-with-a-long-random-secret
uvicorn main:app --host 0.0.0.0 --port 8000
```

The server refuses to start without `APP_API_KEY`. Enter the same private key in the app's Training Settings > Advanced section before uploading training samples. Do not commit or publish production API keys.

### Environment variables (server)

| Variable | Required | Description |
|---|---|---|
| `APP_API_KEY` | Yes | Private key required by upload/export/training endpoints. No default is provided. |
| `CORS_ALLOW_ORIGINS` | No | Comma-separated browser origins allowed by FastAPI CORS. Empty by default. |
| `MAX_UPLOAD_BYTES` | No | Maximum bytes per uploaded image; defaults to 8 MiB. |

---

## Data Pipeline

The disc detection model and pro-reference data are built and maintained by a separate pipeline repo: [Discandformdetection](https://github.com/nbarr1/Discandformdetection).

That pipeline ingests JomezPro 2025 tournament footage, segments individual throws, annotates bounding boxes via CVAT, and runs ViTPose-B pose extraction. Outputs sync to this server via:

```bash
python scripts/sync_to_app.py --all --server http://your-server:8000
```

After syncing annotations, retrain the disc detector:

```bash
curl -X POST http://your-server:8000/api/training/start \
  -H "X-App-Key: $APP_API_KEY"
```

The app can check `/api/model/version` from Training Settings, verifies the downloaded model's SHA-256, and reloads the model after a successful update.

---

## Releases

| Version | Notes |
|---|---|
| v1.1.0 | Fix flight tracker OOM crash, banner persistence, async safety |
| v1.0.0 | Initial release |

---

## Notes on the pro reference database

`pro_baseline_db.json` (v4.0) contains manually annotated phase snapshots from 120fps slow-motion footage. Angles are computed geometrically (atan2/dot-product from normalized 2D landmarks) with ANSUR II anthropometric depth estimation.

Known limitations:
- All pros are right-handed — left-handed comparison mirrors angle keys automatically
- Ricky Wysocki FH power pocket and release: lead leg occluded, some angles fall back to group mean
- Eagle McMahon FH: mirror-image camera angle — angles are valid but R/L landmark mapping differs
- Calvin Heimburg FH: posterior camera view — trunk tilt not directly comparable to side-view measurements
- FH baselines have higher variance than BH due to mixed camera angles across players

Deviation scoring compares your joint angles against the pro mean ± SD at each measured phase. Suggestions are flagged when your angle exceeds 1 SD from the reference range.
