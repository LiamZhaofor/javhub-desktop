import 'dart:async';

import 'package:flutter/material.dart';

import 'api.dart';
import 'models.dart';
import 'screens/jobs.dart';
import 'screens/library.dart';
import 'screens/search.dart';
import 'screens/settings.dart';
import 'screens/wishlist.dart';
import 'widgets.dart';

class App extends StatefulWidget {
  const App({super.key});

  static final api = JavHubApi();
  static final navigator = GlobalKey<NavigatorState>();

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  // null: still checking the stored session
  bool? _loggedIn;

  @override
  void initState() {
    super.initState();
    App.api.onUnauthorized = () {
      if (mounted && _loggedIn == true) setState(() => _loggedIn = false);
    };
    unawaited(_check());
  }

  Future<void> _check() async {
    await App.api.restore();
    var ok = false;
    try {
      ok = await App.api.me();
    } catch (_) {
      // offline: show the shell anyway, with what is cached
      ok = App.api.loggedIn;
    }
    if (mounted) setState(() => _loggedIn = ok);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark, surface: const Color(0xFF111318));
    return MaterialApp(
      title: 'JavHub',
      navigatorKey: App.navigator,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFF0E1014),
        fontFamily: 'Microsoft YaHei UI',
        visualDensity: VisualDensity.compact,
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      ),
      home: switch (_loggedIn) {
        null => const Scaffold(body: Center(child: CircularProgressIndicator())),
        false => LoginPage(onDone: () => setState(() => _loggedIn = true)),
        true => Shell(onLogout: () => setState(() => _loggedIn = false)),
      },
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onDone});

  final VoidCallback onDone;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final _server = TextEditingController(text: App.api.server);
  late final _user = TextEditingController(text: App.api.user.isEmpty ? 'admin' : App.api.user);
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await App.api.login(_server.text, _user.text.trim(), _password.text);
      await App.api.me();
      widget.onDone();
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: SizedBox(
        width: 360,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.play_circle_fill, color: accent, size: 32),
                      SizedBox(width: 8),
                      Text('JavHub', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 24),
                  TextField(controller: _server, decoration: const InputDecoration(labelText: '服务器地址')),
                  const SizedBox(height: 12),
                  TextField(controller: _user, decoration: const InputDecoration(labelText: '用户名'),
                      autofillHints: const [AutofillHints.username]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '密码'),
                    autofillHints: const [AutofillHints.password],
                    onSubmitted: (_) => _busy ? null : _login(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _login,
                    child: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('登录'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

/// The main window: navigation rail on the left, one page at a time.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.onLogout});

  final VoidCallback onLogout;

  /// Lets a page switch to the search page with a code (e.g. 查找其它版本).
  static void search(BuildContext context, String code) =>
      context.findAncestorStateOfType<_ShellState>()?._openSearch(code);

  /// Opens the library filtered by an actress / studio / tag.
  static void filterLibrary(BuildContext context, String query) =>
      context.findAncestorStateOfType<_ShellState>()?._openLibrary(query);

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _searchKey = GlobalKey<SearchPageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  int _activeJobs = 0;
  Timer? _jobsTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_pollJobs());
  }

  @override
  void dispose() {
    _jobsTimer?.cancel();
    super.dispose();
  }

  Future<void> _pollJobs() async {
    _jobsTimer?.cancel();
    try {
      final jobs = await App.api.jobs();
      final n = jobs.where((j) => j.active).length;
      if (mounted && n != _activeJobs) setState(() => _activeJobs = n);
    } catch (_) {}
    if (mounted) _jobsTimer = Timer(Duration(seconds: _activeJobs > 0 ? 5 : 30), _pollJobs);
  }

  void _openSearch(String code) {
    setState(() => _tab = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchKey.currentState?.search(code));
  }

  void _openLibrary(String query) {
    setState(() => _tab = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _libraryKey.currentState?.setQuery(query));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      LibraryPage(key: _libraryKey),
      SearchPage(key: _searchKey, onJobCreated: _pollJobs),
      const JobsPage(),
      const WishlistPage(),
      SettingsPage(onLogout: widget.onLogout),
    ];
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Icon(Icons.play_circle_fill, color: accent, size: 30),
            ),
            destinations: [
              const NavigationRailDestination(icon: Icon(Icons.video_library_outlined),
                  selectedIcon: Icon(Icons.video_library), label: Text('片库')),
              const NavigationRailDestination(icon: Icon(Icons.search), label: Text('搜索')),
              NavigationRailDestination(
                icon: Badge(isLabelVisible: _activeJobs > 0, label: Text('$_activeJobs'), child: const Icon(Icons.download_outlined)),
                selectedIcon: Badge(isLabelVisible: _activeJobs > 0, label: Text('$_activeJobs'), child: const Icon(Icons.download)),
                label: const Text('任务'),
              ),
              const NavigationRailDestination(icon: Icon(Icons.favorite_border), selectedIcon: Icon(Icons.favorite), label: Text('想看')),
              const NavigationRailDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: Text('设置')),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: IndexedStack(index: _tab, children: pages)),
        ],
      ),
    );
  }
}

/// Label for how many jobs are running, for pages that show it.
String jobsSummary(List<Job> jobs) {
  final n = jobs.where((j) => j.active).length;
  return n == 0 ? '没有进行中的任务' : '$n 个进行中';
}
