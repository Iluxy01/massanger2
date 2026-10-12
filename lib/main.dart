import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'state/app_state.dart';
import 'theme/palette.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final state = AppState();
  // `flutter run --dart-define=DEMO=true` — сразу на главный экран, без онбординга.
  if (const bool.fromEnvironment('DEMO')) {
    state.createProfile(name: 'Демо', emoji: '🐼', colors: avatarGradients[1]);
  }
  runApp(VeilApp(state: state));
}
