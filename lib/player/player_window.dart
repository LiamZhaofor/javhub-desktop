import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../theme.dart';
import '../window_frame.dart';
import 'player_page.dart';

/// What a player window is started with (on its command line, as base64 JSON).
class PlayerArgs {
  const PlayerArgs({
    required this.title,
    required this.code,
    required this.itemId,
    required this.part,
    required this.source,
    required this.subtitles,
    this.start = 0,
    this.from = '',
    this.lanBase,
    this.bounds,
    this.maximized = false,
  });

  final String title;
  final String code;
  final String itemId;
  final int part;
  final PlaySource source;
  final List<(String, String)> subtitles;

  /// Where to start (seconds) and on which device it was left; worked out by the
  /// main window while it got the stream ready.
  final int start;
  final String from;

  /// The main window's home-network address of JavHub, when it uses one.
  final String? lanBase;

  /// The main window's place on the screen: the player opens over it.
  final Rect? bounds;
  final bool maximized;

  String encode() => base64Url.encode(utf8.encode(jsonEncode({
    'title': title,
    'code': code,
    'item': itemId,
    'part': part,
    'url': source.url,
    'cloud': source.cloud,
    'local': source.local,
    'subs': [for (final (n, u) in subtitles) [n, u]],
    'start': start,
    'from': from,
    'lan': lanBase,
    if (bounds != null) 'bounds': [bounds!.left, bounds!.top, bounds!.width, bounds!.height],
    'max': maximized,
  })));

  factory PlayerArgs.decode(String s) {
    final j = jsonDecode(utf8.decode(base64Url.decode(s))) as Map<String, dynamic>;
    final b = (j['bounds'] as List?)?.map((v) => (v as num).toDouble()).toList();
    return PlayerArgs(
      title: '${j['title'] ?? ''}',
      code: '${j['code'] ?? ''}',
      itemId: '${j['item'] ?? ''}',
      part: (j['part'] as num?)?.toInt() ?? 0,
      source: PlaySource(url: '${j['url']}', cloud: j['cloud'] == true, local: j['local'] == true),
      subtitles: [for (final s in (j['subs'] as List? ?? const [])) ('${(s as List)[0]}', '${s[1]}')],
      start: (j['start'] as num?)?.toInt() ?? 0,
      from: '${j['from'] ?? ''}',
      lanBase: j['lan'] as String?,
      bounds: b == null || b.length != 4 ? null : Rect.fromLTWH(b[0], b[1], b[2], b[3]),
      maximized: j['max'] == true,
    );
  }
}

/// The player windows the main window started (Windows): each one its own
/// process, so a movie plays in a window of its own next to the library.
class PlayerWindows {
  static final _open = <String, Process>{};
  static bool _mainClosing = false;

  static bool get any => _open.isNotEmpty;

  /// Brings the window playing part [part] of [itemId] to the front; false when
  /// there is none.
  static bool focus(String itemId, int part) {
    final p = _open['$itemId#$part'];
    if (p == null) return false;
    p.stdin.writeln('focus');
    return true;
  }

  /// Starts a player window; [onClosed] runs when it is gone. A movie that is
  /// already playing in a window brings that window to the front instead.
  static Future<void> open(PlayerArgs args, {VoidCallback? onClosed}) async {
    final key = '${args.itemId}#${args.part}';
    if (focus(args.itemId, args.part)) return;
    final p = await Process.start(Platform.resolvedExecutable, ['--player', args.encode()]);
    _open[key] = p;
    unawaited(p.stdout.drain<void>());
    unawaited(p.stderr.drain<void>());
    unawaited(p.exitCode.then((_) {
      _open.remove(key);
      onClosed?.call();
      // the library window was closed while this one played: now it can go
      if (_mainClosing && _open.isEmpty) _quit();
    }));
  }

  /// The main window's close button: with players still open (their 115 streams
  /// run through this process) it only hides, and goes when the last one does.
  static Future<void> watchMainWindow() async {
    await windowManager.setPreventClose(true);
    windowManager.addListener(_MainWindowCloser());
  }
}

class _MainWindowCloser with WindowListener {
  @override
  void onWindowClose() {
    if (PlayerWindows.any) {
      PlayerWindows._mainClosing = true;
      unawaited(windowManager.hide());
    } else {
      _quit();
    }
  }
}

/// The main window's last step. Linux: destroying Flutter's (only) view crashes the engine
/// on the way out, so the process just ends.
void _quit() => exit(0); // (tearing the engine down in order took seconds, and crashed it on Linux)

/// `JavHub.exe --player <args>`: one movie in a window.
Future<void> runPlayerWindow(String encoded) async {
  final args = PlayerArgs.decode(encoded);
  await windowManager.ensureInitialized();
  await App.api.restore();
  if (args.lanBase != null) App.api.useLan(args.lanBase!);
  final b = args.bounds;
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      title: args.title,
      size: b?.size ?? const Size(1280, 760),
      minimumSize: const Size(640, 400),
      center: b == null,
      backgroundColor: Colors.black,
      // Windows: the player's own top bar carries the caption buttons
      titleBarStyle: customTitleBar ? TitleBarStyle.hidden : TitleBarStyle.normal,
      windowButtonVisibility: !customTitleBar,
    ),
    () async {
      if (b != null) await windowManager.setPosition(b.topLeft);
      if (args.maximized) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    },
  );
  runApp(_PlayerWindowApp(args: args));
  // the main window asks for this window again (the same movie played twice). After the
  // first frame, and never fatal: without a pipe on stdin, reading it kept the window blank.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    try {
      stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) async {
        if (line.trim() == 'focus') {
          if (await windowManager.isMinimized()) await windowManager.restore();
          await windowManager.show();
          await windowManager.focus();
        }
      }, onError: (_) {}, cancelOnError: false);
    } catch (_) {}
  });
}

class _PlayerWindowApp extends StatelessWidget {
  const _PlayerWindowApp({required this.args});

  final PlayerArgs args;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: args.title,
    debugShowCheckedModeBanner: false,
    locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
    supportedLocales: const [
      Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
      Locale('en'),
    ],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: buildTheme(Brightness.dark),
    home: PlayerPage(
      title: args.title,
      code: args.code,
      itemId: args.itemId,
      part: args.part,
      source: args.source,
      subtitles: args.subtitles,
      startAt: (args.start, args.from),
      windowed: true,
    ),
  );
}
