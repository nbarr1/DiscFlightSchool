import 'package:flutter/material.dart';
import '../services/flight_data_service.dart';
import '../widgets/flight_path_painter.dart';

class FlightAnalysisScreen extends StatefulWidget {
  const FlightAnalysisScreen({Key? key}) : super(key: key);

  @override
  State<FlightAnalysisScreen> createState() => _FlightAnalysisScreenState();
}

class _FlightAnalysisScreenState extends State<FlightAnalysisScreen> {
  String? flightPathData;
  Map<String, dynamic>? analysisResults;
  bool isLoading = true;
  String? errorMessage;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final pathData = await FlightDataService.loadFlightPath();
      final results = await FlightDataService.loadAnalysisResults();
      
      setState(() {
        flightPathData = pathData;
        analysisResults = results;
        isLoading = false;
      });
    } catch (e) {
      print('Error loading $e');
      setState(() {
        errorMessage = 'Failed to load analysis data. Please run the Python analysis first.';
        isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flight Analysis'),
        backgroundColor: Colors.blue[700],
        elevation: 0,
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: Colors.grey[400]),
                        const SizedBox(height: 16),
                        Text(
                          errorMessage!,
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 16, color: Colors.grey[600]),
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: () {
                            setState(() {
                              isLoading = true;
                              errorMessage = null;
                            });
                            _loadData();
                          },
                          icon: const Icon(Icons.refresh),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : SingleChildScrollView(
                  child: Column(
                    children: [
                      // Flight Path Visualization
                      Container(
                        height: 400,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.blue[700]!, Colors.blue[900]!],
                          ),
                        ),
                        child: flightPathData != null
                            ? FlightPathWidget(jsonCoordinates: flightPathData!)
                            : const Center(
                                child: Text(
                                  'No flight path data available',
                                  style: TextStyle(color: Colors.white),
                                ),
                              ),
                      ),
                      
                      // Analysis Results
                      if (analysisResults != null) ...[
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Form Analysis Results',
                                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                      fontWeight: FontWeight.bold,
                                    ),
                              ),
                              const SizedBox(height: 16),
                              
                              // Similarity Score Card
                              Card(
                                elevation: 4,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text(
                                            'Match Percentage',
                                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                                          ),
                                          Text(
                                            '${analysisResults!['percentage_match'].toStringAsFixed(1)}%',
                                            style: TextStyle(
                                              fontSize: 28,
                                              fontWeight: FontWeight.bold,
                                              color: _getScoreColor(analysisResults!['percentage_match']),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(8),
                                        child: LinearProgressIndicator(
                                          value: analysisResults!['percentage_match'] / 100,
                                          backgroundColor: Colors.grey[300],
                                          color: _getScoreColor(analysisResults!['percentage_match']),
                                          minHeight: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              
                              const SizedBox(height: 16),
                              
                              // Detailed Metrics
                              Card(
                                elevation: 4,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Detailed Metrics',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      const Divider(height: 24),
                                      _buildMetricRow(
                                        'Spine Angle',
                                        '${analysisResults!['user_spine_angle'].toStringAsFixed(1)}°',
                                        '${analysisResults!['pro_spine_angle'].toStringAsFixed(1)}°',
                                        '${analysisResults!['spine_difference'].toStringAsFixed(1)}°',
                                      ),
                                      const SizedBox(height: 12),
                                      _buildMetricRow(
                                        'Elbow Angle',
                                        '${analysisResults!['user_elbow_angle'].toStringAsFixed(1)}°',
                                        '${analysisResults!['pro_elbow_angle'].toStringAsFixed(1)}°',
                                        '${analysisResults!['elbow_difference'].toStringAsFixed(1)}°',
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Scale Factor: ${analysisResults!['scale_factor'].toStringAsFixed(2)}',
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Colors.grey[600],
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              
                              const SizedBox(height: 16),
                              
                              // Recommendations
                              Card(
                                elevation: 4,
                                color: Colors.blue[50],
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(16.0),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: const [
                                          Icon(Icons.lightbulb_outline, color: Colors.orange, size: 24),
                                          SizedBox(width: 8),
                                          Text(
                                            'Recommendations',
                                            style: TextStyle(
                                              fontSize: 18,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Divider(height: 24),
                                      ..._generateRecommendations(analysisResults!),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _buildMetricRow(String label, String userValue, String proValue, String difference) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.grey[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Your Form',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    Text(
                      userValue,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pro Form',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    Text(
                      proValue,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Difference',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[600],
                      ),
                    ),
                    Text(
                      difference,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: _getDifferenceColor(
                          double.parse(difference.replaceAll('°', '')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getScoreColor(double score) {
    if (score >= 80) return Colors.green;
    if (score >= 60) return Colors.orange;
    return Colors.red;
  }

  Color _getDifferenceColor(double difference) {
    if (difference < 5) return Colors.green;
    if (difference < 15) return Colors.orange;
    return Colors.red;
  }

  List<Widget> _generateRecommendations(Map<String, dynamic> results) {
    List<Widget> recommendations = [];
    
    double spineDiff = results['spine_difference'];
    double elbowDiff = results['elbow_difference'];
    double userSpine = results['user_spine_angle'];
    double proSpine = results['pro_spine_angle'];
    double userElbow = results['user_elbow_angle'];
    double proElbow = results['pro_elbow_angle'];
    
    if (spineDiff > 10) {
      String direction = userSpine > proSpine ? 'decrease' : 'increase';
      recommendations.add(
        _buildRecommendation(
          'Try to $direction your spine angle by ${spineDiff.toStringAsFixed(1)}° to better match the pro form. Focus on maintaining a more athletic posture.',
          Icons.accessibility_new,
        ),
      );
    }
    
    if (elbowDiff > 10) {
      String direction = userElbow > proElbow ? 'tighter' : 'more extended';
      recommendations.add(
        _buildRecommendation(
          'Work on keeping your elbow $direction during the power pocket phase. This will help generate more power and accuracy.',
          Icons.sports,
        ),
      );
    }
    
    if (spineDiff <= 5 && elbowDiff <= 5) {
      recommendations.add(
        _buildRecommendation(
          'Excellent form! Your technique closely matches the pro baseline. Keep practicing to maintain this consistency.',
          Icons.check_circle,
        ),
      );
    } else if (spineDiff <= 10 && elbowDiff <= 10) {
      recommendations.add(
        _buildRecommendation(
          'Good form! You\'re very close to the pro baseline. Small adjustments will help you achieve even better results.',
          Icons.trending_up,
        ),
      );
    }
    
    if (recommendations.isEmpty) {
      recommendations.add(
        _buildRecommendation(
          'Continue working on your form. Focus on the fundamentals and film yourself regularly to track progress.',
          Icons.video_camera_back,
        ),
      );
    }
    
    return recommendations;
  }

  Widget _buildRecommendation(String text, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: Colors.blue[700]),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 15, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}