import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api.dart';
import 'platform.dart';
import 'screens/home.dart';
import 'screens/jobs.dart';
import 'screens/library.dart';
import 'screens/search.dart';
import 'screens/settings.dart';
import 'screens/wishlist.dart';
import 'theme.dart';

class App extends StatefulWidget {
  const App({super.key});

  static final api = JavHubApi();

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
    await ThemeController.instance.restore();
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
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: ThemeController.instance,
    builder: (context, mode, _) => MaterialApp(
      title: 'JavHub',
      debugShowCheckedModeBanner: false,
      // Chinese UI text, and on Android the Simplified Chinese system font (as an
      // English app the Han fallback landed on a serif)
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
      supportedLocales: const [Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      themeAnimationDuration: const Duration(milliseconds: 200),
      home: switch (_loggedIn) {
        null => const Scaffold(body: Center(child: CircularProgressIndicator())),
        false => LoginPage(onDone: () => setState(() => _loggedIn = true)),
        true => Shell(onLogout: () => setState(() => _loggedIn = false)),
      },
    ),
  );
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
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      body: Stack(children: [
        // a soft accent glow behind the card
        Positioned(
          top: -220,
          left: -160,
          child: Container(
            width: 620,
            height: 620,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [accent.withValues(alpha: 0.22), accent.withValues(alpha: 0)]),
            ),
          ),
        ),
        Center(
          child: SizedBox(
            width: 380,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                child: AutofillGroup(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: Logo(size: 46)),
                      const SizedBox(height: 14),
                      Text('JavHub', textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: p.text)),
                      const SizedBox(height: 4),
                      Text('登录你的片库', textAlign: TextAlign.center, style: TextStyle(color: p.muted)),
                      const SizedBox(height: 26),
                      TextField(controller: _server, decoration: const InputDecoration(labelText: '服务器地址', prefixIcon: Icon(Icons.dns_outlined, size: 18))),
                      const SizedBox(height: 12),
                      TextField(controller: _user, decoration: const InputDecoration(labelText: '用户名', prefixIcon: Icon(Icons.person_outline, size: 18)),
                          autofillHints: const [AutofillHints.username]),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _password,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_outline, size: 18)),
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _busy ? null : _login(),
                      ),
                      if (_error != null) ...[
                        const SizedBox(height: 12),
                        Text(_error!, style: const TextStyle(color: accent)),
                      ],
                      const SizedBox(height: 22),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: _busy
                            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Text('登录'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class Logo extends StatelessWidget {
  const Logo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(size * 0.28),
      gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFF6B70), accent]),
      boxShadow: [BoxShadow(color: accent.withValues(alpha: 0.35), blurRadius: size * 0.4, offset: Offset(0, size * 0.1))],
    ),
    child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: size * 0.7),
  );
}

/// The main window: a sidebar on the left, one page at a time.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.onLogout});

  final VoidCallback onLogout;

  /// Switches to the search page with a code (e.g. 查找其它版本).
  static void search(BuildContext context, String code) =>
      context.findAncestorStateOfType<_ShellState>()?._openSearch(code);

  /// Switches to the library, filtered by an actress / studio / tag.
  static void filterLibrary(BuildContext context, String query) =>
      context.findAncestorStateOfType<_ShellState>()?._openLibrary(query);

  @override
  State<Shell> createState() => _ShellState();
}

class _NavItem {
  const _NavItem(this.icon, this.selected, this.label, [String? short]) : short = short ?? label;

  final IconData icon;
  final IconData selected;
  final String label;

  /// Under the icon of a phone's bottom bar.
  final String short;
}

