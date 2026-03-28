class AppConstants {
  // API Configuration
  static const String pythonApiUrl = 'http://localhost:5000/api';
  
  // Video Configuration
  static const int defaultFps = 30;
  static const int maxVideoLengthSeconds = 60;
  
  // Tracking Configuration
  static const double minConfidenceThreshold = 0.5;
  static const int interpolationFrameGap = 5;
  
  // Form Analysis
  static const List<String> keyJoints = [
    'leftShoulder',
    'rightShoulder',
    'leftElbow',
    'rightElbow',
    'leftWrist',
    'rightWrist',
    'leftHip',
    'rightHip',
    'leftKnee',
    'rightKnee',
    'leftAnkle',
    'rightAnkle',
  ];
  
  static const List<String> criticalAngles = [
    'shoulderAngle',
    'elbowAngle',
    'hipAngle',
    'kneeAngle',
    'discAngle',
  ];
  
  // Pro Players (for Form Coach comparison)
  static const List<String> proPlayers = [
    'Paul McBeth',
    'Ricky Wysocki',
    'Eagle McMahon',
    'Gannon Buhr',
    'Calvin Heimburg',
  ];

  // Roulette Configuration
  static const List<String> defaultDiscs = [
    'Putter',
    'Midrange',
    'Fairway Driver',
    'Distance Driver',
  ];  // Colors
  static const Map<String, String> phaseColors = {
    'release': '#FF0000',
    'initialFlight': '#FF9800',
    'apex': '#FFEB3B',
    'fade': '#4CAF50',
    'landing': '#2196F3',
  };
}