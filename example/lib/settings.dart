//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'package:shared_preferences/shared_preferences.dart';

/// What the app itself has to know: where its call tokens come from. The destination and the caller ID are inside
/// the call token, and the SDK gets everything else from the platform.
class Settings {
  const Settings({this.tokenUrl = defaultTokenUrl, this.pastedToken = '', this.usePastedToken = false});

  /// The Yolla demo backend that issues call tokens; replace it with your own backend in Settings.
  static const defaultTokenUrl = 'https://demo.yolla.io/api/calls';

  /// The app backend that issues a call token for each call.
  final String tokenUrl;

  /// A call token pasted by hand, for quick manual tests; a token is good for one call.
  final String pastedToken;
  final bool usePastedToken;

  Settings copyWith({String? tokenUrl, String? pastedToken, bool? usePastedToken}) => Settings(
    tokenUrl: tokenUrl ?? this.tokenUrl,
    pastedToken: pastedToken ?? this.pastedToken,
    usePastedToken: usePastedToken ?? this.usePastedToken,
  );

  /// What is wrong, for the user; null when the settings can be used for a call.
  String? get problem {
    if (usePastedToken) return pastedToken.trim().isEmpty ? 'Paste a call token or switch to the token URL' : null;
    final url = Uri.tryParse(tokenUrl.trim());
    if (tokenUrl.trim().isEmpty) return 'A token URL is required';
    if (url == null || !url.scheme.startsWith('http') || url.host.isEmpty) return 'The token URL is invalid';
    return null;
  }
}

/// Kept in the app's preferences for the example; a production app has no tokens to keep at all.
class SettingsStore {
  static const _url = 'tokenUrl', _token = 'pastedToken', _pasted = 'usePastedToken';

  Future<Settings> load() async {
    final preferences = await SharedPreferences.getInstance();
    return Settings(
      tokenUrl: preferences.getString(_url) ?? Settings.defaultTokenUrl,
      pastedToken: preferences.getString(_token) ?? '',
      usePastedToken: preferences.getBool(_pasted) ?? false,
    );
  }

  Future<void> save(Settings settings) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_url, settings.tokenUrl);
    await preferences.setString(_token, settings.pastedToken);
    await preferences.setBool(_pasted, settings.usePastedToken);
  }
}
