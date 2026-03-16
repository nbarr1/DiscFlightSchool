class Disc {
  final String id;
  final String name;
  final String manufacturer;
  final String type; // Putter, Midrange, Fairway, Distance
  final double speed;
  final double glide;
  final double turn;
  final double fade;
  final String? imageUrl;

  Disc({
    required this.id,
    required this.name,
    required this.manufacturer,
    required this.type,
    required this.speed,
    required this.glide,
    required this.turn,
    required this.fade,
    this.imageUrl,
  });

  factory Disc.fromJson(Map<String, dynamic> json) {
    return Disc(
      id: json['id'],
      name: json['name'],
      manufacturer: json['manufacturer'],
      type: json['type'],
      speed: json['speed'].toDouble(),
      glide: json['glide'].toDouble(),
      turn: json['turn'].toDouble(),
      fade: json['fade'].toDouble(),
      imageUrl: json['imageUrl'],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'manufacturer': manufacturer,
      'type': type,
      'speed': speed,
      'glide': glide,
      'turn': turn,
      'fade': fade,
      'imageUrl': imageUrl,
    };
  }
}