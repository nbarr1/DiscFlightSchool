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
│   ├── Pro baseline DB     assets/data/pro_baseline_db.json (v4.0)
│   └── Biomechanics API    GET /api/biomechanics/* from server
│
└── Knowledge Base          assets/data/knowledge_base.json

Python Server (server/)
├── Training data store     YOLO images + labels
├── Model versioning        .tflite served to app
├── Biomechanics DB         throws.json / players.json
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
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/training/upload` | Upload single sample from app |
| POST | `/api/training/bulk-import` | Ingest YOLO ZIP from data pipeline |
| GET | `/api/training/stats` | Sample counts by source |
| GET | `/api/training/sources` | App vs pipeline breakdown |
| GET | `/api/training/export` | Download full dataset as ZIP |
| POST | `/api/training/start` | Kick off YOLOv8 training run |
| GET | `/api/training/status` | Training run status |

### Biomechanics
| Method | Endpoint | Description |
|---|---|---|
| POST | `/api/biomechanics/sync` | Ingest `throws.json` from pipeline |
| GET | `/api/biomechanics/players` | Player list with aggregate stats |
| GET | `/api/biomechanics/player/{name}` | Full profile + throw records |
| GET | `/api/biomechanics/throw/{clip_id}` | Single throw record |
| GET | `/api/biomechanics/stats` | Dataset overview |

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
│   │   │   ├── biomechanics_service.dart
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
    ├── models/
    │   └── disc_detector_v*.tflite
    └── biomechanics/
        ├── throws.json
        └── players.json
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
pip install fastapi uvicorn ultralytics
uvicorn main:app --host 0.0.0.0 --port 8000
```

Set the server URL in the app via the `SERVER_URL` build environment variable or update the default in `biomechanics_service.dart`.

### Environment variables (server)

| Variable | Default | Description |
|---|---|---|
| `APP_API_KEY` | `disc-flight-school-v1` | Shared secret for app requests |
| `PIPELINE_API_KEY` | same as above | Separate key for data pipeline |
| `TRAINING_DEVICE` | `0` | GPU device for YOLOv8 (`0` = first GPU, `cpu` = CPU) |
| `HSA_OVERRIDE_GFX_VERSION` | `12.0.0` | Required for AMD RX 9060 XT (RDNA4) |

---

## Data Pipeline

The disc detection model and biomechanics database are built and maintained by a separate pipeline repo: [Discandformdetection](https://github.com/nbarr1/Discandformdetection).

That pipeline ingests JomezPro 2025 tournament footage, segments individual throws, annotates bounding boxes via CVAT, and runs ViTPose-B pose extraction. Outputs sync to this server via:

```bash
python scripts/sync_to_app.py --all --server http://your-server:8000
```

After syncing annotations, retrain the disc detector:

```bash
curl -X POST http://your-server:8000/api/training/start \
  -H "X-App-Key: disc-flight-school-v1"
```

The app checks `/api/model/version` on launch and downloads any updated `.tflite` automatically.

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
