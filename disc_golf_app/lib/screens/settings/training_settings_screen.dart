import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

    final exportPath = await service.exportTrainingData();

    if (context.mounted) {
      Navigator.of(context).pop();

      if (exportPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported to:\n$exportPath'),
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Export failed')),
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
