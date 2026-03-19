import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/training_data_service.dart';

class TrainingSettingsScreen extends StatelessWidget {
  const TrainingSettingsScreen({super.key});

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
                  service.serverUrl.isEmpty
                      ? 'Upload (no server configured)'
                      : 'Upload ${service.pendingSamples} samples',
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

              // Server URL config
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Server Configuration',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: service.serverUrl,
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          labelText: 'Server URL',
                          hintText: 'https://your-server.com',
                        ),
                        onFieldSubmitted: (value) =>
                            service.setServerUrl(value.trim()),
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
