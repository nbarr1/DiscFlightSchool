import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:disc_golf_app/models/training_sample.dart';
import 'package:disc_golf_app/services/training_data_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('isAllowedServerUri', () {
    test('allows any https origin', () {
      expect(
        TrainingDataService.isAllowedServerUri(
            Uri.parse('https://discflightschool.onrender.com')),
        isTrue,
      );
      expect(
        TrainingDataService.isAllowedServerUri(
            Uri.parse('https://example.com:8443/base')),
        isTrue,
      );
    });

    test('allows plain http only on loopback', () {
      expect(
        TrainingDataService.isAllowedServerUri(Uri.parse('http://localhost:8000')),
        isTrue,
      );
      expect(
        TrainingDataService.isAllowedServerUri(Uri.parse('http://127.0.0.1:8000')),
        isTrue,
      );
    });

    test('rejects cleartext http to a remote host', () {
      // Uploads carry the API key; cleartext to a remote host would leak it.
      expect(
        TrainingDataService.isAllowedServerUri(Uri.parse('http://example.com')),
        isFalse,
      );
      expect(
        TrainingDataService.isAllowedServerUri(
            Uri.parse('http://192.168.1.10:8000')),
        isFalse,
      );
    });

    test('rejects non-http schemes', () {
      for (final uri in [
        'ftp://example.com',
        'file:///etc/passwd',
        'javascript:alert(1)',
        'ws://example.com',
      ]) {
        expect(
          TrainingDataService.isAllowedServerUri(Uri.parse(uri)),
          isFalse,
          reason: '$uri should be rejected',
        );
      }
    });
  });

  group('isSameOrigin', () {
    final base = Uri.parse('https://server.example.com/api');

    test('accepts the same origin', () {
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('https://server.example.com/api/model/download')),
        isTrue,
      );
    });

    test('treats an explicit default port as equal to an omitted one', () {
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('https://server.example.com:443/x')),
        isTrue,
      );
    });

    test('is case insensitive for scheme and host', () {
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('HTTPS://SERVER.EXAMPLE.COM/x')),
        isTrue,
      );
    });

    test('rejects a different host', () {
      expect(
        TrainingDataService.isSameOrigin(base, Uri.parse('https://evil.com/x')),
        isFalse,
      );
    });

    test('rejects a different port on the same host', () {
      // Regression: the guard compared scheme and host only, so a
      // server-supplied URL could redirect the model download to another
      // service on the same box.
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('https://server.example.com:9000/x')),
        isFalse,
      );
    });

    test('rejects a scheme downgrade', () {
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('http://server.example.com/x')),
        isFalse,
      );
    });

    test('rejects a subdomain', () {
      expect(
        TrainingDataService.isSameOrigin(
            base, Uri.parse('https://evil.server.example.com/x')),
        isFalse,
      );
    });
  });

  group('originOf', () {
    test('normalizes scheme and host case and fills the default port', () {
      expect(
        TrainingDataService.originOf('HTTPS://Example.COM/path'),
        TrainingDataService.originOf('https://example.com/other'),
      );
    });

    test('distinguishes ports', () {
      expect(
        TrainingDataService.originOf('https://example.com:8443'),
        isNot(TrainingDataService.originOf('https://example.com')),
      );
    });

    test('ignores path, query and fragment', () {
      expect(
        TrainingDataService.originOf('https://example.com/a?b=c#d'),
        TrainingDataService.originOf('https://example.com/'),
      );
    });

    test('tolerates surrounding whitespace', () {
      expect(
        TrainingDataService.originOf('  https://example.com  '),
        TrainingDataService.originOf('https://example.com'),
      );
    });

    test('returns null for input with no host', () {
      expect(TrainingDataService.originOf(''), isNull);
      expect(TrainingDataService.originOf('not a url'), isNull);
      expect(TrainingDataService.originOf('/relative/path'), isNull);
    });
  });

  group('server URL changes and the stored API key', () {
    test('changing the origin clears the stored API key', () async {
      // The key was issued by the previous server; forwarding it to a new host
      // would hand the user's credential to whoever they just pointed at.
      final service = TrainingDataService();
      await service.init();
      await service.setApiKey('secret-key');
      expect(service.hasApiKey, isTrue);

      await service.setServerUrl('https://someone-elses-server.example.com');

      expect(service.hasApiKey, isFalse);
    });

    test('editing the path on the same origin keeps the key', () async {
      final service = TrainingDataService();
      await service.init();
      await service.setServerUrl('https://server.example.com/api');
      await service.setApiKey('secret-key');

      await service.setServerUrl('https://server.example.com/api/v2');

      expect(service.hasApiKey, isTrue);
    });

    test('changing only the port is treated as a new origin', () async {
      final service = TrainingDataService();
      await service.init();
      await service.setServerUrl('https://server.example.com');
      await service.setApiKey('secret-key');

      await service.setServerUrl('https://server.example.com:9443');

      expect(service.hasApiKey, isFalse);
    });

    test('setting the same URL again is a no-op for the key', () async {
      final service = TrainingDataService();
      await service.init();
      await service.setServerUrl('https://server.example.com');
      await service.setApiKey('secret-key');

      await service.setServerUrl('https://server.example.com');

      expect(service.hasApiKey, isTrue);
    });
  });

  group('TrainingSample YOLO label', () {
    test('formats a class-0 row the server accepts', () {
      final sample = TrainingSample(
        id: 's1',
        imagePath: '/tmp/full.jpg',
        cropPath: '/tmp/crop.jpg',
        centerX: 0.5,
        centerY: 0.25,
        boxWidth: 0.125,
        boxHeight: 0.0625,
        frameIndex: 3,
        imageWidth: 640,
        imageHeight: 360,
        createdAt: DateTime(2026, 5, 7),
      );

      final label = sample.toYoloLabel();
      expect(label, '0 0.500000 0.250000 0.125000 0.062500');

      // Mirrors server/training_server/validation.py's YOLO_LABEL regex.
      final serverPattern = RegExp(
        r'^0\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)'
        r'\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)$',
      );
      expect(serverPattern.hasMatch(label), isTrue,
          reason: 'client label must satisfy the server validator');
    });

    test('boundary values still satisfy the server validator', () {
      final serverPattern = RegExp(
        r'^0\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)'
        r'\s+(?:0(?:\.\d+)?|1(?:\.0+)?)\s+(?:0(?:\.\d+)?|1(?:\.0+)?)$',
      );

      for (final value in [0.0, 1.0, 0.999999]) {
        final sample = TrainingSample(
          id: 's',
          imagePath: 'a',
          cropPath: 'b',
          centerX: value,
          centerY: value,
          boxWidth: value,
          boxHeight: value,
          frameIndex: 0,
          imageWidth: 100,
          imageHeight: 100,
          createdAt: DateTime(2026),
        );
        expect(
          serverPattern.hasMatch(sample.toYoloLabel()),
          isTrue,
          reason: 'value $value produced ${sample.toYoloLabel()}',
        );
      }
    });
  });
}
