import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:image/image.dart' as img;
import '../models/training_sample.dart';

/// Keyframe data passed from the manual tracking screen.
class KeyframeData {
  final int frameIndex;
  final double x; // Normalized 0-1
  final double y; // Normalized 0-1
  final double? boxWidth; // Normalized 0-1, null = use default
  final double? boxHeight; // Normalized 0-1, null = use default

  KeyframeData({
    required this.frameIndex,
    required this.x,
    required this.y,
    this.boxWidth,
    this.boxHeight,
  });
}

/// Manages training data collection from manual disc tracking,
/// local persistence, upload to server, and model version updates.
class TrainingDataService extends ChangeNotifier {
  static const String _optInKey = 'training_opt_in';
  static const String _serverUrlKey = 'training_server_url';
  static const String _modelVersionKey = 'disc_model_version';
  static const String _manifestFile = 'manifest.json';
  static const String _defaultServerUrl = 'https://discflightschool.onrender.com';
  static const double _defaultBoxSize = 0.03; // Normalized bounding box size
  static const int _cropPixels = 64; // Crop region size in pixels

  List<TrainingSample> _samples = [];
  bool _isOptedIn = false;
  String _serverUrl = _defaultServerUrl;
  bool _loaded = false;

  bool get isOptedIn => _isOptedIn;
  String get serverUrl => _serverUrl;
  List<TrainingSample> get samples => List.unmodifiable(_samples);
  int get totalSamples => _samples.length;
  int get uploadedSamples => _samples.where((s) => s.uploaded).length;
  int get pendingSamples => _samples.where((s) => !s.uploaded).length;

