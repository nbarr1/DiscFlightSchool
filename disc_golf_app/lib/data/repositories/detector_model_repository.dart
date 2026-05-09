import '../../models/detector_model_metadata.dart';

/// Persistence and server boundary for detector model metadata/downloads.
abstract interface class DetectorModelRepository {
  Future<DetectorModelMetadata?> getInstalledModel();
  Future<void> saveInstalledModel(DetectorModelMetadata metadata);
  Future<DetectorModelVersion> fetchRemoteVersion();
  Future<String> downloadAndVerifyModel(DetectorModelVersion version);
  Future<void> clearInstalledModel();
}
