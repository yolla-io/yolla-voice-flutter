//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'package:material_ui/material_ui.dart';

import 'app_model.dart';
import 'token_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.model});
  final AppModel model;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _url = TextEditingController(text: widget.model.settings.tokenUrl);
  late final _token = TextEditingController(text: widget.model.settings.pastedToken);
  late final Future<String> _sdkVersion = widget.model.client.sdkVersion.catchError((_) => 'unknown');

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model, settings = model.settings;
    const demoTokenSet =
        TokenProvider.buildDemoToken != '' && TokenProvider.buildDemoToken != TokenProvider.placeholder;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Call token', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('From the backend')),
            ButtonSegment(value: true, label: Text('Pasted')),
          ],
          selected: {settings.usePastedToken},
          onSelectionChanged: (value) => model.updateSettings(settings.copyWith(usePastedToken: value.first)),
        ),
        const SizedBox(height: 12),
        if (settings.usePastedToken)
          TextField(
            controller: _token,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Call token',
              helperText: 'A token is good for one call.',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) => model.updateSettings(settings.copyWith(pastedToken: value)),
          )
        else ...[
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Token URL', border: OutlineInputBorder()),
            onChanged: (value) => model.updateSettings(settings.copyWith(tokenUrl: value)),
          ),
          const SizedBox(height: 8),
          Text(
            demoTokenSet
                ? 'The demo token of this build is sent as the bearer.'
                : 'This build has no demo token: set YOLLA_VOICE_DEMO_TOKEN in config/local.json and build again.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 24),
        FutureBuilder<String>(
          future: _sdkVersion,
          builder: (context, version) =>
              Text('Yolla Voice SDK ${version.data ?? '…'}', style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
  }
}