  /// Initialize: load preferences and manifest.
  Future<void> init() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    _isOptedIn = prefs.getBool(_optInKey) ?? false;
    final storedUrl = prefs.getString(_serverUrlKey) ?? '';
    _serverUrl = storedUrl.isEmpty ? _defaultServerUrl : storedUrl;
    await _loadManifest();
    _loaded = true;
    notifyListeners();
  }

  /// Toggle opt-in for training data collection.
  Future<void> setOptIn(bool value) async {
    _isOptedIn = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_optInKey, value);
    notifyListeners();
  }

  /// Set the server URL for uploads and model updates.
  Future<void> setServerUrl(String url) async {
    _serverUrl = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url);
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Data Collection
  // ---------------------------------------------------------------------------

  /// Collect training samples from manually marked keyframes.
  /// Returns the number of samples successfully saved.
  Future<int> collectFromKeyframes(
    List<KeyframeData> keyframes,
    String videoPath,
    double fps,
  ) async {
    if (!_isOptedIn || keyframes.isEmpty) return 0;

    final dataDir = await _getDataDir();
    final imagesDir = Directory('${dataDir.path}/images');
    final labelsDir = Directory('${dataDir.path}/labels');
    if (!await imagesDir.exists()) await imagesDir.create(recursive: true);
    if (!await labelsDir.exists()) await labelsDir.create(recursive: true);

    int saved = 0;

    for (final kf in keyframes) {
      try {
        final id = _generateId();
        final timeMs = (kf.frameIndex / fps * 1000).round();

        // Extract full frame at keyframe timestamp
        final fullPath = await VideoThumbnail.thumbnailFile(
          video: videoPath,
          thumbnailPath: imagesDir.path,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 640,
          timeMs: timeMs,
          quality: 90,
        );

        if (fullPath == null) continue;

        // Rename to our naming convention
        final fullDest = '${imagesDir.path}/${id}_full.jpg';
        await File(fullPath).rename(fullDest);

        // Decode image to get dimensions and create crop
        final bytes = await File(fullDest).readAsBytes();
        final decoded = img.decodeJpg(bytes);
        if (decoded == null) continue;

        final imgW = decoded.width;
        final imgH = decoded.height;

        // Crop disc region
        final cropCenterX = (kf.x * imgW).round();
        final cropCenterY = (kf.y * imgH).round();
        final halfCrop = _cropPixels ~/ 2;
        final cropX = (cropCenterX - halfCrop).clamp(0, imgW - _cropPixels);
        final cropY = (cropCenterY - halfCrop).clamp(0, imgH - _cropPixels);
        final cropW = min(_cropPixels, imgW - cropX);
        final cropH = min(_cropPixels, imgH - cropY);

        final cropped = img.copyCrop(
          decoded,
          x: cropX,
          y: cropY,
          width: cropW,
          height: cropH,
        );
        final cropDest = '${imagesDir.path}/${id}_crop.jpg';
        await File(cropDest).writeAsBytes(img.encodeJpg(cropped, quality: 95));

        // Write YOLO label
        final sample = TrainingSample(
          id: id,
          imagePath: fullDest,
          cropPath: cropDest,
          centerX: kf.x,
          centerY: kf.y,
          boxWidth: kf.boxWidth ?? _defaultBoxSize,
          boxHeight: kf.boxHeight ?? _defaultBoxSize,
          frameIndex: kf.frameIndex,
          imageWidth: imgW,
          imageHeight: imgH,
          createdAt: DateTime.now(),
        );

        final labelPath = '${labelsDir.path}/$id.txt';
        await File(labelPath).writeAsString(sample.toYoloLabel());

        _samples.add(sample);
        saved++;
      } catch (e) {
        debugPrint('Failed to save training sample: $e');
      }
    }

    if (saved > 0) {
      await _saveManifest();
      notifyListeners();
    }

    debugPrint('Saved $saved training samples from ${keyframes.length} keyframes');
    return saved;
  }

  // ---------------------------------------------------------------------------
  // Upload
  // ---------------------------------------------------------------------------

  /// Upload all pending (un-uploaded) samples to the server.
  /// Returns the number successfully uploaded.
  Future<int> uploadPending() async {
    if (_serverUrl.isEmpty) {
      debugPrint('No server URL configured for training data upload');
      return 0;
    }

    final pending = _samples.where((s) => !s.uploaded).toList();
    if (pending.isEmpty) return 0;

    int uploaded = 0;
    final client = HttpClient();

    try {
      for (final sample in pending) {
        try {
          final fullFile = File(sample.imagePath);
          final cropFile = File(sample.cropPath);
          if (!await fullFile.exists() || !await cropFile.exists()) {
            debugPrint('Skipping ${sample.id}: image files missing');
            continue;
          }

          final uri = Uri.parse('$_serverUrl/api/training/upload');
          final request = await client.postUrl(uri);

          final boundary = '----FormBoundary${_generateId()}';
          request.headers.set(
            'Content-Type',
            'multipart/form-data; boundary=$boundary',
          );
          request.headers.set('X-App-Key', 'disc-flight-school-v1');

          // Helper to write a text field part
          void writeField(StringBuffer buf, String name, String value) {
            buf.write('--$boundary\r\n');
            buf.write('Content-Disposition: form-data; name="$name"\r\n\r\n');
            buf.write('$value\r\n');
          }

          // Build preamble with text fields
          final preamble = StringBuffer();
          writeField(preamble, 'sample_id', sample.id);
          writeField(preamble, 'label', sample.toYoloLabel());
          writeField(preamble, 'image_width', sample.imageWidth.toString());
          writeField(preamble, 'image_height', sample.imageHeight.toString());
          writeField(preamble, 'app_version', '1.0.0');

          // Full image file part header
          preamble.write('--$boundary\r\n');
          preamble.write(
            'Content-Disposition: form-data; name="full_image"; '
            'filename="${sample.id}_full.jpg"\r\n',
          );
          preamble.write('Content-Type: image/jpeg\r\n\r\n');

          // Middle part between files
          final middle = StringBuffer();
          middle.write('\r\n--$boundary\r\n');
          middle.write(
            'Content-Disposition: form-data; name="crop_image"; '
            'filename="${sample.id}_crop.jpg"\r\n',
          );
          middle.write('Content-Type: image/jpeg\r\n\r\n');

          // Closing boundary
          final closing = '\r\n--$boundary--\r\n';

          // Calculate content length
          final fullBytes = await fullFile.readAsBytes();
          final cropBytes = await cropFile.readAsBytes();
          final preambleBytes = utf8.encode(preamble.toString());
          final middleBytes = utf8.encode(middle.toString());
          final closingBytes = utf8.encode(closing);

          request.contentLength = preambleBytes.length +
              fullBytes.length +
              middleBytes.length +
              cropBytes.length +
              closingBytes.length;

          // Write all parts
          request.add(preambleBytes);
          request.add(fullBytes);
          request.add(middleBytes);
          request.add(cropBytes);
          request.add(closingBytes);

          final response = await request.close();

          if (response.statusCode == 200) {
            final idx = _samples.indexWhere((s) => s.id == sample.id);
            if (idx != -1) {
              _samples[idx] = _samples[idx].copyWith(uploaded: true);
            }
            uploaded++;
          }

          await response.drain<void>();
        } catch (e) {
          debugPrint('Failed to upload sample ${sample.id}: $e');
        }
      }
    } finally {
      client.close();
    }

    if (uploaded > 0) {
      await _saveManifest();
      notifyListeners();
    }

    return uploaded;
  }

  // ---------------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------------

  /// Export all training data as a ZIP file to the given directory.
  /// Returns the path to the created ZIP file, or null on failure.
  Future<String?> exportTrainingData() async {
    if (_samples.isEmpty) return null;

    try {
      final dataDir = await _getDataDir();
      final exportDir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;

      // Build a manifest JSON
      final manifest = {
        'exported_at': DateTime.now().toIso8601String(),
        'sample_count': _samples.length,
        'samples': _samples.map((s) => s.toJson()).toList(),
      };

      // Use dart:io ZipEncoder via the archive package
      // Since we want to avoid adding heavy dependencies, we'll create
      // a directory structure and use gzip + tar approach
      // Actually, let's create a simple directory export that can be zipped externally
      // or shared as-is

      final exportSubDir = Directory('${exportDir.path}/training_export_$timestamp');
      await exportSubDir.create(recursive: true);

      final exportImages = Directory('${exportSubDir.path}/images');
      final exportLabels = Directory('${exportSubDir.path}/labels');
      await exportImages.create();
      await exportLabels.create();

      // Copy images and labels
      for (final sample in _samples) {
        final fullFile = File(sample.imagePath);
        final cropFile = File(sample.cropPath);
        final labelFile = File('${dataDir.path}/labels/${sample.id}.txt');

        if (await fullFile.exists()) {
          await fullFile.copy('${exportImages.path}/${sample.id}_full.jpg');
        }
        if (await cropFile.exists()) {
          await cropFile.copy('${exportImages.path}/${sample.id}_crop.jpg');
        }
        if (await labelFile.exists()) {
          await labelFile.copy('${exportLabels.path}/${sample.id}.txt');
        }
      }

      // Write manifest
      final manifestFile = File('${exportSubDir.path}/manifest.json');
      await manifestFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(manifest),
      );

      return exportSubDir.path;
    } catch (e) {
      debugPrint('Failed to export training data: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Model Updates
  // ---------------------------------------------------------------------------

  /// Get the path to the current disc detection model.
  /// Returns a custom (downloaded) model path if available, otherwise null
  /// (caller should fall back to the bundled asset model).
  Future<String?> getCustomModelPath() async {
    final dataDir = await _getDataDir();
    final modelPath = '${dataDir.path}/models/disc_detector.tflite';
    final file = File(modelPath);
    if (await file.exists()) return modelPath;
    return null;
  }

  /// Get the locally stored model version string.
  Future<String> getModelVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_modelVersionKey) ?? 'bundled-1.0.0';
  }

  /// Check server for a newer model version.
  /// Returns true if an update is available.
  Future<bool> checkForModelUpdate() async {
    if (_serverUrl.isEmpty) return false;

    try {
      final client = HttpClient();
      final uri = Uri.parse('$_serverUrl/api/model/version');
      final request = await client.getUrl(uri);
      final response = await request.close();

      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        final data = jsonDecode(body) as Map<String, dynamic>;
        final remoteVersion = data['version'] as String;
        final localVersion = await getModelVersion();
        client.close();
        return remoteVersion != localVersion;
      }
      client.close();
    } catch (e) {
      debugPrint('Failed to check model version: $e');
    }
    return false;
  }

  /// Download the latest model from the server.
  Future<bool> downloadModel() async {
    if (_serverUrl.isEmpty) return false;

    try {
      // Get version info
      final client = HttpClient();
      final versionUri = Uri.parse('$_serverUrl/api/model/version');
      final versionReq = await client.getUrl(versionUri);
      final versionResp = await versionReq.close();

      if (versionResp.statusCode != 200) {
        client.close();
        return false;
      }

      final versionBody = await versionResp.transform(utf8.decoder).join();
      final versionData = jsonDecode(versionBody) as Map<String, dynamic>;
      final modelUrl = versionData['url'] as String;
      final version = versionData['version'] as String;

      // Download model file — server returns relative path, prepend base URL
      final fullUrl = modelUrl.startsWith('http') ? modelUrl : '$_serverUrl$modelUrl';
      final modelUri = Uri.parse(fullUrl);
      final modelReq = await client.getUrl(modelUri);
      final modelResp = await modelReq.close();

      if (modelResp.statusCode != 200) {
        client.close();
        return false;
      }

      final dataDir = await _getDataDir();
      final modelsDir = Directory('${dataDir.path}/models');
      if (!await modelsDir.exists()) await modelsDir.create(recursive: true);

      final modelFile = File('${modelsDir.path}/disc_detector.tflite');
      final sink = modelFile.openWrite();
      await modelResp.pipe(sink);

      // Save version
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modelVersionKey, version);

      client.close();
      debugPrint('Downloaded model version $version');
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Failed to download model: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Data Management
  // ---------------------------------------------------------------------------

  /// Delete all local training data.
  Future<void> clearAllData() async {
    final dataDir = await _getDataDir();
    if (await dataDir.exists()) {
      // Keep the models subdirectory
      final entries = await dataDir.list().toList();
      for (final entry in entries) {
        if (entry is Directory && !entry.path.endsWith('models')) {
          await entry.delete(recursive: true);
        } else if (entry is File) {
          await entry.delete();
        }
      }
    }
    _samples.clear();
    await _saveManifest();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<Directory> _getDataDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final dataDir = Directory('${appDir.path}/training_data');
    if (!await dataDir.exists()) await dataDir.create(recursive: true);
    return dataDir;
  }

  Future<void> _loadManifest() async {
    try {
      final dataDir = await _getDataDir();
      final file = File('${dataDir.path}/$_manifestFile');
      if (await file.exists()) {
        final content = await file.readAsString();
        final list = jsonDecode(content) as List;
        _samples = list
            .map((e) => TrainingSample.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('Failed to load training manifest: $e');
      _samples = [];
    }
  }

  Future<void> _saveManifest() async {
    try {
      final dataDir = await _getDataDir();
      final file = File('${dataDir.path}/$_manifestFile');
      final content = jsonEncode(_samples.map((s) => s.toJson()).toList());
      await file.writeAsString(content);
    } catch (e) {
      debugPrint('Failed to save training manifest: $e');
    }
  }

  String _generateId() {
    final random = Random();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final suffix = random.nextInt(99999).toString().padLeft(5, '0');
    return '${timestamp}_$suffix';
  }
}
