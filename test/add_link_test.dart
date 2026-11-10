import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:javhub_desktop/api.dart';
import 'package:javhub_desktop/models.dart';
import 'package:javhub_desktop/screens/jobs.dart';

const _ed2k = 'ed2k://|file|%5BHD%5DSSIS-001-C.mp4|5368709120|0123456789ABCDEF0123456789ABCDEF|/';

/// JavHub with two places to download to (115 by default, with two library folders)
/// that records the jobs asked for.
JavHubApi _api(List<Map<String, dynamic>> posted) => JavHubApi(
  client: MockClient((r) async {
    if (r.url.path == '/api/backends') {
      return http.Response(
        jsonEncode({
          'default': 'cloud:115 Cloud',
          'backends': [
            {'name': 'qbittorrent', 'ok': true, 'dir': '/media/jav'},
            {'name': 'cloud:115 Cloud', 'ok': true, 'dir': '/115/jav', 'dirs': ['/115/jav', '/115/jav2']},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (r.url.path == '/api/jobs' && r.method == 'POST') {
      final b = jsonDecode(r.body) as Map<String, dynamic>;
      posted.add(b);
      final code = (b['code'] as String).isEmpty ? 'SSIS-001' : (b['code'] as String).toUpperCase();
      return http.Response(jsonEncode({'job': {'id': 'j1', 'code': code, 'backend': b['backend'], 'status': 'queued'}}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 404);
  }),
);

Future<Job?> _open(WidgetTester tester, JavHubApi api, Size size, {String clipboard = ''}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'Clipboard.getData') return {'text': clipboard};
    return null;
  });
  Job? result;
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () async => result = await showDialog<Job>(context: context, builder: (_) => AddLinkDialog(api: api)),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

ChoiceChip _chip(WidgetTester tester, String title) =>
    tester.widget<ChoiceChip>(find.ancestor(of: find.text(title), matching: find.byType(ChoiceChip)));

void main() {
  for (final (name, size) in [('desktop', const Size(1280, 800)), ('phone', const Size(360, 740))]) {
    testWidgets('an ed2k link copied before opening is filled in and goes to 115 ($name)', (tester) async {
      final posted = <Map<String, dynamic>>[];
      await _open(tester, _api(posted), size, clipboard: _ed2k);
      expect(tester.takeException(), isNull); // nothing overflows
      expect(find.text(_ed2k), findsOneWidget);
      expect(find.text('文件名：[HD]SSIS-001-C.mp4'), findsOneWidget);
      // qBittorrent cannot take an ed2k link: shown, not selectable; 115 is chosen
      expect(_chip(tester, 'NAS（BT 下载）').onSelected, isNull);
      expect(_chip(tester, '115 网盘').selected, isTrue);
      await tester.tap(find.text('开始下载'));
      await tester.pumpAndSettle();
      expect(posted, [
        {'code': '', 'magnet': _ed2k, 'backend': 'cloud:115 Cloud', 'replace': false},
      ]);
      expect(find.byType(AddLinkDialog), findsNothing); // closed with the job
    });
  }

  testWidgets('a magnet with a typed code may go to qBittorrent; anything else is not sent', (tester) async {
    final posted = <Map<String, dynamic>>[];
    await _open(tester, _api(posted), const Size(1280, 800));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://example.com/a.torrent');
    await tester.pump();
    expect(find.text('不是磁力或 ed2k 链接'), findsOneWidget);
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(posted, isEmpty);
    expect(find.textContaining('请粘贴磁力链接'), findsOneWidget);

    await tester.enterText(fields.at(0), 'magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567');
    await tester.pump();
    expect(find.text('这个链接没有文件名，请填上番号'), findsOneWidget);
    expect(_chip(tester, 'NAS（BT 下载）').onSelected, isNotNull);
    await tester.tap(find.text('NAS（BT 下载）'));
    await tester.enterText(fields.at(1), 'abp-123');
    await tester.tap(find.text('开始下载'));
    await tester.pumpAndSettle();
    expect(posted.single['backend'], 'qbittorrent');
    expect(posted.single['code'], 'abp-123');
    expect(tester.takeException(), isNull);
  });
}
