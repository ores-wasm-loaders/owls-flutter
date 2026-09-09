import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const expectedDeclarations = <String>[
  'Ores.WasmLoaders.Activation',
  'Ores.WasmLoaders.ActivationMode',
  'Ores.WasmLoaders.ApplicationId',
  'Ores.WasmLoaders.Asset',
  'Ores.WasmLoaders.AssetId',
  'Ores.WasmLoaders.AssetKind',
  'Ores.WasmLoaders.AssetRole',
  'Ores.WasmLoaders.AssetStage',
  'Ores.WasmLoaders.EntrypointId',
  'Ores.WasmLoaders.FrameworkKind',
  'Ores.WasmLoaders.HostSelector',
  'Ores.WasmLoaders.HttpsAssetUrl',
  'Ores.WasmLoaders.IslandName',
  'Ores.WasmLoaders.PrepareBudget',
  'Ores.WasmLoaders.PrepareStage',
  'Ores.WasmLoaders.RecordString',
  'Ores.WasmLoaders.RecordUnknown',
  'Ores.WasmLoaders.Release',
  'Ores.WasmLoaders.ReleaseId',
  'Ores.WasmLoaders.RuntimeKind',
  'Ores.WasmLoaders.SchemaVersion',
  'Ores.WasmLoaders.Sha256Hex',
  'Ores.WasmLoaders.ToolchainId',
];

String exactRef(String workflow, String name) {
  final match = RegExp('^\\s*$name:\\s*([0-9a-f]{40})\\s*\$', multiLine: true)
      .firstMatch(workflow);
  expect(match, isNotNull, reason: '$name must be an immutable commit SHA');
  return match!.group(1)!;
}

void main() {
  test(
      'Flutter current-contract boundary uses canonical complete-scope TJSV admission',
      () {
    final workflow =
        File('.github/workflows/flutter-package.yml').readAsStringSync();
    final currentInterfaces = exactRef(workflow, 'CURRENT_INTERFACES_REF');
    final releasedInterfaces = exactRef(workflow, 'RELEASED_INTERFACES_REF');
    final validator = exactRef(workflow, 'TSJSV_REF');

    expect(currentInterfaces, '76364a23364993ff4be1ed82a4978725ed6f811c');
    expect(validator, '03ccc0ecdfc70f9198c3ccf80718910961d3fde1');
    expect(currentInterfaces, isNot(releasedInterfaces),
        reason:
            'released package lock and current compatibility canary are distinct boundaries');

    expect(workflow,
        contains('repository: ORESoftware/typespec-json-schema-validator'));
    expect(workflow, contains('ref: \${{ env.TSJSV_REF }}'));
    expect(workflow, contains('ref: \${{ env.CURRENT_INTERFACES_REF }}'));
    expect(workflow,
        contains('--instances=.typespec-json-schema-validator/instances'));
    expect(workflow, contains('fixtures/valid/*.json'));
    expect(workflow, contains('instances/Release/valid'));
    expect(
      workflow,
      contains(
        'ORESoftware/typespec-json-schema-validator/actions/verify-contract-ir@'
        '03ccc0ecdfc70f9198c3ccf80718910961d3fde1',
      ),
    );
    expect(workflow, contains('tjsv-consumer-verification.json'));
    expect(workflow, contains('node scripts/verify-contract-ir.mjs'));
    expect(workflow, contains('node scripts/check-language-projections.mjs'));

    for (final declaration in expectedDeclarations) {
      expect(workflow, contains('"$declaration"'),
          reason: 'complete-scope TJSV admission is missing $declaration');
    }

    expect(
      workflow,
      isNot(matches(RegExp(
        r'repository:\s*ORESoftware/typespec-json-schema-validator[\s\S]{0,240}?ref:\s*(?:main|master|v\d+)',
      ))),
      reason: 'the Flutter host must not use a mutable TJSV ref',
    );
  });
}