const _nav = [
  _NavItem(Icons.home_outlined, Icons.home_rounded, '首页'),
  _NavItem(Icons.video_library_outlined, Icons.video_library_rounded, '片库'),
  _NavItem(Icons.search_rounded, Icons.saved_search_rounded, '搜索与推荐', '搜索'),
  _NavItem(Icons.download_outlined, Icons.download_rounded, '下载任务', '任务'),
  _NavItem(Icons.favorite_border_rounded, Icons.favorite_rounded, '想看'),
  _NavItem(Icons.tune_outlined, Icons.tune_rounded, '设置'),
];

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _searchKey = GlobalKey<SearchPageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _homeKey = GlobalKey<HomePageState>();
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
    setState(() => _tab = 2);
    WidgetsBinding.instance.addPostFrameCallback((_) => _searchKey.currentState?.search(code));
  }

  void _openLibrary(String query) {
    setState(() => _tab = 1);
    WidgetsBinding.instance.addPostFrameCallback((_) => _libraryKey.currentState?.setQuery(query));
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pages = [
      HomePage(key: _homeKey),
      LibraryPage(key: _libraryKey),
      SearchPage(key: _searchKey, onJobCreated: _pollJobs),
      const JobsPage(),
      const WishlistPage(),
      SettingsPage(onLogout: widget.onLogout),
    ];
    if (isCompact(context)) {
      return Scaffold(
        body: IndexedStack(index: _tab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          height: 64,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          indicatorColor: accent.withValues(alpha: 0.18),
          onDestinationSelected: (i) {
            if (i == 0 && _tab != 0) unawaited(_homeKey.currentState?.reload());
            setState(() => _tab = i);
          },
          destinations: [
            for (var i = 0; i < _nav.length; i++)
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: i == 3 && _activeJobs > 0,
                  label: Text('$_activeJobs'),
                  child: Icon(_nav[i].icon),
                ),
                selectedIcon: Icon(_nav[i].selected, color: accent),
                label: _nav[i].short,
              ),
          ],
        ),
      );
    }
    return Scaffold(
      // a phone held sideways also gets the sidebar: keep it clear of the status bar / notch
      body: SafeArea(
        top: !isDesktop,
        bottom: !isDesktop,
        left: !isDesktop,
        right: false,
        child: Row(
        children: [
          Container(
            width: 208,
            decoration: BoxDecoration(color: p.sidebar, border: Border(right: BorderSide(color: p.line))),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 22, 16, 22),
                  child: Row(children: [
                    const Logo(size: 30),
                    const SizedBox(width: 10),
                    Text('JavHub', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: p.text)),
                  ]),
                ),
                for (var i = 0; i < _nav.length; i++)
                  _SideButton(
                    item: _nav[i],
                    selected: _tab == i,
                    badge: i == 3 && _activeJobs > 0 ? '$_activeJobs' : null,
                    onTap: () {
                      // back to 首页: show what was just watched
                      if (i == 0 && _tab != 0) unawaited(_homeKey.currentState?.reload());
                      setState(() => _tab = i);
                    },
                  ),
                const Spacer(),
                const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 14), child: ThemeToggle()),
              ],
            ),
          ),
          Expanded(child: IndexedStack(index: _tab, children: pages)),
        ],
      ),
      ),
    );
  }
}

class _SideButton extends StatefulWidget {
  const _SideButton({required this.item, required this.selected, required this.onTap, this.badge});

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final String? badge;

  @override
  State<_SideButton> createState() => _SideButtonState();
}

class _SideButtonState extends State<_SideButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = widget.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 42,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: on ? accent.withValues(alpha: 0.13) : (_hover ? p.raised : Colors.transparent),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                width: 3,
                height: on ? 18 : 0,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
              ),
              Icon(on ? widget.item.selected : widget.item.icon, size: 20, color: on ? accent : p.muted),
              const SizedBox(width: 12),
              Expanded(
                child: Text(widget.item.label,
                    style: TextStyle(color: on ? p.text : p.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w500, fontSize: 14)),
              ),
              if (widget.badge != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                  decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(10)),
                  child: Text(widget.badge!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Follow Windows / light / dark, as three small icons.
class ThemeToggle extends StatelessWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (context, mode, _) => Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(10), border: Border.all(color: p.line)),
        child: Row(children: [
          for (final (m, icon, tip) in const [
            (ThemeMode.system, Icons.brightness_auto_outlined, '跟随系统'),
            (ThemeMode.light, Icons.light_mode_outlined, '亮色'),
            (ThemeMode.dark, Icons.dark_mode_outlined, '暗色'),
          ])
            Expanded(
              child: Tooltip(
                message: tip,
                child: InkWell(
                  borderRadius: BorderRadius.circular(7),
                  onTap: () => ThemeController.instance.set(m),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    height: 30,
                    decoration: BoxDecoration(
                      color: mode == m ? p.surface : Colors.transparent,
                      borderRadius: BorderRadius.circular(7),
                      boxShadow: mode == m ? const [BoxShadow(color: Color(0x22000000), blurRadius: 4, offset: Offset(0, 1))] : null,
                    ),
                    child: Icon(icon, size: 17, color: mode == m ? accent : p.muted),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
