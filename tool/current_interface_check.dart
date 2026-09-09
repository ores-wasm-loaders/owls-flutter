import 'dart:convert';
import 'dart:io';

import 'package:owls_flutter/owls_flutter.dart';

bool _deepEqual(Object? left, Object? right) {
  if (identical(left, right) || left == right) return true;
  if (left is List && right is List) {
    return left.length == right.length &&
        Iterable<int>.generate(
          left.length,
        ).every((index) => _deepEqual(left[index], right[index]));
  }
  if (left is Map && right is Map) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _deepEqual(left[key], right[key]),
        );
  }
  return false;
}

Never _fail(String message) => throw StateError(message);

Future<void> main() async {
  final directory = Directory(
    'zed_modules/ores-wasm-loaders/owls-interfaces/fixtures/valid',
  );
  if (!directory.existsSync()) {
    _fail('current interface fixture directory is missing');
  }

  final fixtures = directory
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  if (fixtures.length < 4) _fail('expected the current v1/v2 fixture corpus');

  var sawV1 = false;
  var sawV2 = false;
  for (final fixture in fixtures) {
    final decoded = jsonDecode(await fixture.readAsString());
    if (decoded is! Map<String, dynamic>) {
      _fail('${fixture.path}: release root must be an object');
    }
    final assets = decoded['assets'];
    if (assets is! List || assets.isEmpty) {
      _fail('${fixture.path}: release assets must be a non-empty array');
    }
    final origins = assets
        .map((asset) =>
            Uri.parse((asset as Map<String, dynamic>)['url'] as String).origin)
        .toSet()
        .toList()
      ..sort();

    final parsed = parseRelease(decoded, origins);
    sawV1 = sawV1 || parsed.schemaVersion == 1;
    sawV2 = sawV2 || parsed.schemaVersion == 2;
    final roundTrip = jsonDecode(jsonEncode(parsed));
    if (!_deepEqual(decoded, roundTrip)) {
      _fail('${fixture.path}: Flutter host round trip changed the release');
    }
  }

  if (!sawV1 || !sawV2) {
    _fail('Flutter host did not consume both release generations');
  }
  stdout.writeln(
    'PASS: ${fixtures.length} current release fixtures crossed the Flutter host boundary',
  );
}
