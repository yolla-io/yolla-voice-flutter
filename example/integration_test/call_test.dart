//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Runs on a device or a simulator against the real native side and the real platform, without ringing anybody:
// the tokens here are not ones the platform issued, so it refuses them.
//
//   flutter test integration_test -d <device>
//

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yolla_voice/yolla_voice.dart';

/// A token the SDK can read (it has the claims) and the platform cannot accept (nobody signed it).
String unsignedToken(String callId) {
  String part(Object json) => base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return [
    part({'alg': 'none', 'typ': 'JWT'}),
    part({'iss': 'yolla-voice', 'jti': callId, 'to': '+4915112345678', 'cli': 'anonymous', 'exp': now + 60}),
    'c2ln',
  ].join('.');
}

Future<Call> ended(VoiceClient client, String callId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final call = client.call.value;
    if (call != null && call.callId == callId && !call.isActive) return call;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('the call did not end: ${client.call.value}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final client = VoiceClient();

  testWidgets('the native SDK is there', (tester) async {
    expect(await client.sdkVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });

  testWidgets('a token that cannot be read starts nothing', (tester) async {
    await expectLater(
      client.connect('not a token'),
      throwsA(isA<VoiceError>().having((e) => e.code, 'code', VoiceError.invalidToken)),
    );
    expect(client.call.value, isNull);
    await expectLater(
      client.setMuted(true),
      throwsA(isA<VoiceError>().having((e) => e.code, 'code', VoiceError.invalidCallState)),
    );
    await client.hangup();
  });

  testWidgets('a call the platform refuses ends as failed, and the client is free again', (tester) async {
    final seen = <CallState>[];
    void record() {
      final state = client.call.value?.state;
      if (state != null && (seen.isEmpty || seen.last != state)) seen.add(state);
    }

    client.call.addListener(record);
    addTearDown(() => client.call.removeListener(record));

    await client.connect(unsignedToken('call_flutter_test_1'));
    final started = client.call.value;
    expect(started?.callId, 'call_flutter_test_1');
    expect(started?.to, '+4915112345678');
    expect(started?.from, const AnonymousCallerId());
    // While it is being set up: one call at a time, and the audio routes of the call are there.
    if (started!.isActive) {
      await expectLater(
        client.connect(unsignedToken('call_flutter_test_x')),
        throwsA(isA<VoiceError>().having((e) => e.code, 'code', VoiceError.callInProgress)),
      );
    }

    final call = await ended(client, 'call_flutter_test_1');
    expect(call.endReason, CallEndReason.failed);
    expect(call.error, isNotNull);
    expect(call.wasConnected, isFalse);
    expect(seen.first, CallState.connecting);
    expect(seen.last, CallState.disconnected);
    debugPrint('refused call: ${call.error}');

    // The next call starts once the previous one is released (its end tone has played).
    await client.connect(unsignedToken('call_flutter_test_2'));
    expect(client.call.value?.callId, 'call_flutter_test_2');
    await client.hangup();
    final second = await ended(client, 'call_flutter_test_2');
    expect(second.endReason, anyOf(CallEndReason.cancelled, CallEndReason.failed));
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(client.audioRoutes.value.available, isEmpty);
  });
}
