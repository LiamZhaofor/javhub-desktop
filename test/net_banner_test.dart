import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:javhub_desktop/app.dart';
import 'package:javhub_desktop/theme.dart';

/// A page with something of its own to lose (as a page's scroll or filters).
class _Counter extends StatefulWidget {
  const _Counter();

  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;

  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => setState(() => n++), child: Text('count $n'));
}

void main() {
  tearDown(() => App.api.netDownSince.value = null);

  for (final compact in [false, true]) {
    testWidgets('外网不通 banner comes and goes, the page keeps its state (compact: $compact)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: WithNetBanner(compact: compact, child: const _Counter())),
      ));
      expect(find.textContaining('外网不通'), findsNothing);
      await tester.tap(find.text('count 0'));
      await tester.pump();

      final since = DateTime(2026, 11, 18, 9, 5).millisecondsSinceEpoch / 1000;
      App.api.netDownSince.value = since;
      await tester.pump();
      expect(find.textContaining('外网不通（自 11-18 09:05 起）：刮削暂停'), findsOneWidget);
      expect(find.text('count 1'), findsOneWidget);

      App.api.netDownSince.value = 0; // down, since unknown
      await tester.pump();
      expect(find.textContaining('外网不通：刮削暂停'), findsOneWidget);

      App.api.netDownSince.value = null;
      await tester.pump();
      expect(find.textContaining('外网不通'), findsNothing);
      expect(find.text('count 1'), findsOneWidget);
    });
  }
}
