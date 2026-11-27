//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'dart:convert';
import 'dart:io';

import 'settings.dart';

/// Why there is no call token; [message] is for the user.
class TokenException implements Exception {
  const TokenException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// One HTTP request, so that tests can answer it themselves.
typedef TokenRequest = Future<({int status, String body})> Function(Uri url, Map<String, String> headers, String body);

/// Supplies the call token for `VoiceClient.connect`: from the app's backend (`POST <url>` with `{"to": …}`, which
/// answers `{"callToken": …}`) or a pasted one.
class TokenProvider {
  TokenProvider({this.demoToken = buildDemoToken, TokenRequest? request}) : _request = request ?? _post;

  /// What the build setting holds until a token is set.
  static const placeholder = 'YOUR_DEMO_TOKEN';

  /// The demo backend's credential, which its token endpoint expects as the bearer. It is not in the code: it comes
  /// from the build (`--dart-define-from-file=config/local.json`, a git-ignored copy of `config/example.json`).
  /// A production app authorises this request with the user's own session instead.
  static const buildDemoToken = String.fromEnvironment('YOLLA_VOICE_DEMO_TOKEN');

  final String demoToken;
  final TokenRequest _request;

  /// [number] is the dialed number, sent to the backend as typed; a pasted token ignores it.
  Future<String> token(Settings settings, String number) async {
    if (settings.usePastedToken) {
      final token = settings.pastedToken.trim();
      if (token.isEmpty) throw const TokenException('No token: paste a call token in Settings');
      return token;
    }
    final url = Uri.tryParse(settings.tokenUrl.trim());
    if (url == null || url.host.isEmpty) throw const TokenException('The token URL is invalid');
    final bearer = demoToken.trim();
    // Without the token the backend would only answer 401: say what is missing instead.
    if (bearer.isEmpty || bearer == placeholder) {
      throw const TokenException(
        'No demo token: put YOLLA_VOICE_DEMO_TOKEN into config/local.json and build again, or paste a call token '
        'in Settings',
      );
    }
    final ({int status, String body}) response;
    try {
      response = await _request(url, {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'Authorization': 'Bearer $bearer',
      }, jsonEncode({'to': number}));
    } on IOException catch (e) {
      throw TokenException('Token request failed (${url.host}): $e');
    }
    if (response.status < 200 || response.status >= 300) {
      throw TokenException('The token endpoint returned HTTP ${response.status}');
    }
    try {
      final token = (jsonDecode(response.body) as Map<String, dynamic>)['callToken'];
      if (token is String && token.isNotEmpty) return token;
    } on Object {
      // Falls through: not the JSON the app expects.
    }
    throw const TokenException('The token endpoint did not return {"callToken": …}');
  }

  static Future<({int status, String body})> _post(Uri url, Map<String, String> headers, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.postUrl(url);
      headers.forEach(request.headers.set);
      request.add(utf8.encode(body));
      final response = await request.close().timeout(const Duration(seconds: 20));
      return (status: response.statusCode, body: await response.transform(utf8.decoder).join());
    } finally {
      client.close();
    }
  }
}
