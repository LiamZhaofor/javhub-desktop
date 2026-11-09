import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'app.dart';
import 'player/player_page.dart';
import 'player/stream_proxy.dart';
import 'theme.dart';
import 'window_frame.dart';
import 'player/player_window.dart';

// --dart-define=JAVHUB_PHONE=true: a phone-sized window, to try the phone layout on a PC
const _phone = bool.fromEnvironment('JAVHUB_PHONE');

// --dart-define=JAVHUB_TEST_PLAYER=<a video file>: a test build that opens the player on that
// file straight away (trying the player's controls without the library or the network)
const _testPlayer = String.fromEnvironment('JAVHUB_TEST_PLAYER');

// --dart-define=JAVHUB_TEST_ITEM=<library id of a 115 movie>: a test build that plays that movie
// through the 115 proxy straight away - not saved as progress, not counted as watched
const _testItem = String.fromEnvironment('JAVHUB_TEST_ITEM');

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  if (_testItem.isNotEmpty) {
    await App.api.restore();
    try {
      await App.api.me();
    } catch (_) {}
    final it = await App.api.libraryItem(_testItem);
    final path = it.sources.first.split('/').map(Uri.encodeComponent).join('/');
    final url = App.api.url('/play/ol$path', {'mode': 'direct', 'relay': '0'});
    final local = await JavStreamProxy.instance.wrap(url, headers: {...App.api.authHeaders, 'X-Jav-Prefetch': '1'});
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: PlayerPage(title: 'Seek test', code: '', resume: false, source: PlaySource(url: local, cloud: true, local: true)),
    ));
    return;
  }
  if (_testPlayer.isNotEmpty) {
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: const PlayerPage(
        title: 'Player test',
        code: 'TEST-001',
        resume: false,
        source: PlaySource(url: _testPlayer, cloud: false, local: true),
      ),
    ));
    return;
  }
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    // the phone: upright everywhere; the player turns it sideways while it is open
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    runApp(const App());
    return;
  }
  // a movie in a window of its own (started by the main window)
  final player = args.indexOf('--player');
  if (player >= 0 && player + 1 < args.length) {
    await runPlayerWindow(args[player + 1]);
    return;
  }
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: 'JavHub',
      size: _phone ? const Size(412, 900) : const Size(1440, 900),
      minimumSize: _phone ? const Size(360, 640) : const Size(960, 640),
      center: true,
      backgroundColor: const Color(0xFF0E1014),
      // Windows: the app draws its own title bar (window_frame.dart)
      titleBarStyle: customTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: !customTitleBar,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );
  await PlayerWindows.watchMainWindow();
  runApp(const App());
}
