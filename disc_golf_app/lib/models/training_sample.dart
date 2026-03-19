class TrainingSample {
  final String id;
  final String imagePath;
  final String cropPath;
  final double centerX;
  final double centerY;
  final double boxWidth;
  final double boxHeight;
  final int frameIndex;
  final int imageWidth;
  final int imageHeight;
  final DateTime createdAt;
  final bool uploaded;

  TrainingSample({
    required this.id,
    required this.imagePath,
    required this.cropPath,
    required this.centerX,
    required this.centerY,
    required this.boxWidth,
    required this.boxHeight,
    required this.frameIndex,
    required this.imageWidth,
    required this.imageHeight,
    required this.createdAt,
    this.uploaded = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'imagePath': imagePath,
        'cropPath': cropPath,
        'centerX': centerX,
        'centerY': centerY,
        'boxWidth': boxWidth,
        'boxHeight': boxHeight,
        'frameIndex': frameIndex,
        'imageWidth': imageWidth,
        'imageHeight': imageHeight,
        'createdAt': createdAt.toIso8601String(),
        'uploaded': uploaded,
      };

  factory TrainingSample.fromJson(Map<String, dynamic> json) => TrainingSample(
        id: json['id'] as String,
        imagePath: json['imagePath'] as String,
        cropPath: json['cropPath'] as String,
        centerX: (json['centerX'] as num).toDouble(),
        centerY: (json['centerY'] as num).toDouble(),
        boxWidth: (json['boxWidth'] as num).toDouble(),
        boxHeight: (json['boxHeight'] as num).toDouble(),
        frameIndex: json['frameIndex'] as int,
        imageWidth: json['imageWidth'] as int,
        imageHeight: json['imageHeight'] as int,
        createdAt: DateTime.parse(json['createdAt'] as String),
        uploaded: json['uploaded'] as bool? ?? false,
      );

  TrainingSample copyWith({bool? uploaded}) => TrainingSample(
        id: id,
        imagePath: imagePath,
        cropPath: cropPath,
        centerX: centerX,
        centerY: centerY,
        boxWidth: boxWidth,
        boxHeight: boxHeight,
        frameIndex: frameIndex,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        createdAt: createdAt,
        uploaded: uploaded ?? this.uploaded,
      );

  /// YOLO format label line: "class_id center_x center_y width height"
  String toYoloLabel() =>
      '0 ${centerX.toStringAsFixed(6)} ${centerY.toStringAsFixed(6)} ${boxWidth.toStringAsFixed(6)} ${boxHeight.toStringAsFixed(6)}';
}
