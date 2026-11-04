import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';

// --dart-define=JAVHUB_PHONE=true: a phone-sized window, to try the phone layout on a PC
const _phone = bool.fromEnvironment('JAVHUB_PHONE');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    runApp(const App());
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      title: 'JavHub',
      size: _phone ? Size(412, 900) : Size(1440, 900),
      minimumSize: _phone ? Size(360, 640) : Size(960, 640),
      center: true,
      backgroundColor: Color(0xFF0E1014),
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(const App());
}
