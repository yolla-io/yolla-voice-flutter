//
// Copyright (c) 2026 Yolla Calls International OÜ
// Author: Sergei Popov
// SPDX-License-Identifier: MIT
//
// Part of the Yolla Voice example app; see the LICENSE file in the example's folder.
//

import 'package:material_ui/material_ui.dart';

import 'app_model.dart';
import 'dialer_screen.dart';
import 'in_call_screen.dart';
import 'settings_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // One model for the app's whole life: the call is the app's, not a screen's.
  runApp(ExampleApp(model: AppModel()..load()));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.model});
  final AppModel model;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Yolla Voice',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark),
    home: RootScreen(model: model),
  );
}

/// The dialer and the settings; the call screen covers them while there is a call to show.
class RootScreen extends StatefulWidget {
  const RootScreen({super.key, required this.model});
  final AppModel model;

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    widget.model.addListener(_showAlert);
  }

  @override
  void dispose() {
    widget.model.removeListener(_showAlert);
    super.dispose();
  }

  void _showAlert() {
    final text = widget.model.alert;
    if (text == null || !mounted) return;
    widget.model.clearAlert();
    showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: const Text('OK'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model, call = model.shownCall;
      if (call != null) return InCallScreen(model: model, call: call);
      return Scaffold(
        appBar: AppBar(title: const Text('Yolla Voice')),
        body: SafeArea(
          child: _tab == 0 ? DialerScreen(model: model) : SettingsScreen(model: model),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (tab) => setState(() => _tab = tab),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.dialpad), label: 'Dialer'),
            NavigationDestination(icon: Icon(Icons.tune), label: 'Settings'),
          ],
        ),
      );
    },
  );
}
