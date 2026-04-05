import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import '../../services/disc_detection_service.dart';
import '../../services/knowledge_base_service.dart';
import '../../services/training_data_service.dart';

class TrainingSettingsScreen extends StatefulWidget {
  const TrainingSettingsScreen({super.key});

  @override
  State<TrainingSettingsScreen> createState() => _TrainingSettingsScreenState();
}

class _TrainingSettingsScreenState extends State<TrainingSettingsScreen> {
  bool? _serverOnline;
  bool _checkingServer = false;

  @override
  void initState() {
    super.initState();
    _checkServerHealth();
  }

  Future<void> _checkServerHealth() async {
    final service = context.read<TrainingDataService>();
    if (service.serverUrl.isEmpty) {
      setState(() => _serverOnline = null);
      return;
    }
    setState(() => _checkingServer = true);
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final request = await client.getUrl(
        Uri.parse('${service.serverUrl}/health'),
      );
      final response = await request.close();
      if (mounted) {
        setState(() {
          _serverOnline = response.statusCode == 200;
          _checkingServer = false;
        });
      }
      client.close();
    } catch (_) {
      if (mounted) {
        setState(() {
          _serverOnline = false;
          _checkingServer = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Training Settings'),
      ),
      body: Consumer<TrainingDataService>(
        builder: (context, service, _) {
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Disc detection confidence threshold
              Consumer<DiscDetectionService>(
                builder: (context, detectionService, _) {
                  final threshold = detectionService.confidenceThreshold;
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Disc Detection Sensitivity',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 15)),
                          const SizedBox(height: 4),
                          Text(
                            'Lower = detects more (may include false positives). '
                            'Higher = more precise (may miss fast-moving disc).',
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade400),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              const Text('Low', style: TextStyle(fontSize: 11, color: Colors.grey)),
                              Expanded(
                                child: Slider(
                                  value: threshold,
                                  min: 0.01,
                                  max: 0.5,
                                  divisions: 49,
                                  label: '${(threshold * 100).toStringAsFixed(0)}%',
                                  onChanged: (v) =>
                                      detectionService.setConfidenceThreshold(v),
                                ),
                              ),
                              const Text('High', style: TextStyle(fontSize: 11, color: Colors.grey)),
                            ],
                          ),
                          Center(
                            child: Text(
                              'Current: ${(threshold * 100).toStringAsFixed(0)}% confidence required',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ),
                          const SizedBox(height: 4),
                        ],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Opt-in toggle
              Card(
                child: SwitchListTile(
                  title: const Text('Help improve disc tracking'),
                  subtitle: const Text(
                    'When enabled, your manual flight tracking data is saved '
                    'to help train the auto-detection model.',
                  ),
                  value: service.isOptedIn,
                  onChanged: (value) => service.setOptIn(value),
                ),
              ),
              const SizedBox(height: 16),

              // Server status
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Icon(
                        _checkingServer
                            ? Icons.sync
                            : _serverOnline == true
                                ? Icons.cloud_done
                                : _serverOnline == false
                                    ? Icons.cloud_off
                                    : Icons.cloud_queue,
                        color: _checkingServer
                            ? Colors.grey
                            : _serverOnline == true
                                ? Colors.green
                                : _serverOnline == false
                                    ? Colors.red
                                    : Colors.grey,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _checkingServer
                              ? 'Checking server...'
                              : _serverOnline == true
                                  ? 'Training server connected'
                                  : _serverOnline == false
                                      ? 'Training server unreachable'
                                      : 'No server configured',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: _serverOnline == true
                                ? Colors.green
                                : _serverOnline == false
                                    ? Colors.red
                                    : null,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.refresh, size: 20),
                        onPressed: _checkingServer ? null : _checkServerHealth,
                        tooltip: 'Refresh',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Stats
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Collection Stats',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      _StatRow(
                        label: 'Total samples',
                        value: '${service.totalSamples}',
                      ),
                      _StatRow(
                        label: 'Uploaded',
                        value: '${service.uploadedSamples}',
                      ),
                      _StatRow(
                        label: 'Pending upload',
                        value: '${service.pendingSamples}',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Upload button
              ElevatedButton.icon(
                onPressed: service.pendingSamples > 0 &&
                        service.serverUrl.isNotEmpty
                    ? () => _uploadData(context, service)
                    : null,
                icon: const Icon(Icons.cloud_upload),
                label: Text(
                  service.pendingSamples > 0
                      ? 'Upload ${service.pendingSamples} samples'
                      : 'No samples to upload',
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: 12),

              // Export training data
              ElevatedButton.icon(
                onPressed: service.totalSamples > 0
                    ? () => _exportData(context, service)
                    : null,
                icon: const Icon(Icons.folder_zip),
                label: Text(
                  'Export ${service.totalSamples} samples',
                ),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: 12),

              // Check for model update
              OutlinedButton.icon(
                onPressed: service.serverUrl.isNotEmpty
                    ? () => _checkModelUpdate(context, service)
                    : null,
                icon: const Icon(Icons.system_update),
                label: const Text('Check for model update'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(14),
                ),
              ),
              const SizedBox(height: 24),

              // AI API Key
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.auto_awesome,
                              size: 20, color: Colors.teal.shade300),
                          const SizedBox(width: 8),
                          Text(
                            'AI Search (Knowledge Base)',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter your Anthropic API key to enable AI-powered '
                        'research search in the Knowledge Base.',
                        style: TextStyle(
                          color: Colors.grey.shade500,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Consumer<KnowledgeBaseService>(
                        builder: (context, kbService, _) {
                          return Row(
                            children: [
                              Icon(
                                kbService.hasApiKey
                                    ? Icons.check_circle
                                    : Icons.warning_amber,
                                size: 18,
                                color: kbService.hasApiKey
                                    ? Colors.green
                                    : Colors.orange,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                kbService.hasApiKey
                                    ? 'API key saved'
                                    : 'No API key set',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: kbService.hasApiKey
                                      ? Colors.green
                                      : Colors.orange,
                                ),
                              ),
                              const Spacer(),
                              if (kbService.hasApiKey)
                                TextButton(
                                  onPressed: () async {
                                    await kbService.clearApiKey();
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                        const SnackBar(
                                            content:
                                                Text('API key removed')),
                                      );
                                    }
                                  },
                                  child: const Text('Remove',
                                      style: TextStyle(color: Colors.red)),
                                )
                              else
                                ElevatedButton(
                                  onPressed: () =>
                                      _showApiKeyDialog(context, kbService),
                                  child: const Text('Add Key'),
                                ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Advanced: Custom server URL
              ExpansionTile(
                title: const Text('Advanced'),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextFormField(
                          initialValue: service.serverUrl,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Custom Server (optional)',
                            hintText: 'https://disc-flight-school.onrender.com',
                            helperText: 'Leave blank to use the default server',
                          ),
                          onFieldSubmitted: (value) {
                            service.setServerUrl(value.trim());
                            _checkServerHealth();
                          },
                        ),
                        const SizedBox(height: 8),
                        FutureBuilder<String>(
                          future: service.getModelVersion(),
                          builder: (context, snapshot) {
                            return Text(
                              'Model version: ${snapshot.data ?? '...'}',
                              style: TextStyle(
                                color: Colors.grey[500],
                                fontSize: 12,
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // Clear data
              TextButton.icon(
                onPressed: service.totalSamples > 0
                    ? () => _confirmClearData(context, service)
                    : null,
                icon: const Icon(Icons.delete_outline, color: Colors.red),
                label: const Text(
                  'Clear all training data',
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showApiKeyDialog(
      BuildContext context, KnowledgeBaseService kbService) {
    final keyController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Anthropic API Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Your key is stored locally on this device and is only '
              'used to query the Claude API for research answers.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: keyController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'sk-ant-...',
                labelText: 'API Key',
              ),
              obscureText: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              if (keyController.text.trim().isNotEmpty) {
                await kbService.setApiKey(keyController.text);
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('API key saved')),
                  );
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _exportData(
      BuildContext context, TrainingDataService service) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Exporting...'),
          ],
        ),
      ),
    );

    final zipPath = await service.exportTrainingData();

    if (context.mounted) {
      Navigator.of(context).pop(); // dismiss progress dialog

      if (zipPath != null) {
        // Open the OS share sheet so the user can send the ZIP wherever
        // they like (email, cloud drive, AirDrop, etc.).
        await Share.shareXFiles(
          [XFile(zipPath, mimeType: 'application/zip')],
          subject: 'Disc training data export',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export failed — no samples to export')),
        );
      }
    }
  }

  Future<void> _uploadData(
      BuildContext context, TrainingDataService service) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('Uploading...'),
          ],
        ),
      ),
    );

    final uploaded = await service.uploadPending();

    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Uploaded $uploaded samples')),
      );
    }
  }

  Future<void> _checkModelUpdate(
      BuildContext context, TrainingDataService service) async {
    final hasUpdate = await service.checkForModelUpdate();

    if (!context.mounted) return;

    if (hasUpdate) {
      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Model Update Available'),
          content: const Text(
            'A newer disc detection model is available. Download it?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download'),
            ),
          ],
        ),
      );

      if (shouldDownload == true && context.mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const AlertDialog(
            content: Row(
              children: [
                CircularProgressIndicator(),
                SizedBox(width: 16),
                Text('Downloading model...'),
              ],
            ),
          ),
        );

        final success = await service.downloadModel();

        if (context.mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                success
                    ? 'Model updated! Restart the app to use it.'
                    : 'Download failed.',
              ),
            ),
          );
        }
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model is up to date')),
      );
    }
  }

  Future<void> _confirmClearData(
      BuildContext context, TrainingDataService service) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear Training Data'),
        content: Text(
          'Delete all ${service.totalSamples} training samples? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await service.clearAllData();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Training data cleared')),
        );
      }
    }
  }
}

class _StatRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
