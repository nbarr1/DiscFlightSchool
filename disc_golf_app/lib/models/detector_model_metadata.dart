/// Metadata for a locally installed or remotely advertised detector model.
class DetectorModelMetadata {
  final String version;
  final String sha256;
  final String path;
  final DateTime installedAt;

  const DetectorModelMetadata({
    required this.version,
    required this.sha256,
    required this.path,
    required this.installedAt,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'sha256': sha256,
        'path': path,
        'installedAt': installedAt.toIso8601String(),
      };

  factory DetectorModelMetadata.fromJson(Map<String, dynamic> json) =>
      DetectorModelMetadata(
        version: json['version'] as String,
        sha256: json['sha256'] as String,
        path: json['path'] as String,
        installedAt: DateTime.parse(json['installedAt'] as String),
      );
}

/// Server response shape from GET /api/model/version.
class DetectorModelVersion {
  final String version;
  final String sha256;
  final String url;

  const DetectorModelVersion({
    required this.version,
    required this.sha256,
    required this.url,
  });

  bool get hasModel => version != 'none' && sha256.isNotEmpty && url.isNotEmpty;

  factory DetectorModelVersion.fromJson(Map<String, dynamic> json) =>
      DetectorModelVersion(
        version: json['version'] as String,
        sha256: json['sha256'] as String,
        url: json['url'] as String,
      );
}
