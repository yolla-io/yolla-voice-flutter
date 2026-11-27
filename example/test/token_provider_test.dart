//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yolla_voice_example/settings.dart';
import 'package:yolla_voice_example/token_provider.dart';

void main() {
  Matcher failsWith(String text) => throwsA(isA<TokenException>().having((e) => e.message, 'message', contains(text)));

  test('asks the backend for a token for the number, with the demo token as the bearer', () async {
    late Uri askedUrl;
    late Map<String, String> askedHeaders;
    late String askedBody;
    final provider = TokenProvider(
      demoToken: 'demo',
      request: (url, headers, body) async {
        askedUrl = url;
        askedHeaders = headers;
        askedBody = body;
        return (status: 201, body: '{"callToken":"a.b.c"}');
      },
    );
    expect(await provider.token(const Settings(), '+4915112345678'), 'a.b.c');
    expect(askedUrl.toString(), Settings.defaultTokenUrl);
    expect(askedHeaders['Authorization'], 'Bearer demo');
    expect(jsonDecode(askedBody), {'to': '+4915112345678'});
  });

  test('a pasted token is used as it is', () async {
    final provider = TokenProvider(demoToken: '', request: (_, _, _) => fail('no request expected'));
    const settings = Settings(usePastedToken: true, pastedToken: '  a.b.c\n');
    expect(await provider.token(settings, '1'), 'a.b.c');
    await expectLater(provider.token(settings.copyWith(pastedToken: ' '), '1'), failsWith('paste a call token'));
  });

  test('without a demo token it says what to set instead of asking', () async {
    for (final token in ['', TokenProvider.placeholder]) {
      final provider = TokenProvider(demoToken: token, request: (_, _, _) => fail('no request expected'));
      await expectLater(provider.token(const Settings(), '1'), failsWith('YOLLA_VOICE_DEMO_TOKEN'));
    }
  });

  test('what the backend can answer wrongly', () async {
    TokenProvider answering(int status, String body) =>
        TokenProvider(demoToken: 'demo', request: (_, _, _) async => (status: status, body: body));
    await expectLater(answering(401, '').token(const Settings(), '1'), failsWith('HTTP 401'));
    await expectLater(answering(200, 'oops').token(const Settings(), '1'), failsWith('callToken'));
    await expectLater(answering(200, '{"callToken":""}').token(const Settings(), '1'), failsWith('callToken'));
    final offline = TokenProvider(demoToken: 'demo', request: (_, _, _) => throw const SocketException('offline'));
    await expectLater(offline.token(const Settings(), '1'), failsWith('demo.yolla.io'));
  });

  test('settings say what is wrong with them', () {
    expect(const Settings().problem, isNull);
    expect(const Settings(tokenUrl: ' ').problem, contains('required'));
    expect(const Settings(tokenUrl: 'demo.yolla.io').problem, contains('invalid'));
    expect(const Settings(usePastedToken: true).problem, contains('Paste'));
    expect(const Settings(usePastedToken: true, pastedToken: 'a.b.c').problem, isNull);
  });
}
