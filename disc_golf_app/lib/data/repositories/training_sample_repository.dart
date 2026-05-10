import '../../models/training_sample.dart';

/// Persistence boundary for locally collected disc detector training samples.
abstract interface class TrainingSampleRepository {
  Future<List<TrainingSample>> getAllSamples();
  Future<List<TrainingSample>> getPendingUploads();
  Future<void> saveSample(TrainingSample sample);
  Future<void> saveSamples(List<TrainingSample> samples);
  Future<void> markUploaded(String sampleId);
  Future<void> deleteSample(String sampleId);
  Future<void> clearSamples();
}
