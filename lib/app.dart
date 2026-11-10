import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'api.dart';
import 'motion.dart';
import 'platform.dart';
import 'screens/home.dart';
import 'screens/jobs.dart';
import 'screens/library.dart';
import 'screens/search.dart';
import 'screens/settings.dart';
import 'screens/favorites.dart';
import 'theme.dart';
import 'updater.dart';
import 'window_frame.dart';

class App extends StatefulWidget {
  const App({super.key});

  static final api = JavHubApi();

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  // null: still checking the stored session
  bool? _loggedIn;

  /// The start animation has had its moment (it is not cut short by a fast session check).
  bool _introDone = false;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 750), () {
      if (mounted) setState(() => _introDone = true);
    });
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
      builder: (context, child) => TitleBarFrame(child: child ?? const SizedBox.shrink()),
      scrollBehavior: const _AppScroll(),
      // Chinese UI text, and on Android the Simplified Chinese system font (as an
      // English app the Han fallback landed on a serif)
      locale: const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
      supportedLocales: const [
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'),
        Locale('en'),
      ],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      themeAnimationDuration: const Duration(milliseconds: 200),
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 520),
        switchInCurve: Motion.standard,
        switchOutCurve: Motion.exit,
        // the logo grows away and fades; the app comes in from a touch smaller
        transitionBuilder: (child, a) {
          final leaving = child.key == const ValueKey('intro');
          return FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: leaving ? 1.12 : 0.94, end: 1.0).animate(a), child: child),
          );
        },
        child: _loggedIn == null || !_introDone
            ? const _Intro(key: ValueKey('intro'))
            : _loggedIn == false
            ? LoginPage(key: const ValueKey('login'), onDone: () => setState(() => _loggedIn = true))
            : Shell(key: const ValueKey('shell'), onLogout: () => setState(() => _loggedIn = false)),
      ),
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
      body: Stack(
        children: [
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
                        Text(
                          'JavHub',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: p.text),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '登录你的片库',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: p.muted),
                        ),
                        const SizedBox(height: 26),
                        TextField(
                          controller: _server,
                          decoration: const InputDecoration(labelText: '服务器地址', prefixIcon: Icon(Icons.dns_outlined, size: 18)),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _user,
                          decoration: const InputDecoration(labelText: '用户名', prefixIcon: Icon(Icons.person_outline, size: 18)),
                          autofillHints: const [AutofillHints.username],
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _password,
                          obscureText: true,
                          decoration: const InputDecoration(labelText: '密码', prefixIcon: Icon(Icons.lock_outline, size: 18)),
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _busy ? null : _login(),
                        ),
                        if (_error != null) ...[const SizedBox(height: 12), Text(_error!, style: const TextStyle(color: accent))],
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
        ],
      ),
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
  static void search(BuildContext context, String code) => (context.findAncestorStateOfType<_ShellState>() ?? _ShellState._current)?._openSearch(code);

  /// Switches to the library, filtered by an actress / studio / tag.
  static void filterLibrary(BuildContext context, String query) =>
      (context.findAncestorStateOfType<_ShellState>() ?? _ShellState._current)?._openLibrary(query);

  /// 收藏's badge: how many of the followed actresses' new movies are unseen.
  static void setNewReleases(int n) => _ShellState.setNewReleases(n);

  /// The library and the home page fetch the list again (a movie was fixed / removed).
  static void refresh() {
    final s = _ShellState._current;
    unawaited(s?._libraryKey.currentState?.load());
    unawaited(s?._homeKey.currentState?.reload());
  }

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
  _NavItem(Icons.favorite_border_rounded, Icons.favorite_rounded, '收藏'),
  _NavItem(Icons.tune_outlined, Icons.tune_rounded, '设置'),
];

class _ShellState extends State<Shell> {
  int _tab = 0;
  final _searchKey = GlobalKey<SearchPageState>();
  final _libraryKey = GlobalKey<LibraryPageState>();
  final _homeKey = GlobalKey<HomePageState>();
  final _favKey = GlobalKey<FavoritesPageState>();
  int _activeJobs = 0;
  Timer? _jobsTimer;
  int _newReleases = 0;
  Timer? _releasesTimer;

  /// 收藏's badge: the followed actresses' new movies not seen yet.
  static void setNewReleases(int n) {
    final s = _current;
    if (s != null && s.mounted && s._newReleases != n) s.setState(() => s._newReleases = n);
  }

  Future<void> _pollReleases() async {
    try {
      setNewReleases((await App.api.releases()).unread);
    } catch (_) {}
  }

  /// The shell on screen: pages pushed over it (a movie, an actress) are not below it.
  static _ShellState? _current;

  @override
  void initState() {
    super.initState();
    _current = this;
    unawaited(_pollJobs());
    unawaited(_pollReleases());
    _releasesTimer = Timer.periodic(const Duration(minutes: 30), (_) => unawaited(_pollReleases()));
    // a newer build on JavHub? asked once a start, a little after it
    Future<void>.delayed(const Duration(seconds: 4), () {
      if (mounted) unawaited(checkForUpdate(context));
    });
  }

  @override
  void dispose() {
    if (_current == this) _current = null;
    _jobsTimer?.cancel();
    _releasesTimer?.cancel();
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

  // Made once: switching tabs (or a badge changing) rebuilds the shell, and new page widgets
  // there would build all six pages again - a 15-50 ms frame on a phone, as a tab is chosen.
  late final List<Widget> _pages = [
    HomePage(key: _homeKey),
    LibraryPage(key: _libraryKey),
    SearchPage(key: _searchKey, onJobCreated: _pollJobs),
    const JobsPage(),
    FavoritesPage(key: _favKey),
    SettingsPage(onLogout: widget.onLogout),
  ];

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final pages = _pages;
    if (isCompact(context)) {
      return Scaffold(
        // pages scroll on under the bar, which floats over them as frosted glass
        extendBody: true,
        body: FadeIndexedStack(index: _tab, children: pages),
        bottomNavigationBar: _GlassNavBar(
          selected: _tab,
          badges: {if (_activeJobs > 0) 3: '$_activeJobs', if (_newReleases > 0) 4: '$_newReleases'},
          onSelect: (i) {
            if (i == _tab) {
              // the open tab tapped again: back to the top
              if (i == 1) _libraryKey.currentState?.scrollToTop();
              return;
            }
            unawaited(HapticFeedback.selectionClick());
            if (i == 0) unawaited(_homeKey.currentState?.reload());
            if (i == 4) unawaited(_favKey.currentState?.reload());
            setState(() => _tab = i);
          },
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
              decoration: BoxDecoration(
                color: p.sidebar,
                border: Border(right: BorderSide(color: p.line)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 22, 16, 22),
                    child: Row(
                      children: [
                        const Logo(size: 30),
                        const SizedBox(width: 10),
                        Text(
                          'JavHub',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: p.text),
                        ),
                      ],
                    ),
                  ),
                  for (var i = 0; i < _nav.length; i++)
                    _SideButton(
                      item: _nav[i],
                      selected: _tab == i,
                      badge: i == 3 && _activeJobs > 0 ? '$_activeJobs' : (i == 4 && _newReleases > 0 ? '$_newReleases' : null),
                      onTap: () {
                        // back to 首页: show what was just watched
                        if (i == 0 && _tab != 0) unawaited(_homeKey.currentState?.reload());
                        if (i == 4 && _tab != 4) unawaited(_favKey.currentState?.reload());
                        setState(() => _tab = i);
                      },
                    ),
                  const Spacer(),
                  const Padding(padding: EdgeInsets.fromLTRB(12, 0, 12, 14), child: ThemeToggle()),
                ],
              ),
            ),
            Expanded(
              child: FadeIndexedStack(index: _tab, children: pages),
            ),
          ],
        ),
      ),
    );
  }
}

/// The phone's navigation, in liquid glass: a rounded bar of frosted glass floating above
/// the page, with a glass lens on the chosen tab.
///  - tap a tab: the lens flows over to it, bulging a little on the way;
///  - press and slide along the bar: the lens lifts off it and swells into clear glass that
///    magnifies the icon under it, follows the finger (stretching with the speed, a tick at
///    each tab), and drops onto the tab it is let go over. Pulled past either end, it and the
///    bar give like rubber.
class _GlassNavBar extends StatefulWidget {
  const _GlassNavBar({required this.selected, required this.onSelect, this.badges = const {}});

  final int selected;
  final ValueChanged<int> onSelect;
  final Map<int, String> badges;

  @override
  State<_GlassNavBar> createState() => _GlassNavBarState();
}

class _GlassNavBarState extends State<_GlassNavBar> with TickerProviderStateMixin {
  static const _radius = 28.0;
  static const _height = 66.0;
  static const _inset = 5.0;

  // the lens to its tab, a little bounce at the end
  static final _flow = SpringDescription.withDampingRatio(mass: 1, stiffness: 300, ratio: 0.7);
  // the lens after the finger: close behind, a touch of lag (that is where its stretch comes from)
  static final _chase = SpringDescription.withDampingRatio(mass: 1, stiffness: 1600, ratio: 0.9);
  // lifting off and settling back
  static final _swell = SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.6);

  /// The lens centre in tabs (0 = the first); fractional while it moves.
  late final AnimationController _pos = AnimationController.unbounded(vsync: this, value: widget.selected.toDouble());

  /// 0 resting on the bar, 1 lifted off it under a finger.
  late final AnimationController _lift = AnimationController.unbounded(vsync: this);

  int _target = 0;
  bool _dragging = false;
  int _hover = 0;
  double _tabW = 1;

  // Under a finger the lens is moved once a frame, toward where the finger is ([_goal]), by
  // [_chase]. (Not a new animation for every touch event: a phone sends those faster than it
  // draws, and an animation started anew each time never gets past its first frame.)
  late final Ticker _follower = createTicker(_tick);
  Duration _lastTick = Duration.zero;
  double _goal = 0;
  double _vel = 0; // the lens, tabs a second

  int get _n => _nav.length;

  @override
  void initState() {
    super.initState();
    _target = widget.selected;
  }

  @override
  void didUpdateWidget(_GlassNavBar old) {
    super.didUpdateWidget(old);
    // (switched from elsewhere, or by a tap: flow over, unless it is on its way there already)
    if (!_dragging && widget.selected != _target) _flowTo(widget.selected, bulge: true);
  }

  @override
  void dispose() {
    _follower.dispose();
    _pos.dispose();
    _lift.dispose();
    super.dispose();
  }

  void _flowTo(int i, {double? velocity, bool bulge = false}) {
    _target = i;
    unawaited(_pos.animateWith(SpringSimulation(_flow, _pos.value, i.toDouble(), velocity ?? _pos.velocity)));
    _liftTo(0, velocity: bulge ? 4.5 : null);
  }

  void _liftTo(double to, {double? velocity}) =>
      unawaited(_lift.animateWith(SpringSimulation(_swell, _lift.value, to, velocity ?? _lift.velocity)));

  /// The finger x as a lens position; past either end it is held back like rubber.
  double _tabAt(double dx) {
    final t = dx / _tabW - 0.5;
    final last = _n - 1.0;
    double rubber(double over) => 0.55 * (1 - 1 / (over + 1));
    if (t < 0) return -rubber(-t);
    if (t > last) return last + rubber(t - last);
    return t;
  }

  // --dart-define=JAVHUB_FRAMES=true: a drag logs its touch events, frames and ticks (adb logcat -s flutter)
  static const _trace = bool.fromEnvironment('JAVHUB_FRAMES');
  final _clock = Stopwatch()..start();
  final _log = <String>[];

  void _follow(double dx) {
    _goal = _tabAt(dx);
    if (_trace) _log.add('e ${_clock.elapsedMilliseconds} ${_goal.toStringAsFixed(2)}');
    final h = _goal.round().clamp(0, _n - 1);
    if (h != _hover) {
      _hover = h;
      if (_trace) {
        final t0 = _clock.elapsedMilliseconds;
        _log.add('h $t0');
        unawaited(HapticFeedback.selectionClick().then((_) => _log.add('hd $t0 ${_clock.elapsedMilliseconds - t0}')));
      } else {
        unawaited(HapticFeedback.selectionClick());
      }
    }
  }

  void _tick(Duration now) {
    final dt = ((now - _lastTick).inMicroseconds / 1e6).clamp(0.0, 1 / 30);
    _lastTick = now;
    if (dt <= 0) return;
    // one frame of the spring, from where the lens is and how fast it goes
    final s = SpringSimulation(_chase, _pos.value, _goal, _vel);
    _vel = s.dx(dt);
    _pos.value = s.x(dt);
    if (_trace) _log.add('f ${_clock.elapsedMilliseconds} ${_pos.value.toStringAsFixed(2)}');
  }

  // a finger on the bar: the lens swells a little (a tap carries on to the tab, a slide lifts it)
  void _down(DragDownDetails d) => _liftTo(0.35);

  void _cancel() {
    if (!_dragging) _liftTo(0);
  }

  void _start(DragStartDetails d) {
    // ignore: avoid_print
    if (_trace) print('mark start ${Timeline.now ~/ 1000}');
    _dragging = true;
    _vel = _pos.velocity; // (it may be flowing still)
    _pos.stop();
    _hover = _pos.value.round().clamp(0, _n - 1);
    _liftTo(1);
    _follow(d.localPosition.dx - _inset);
    _lastTick = Duration.zero;
    if (!_follower.isActive) unawaited(_follower.start());
  }

  void _end(DragEndDetails d) {
    // ignore: avoid_print
    if (_trace) print('mark end ${Timeline.now ~/ 1000}');
    _dragging = false;
    _follower.stop();
    // the tab under the finger (not under the lens, a little behind it); a flick carries on a bit
    final flick = d.velocity.pixelsPerSecond.dx / _tabW;
    final to = (_goal + flick * 0.05).round().clamp(0, _n - 1);
    _flowTo(to, velocity: _vel);
    if (to != widget.selected) widget.onSelect(to);
    if (_trace) {
      final all = _log.join(';');
      _log.clear();
      for (var i = 0; i < all.length; i += 900) {
        // ignore: avoid_print
        print('drag ${all.substring(i, (i + 900).clamp(0, all.length))}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final radius = BorderRadius.circular(_radius);
    final bar = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: dark ? 0.45 : 0.16), blurRadius: 30, offset: const Offset(0, 12)),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              // a see-through tint, lit a little more along the top, with a bright rim
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? [
                        Color.alphaBlend(Colors.white.withValues(alpha: 0.10), p.raised).withValues(alpha: 0.62),
                        p.raised.withValues(alpha: 0.48),
                      ]
                    : [Colors.white.withValues(alpha: 0.82), Colors.white.withValues(alpha: 0.58)],
              ),
              border: Border.all(color: Colors.white.withValues(alpha: dark ? 0.14 : 0.75)),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(14, 0, 14, 10 + MediaQuery.paddingOf(context).bottom),
      child: SizedBox(
        height: _height,
        child: LayoutBuilder(
          builder: (context, c) {
            _tabW = (c.maxWidth - 2 * _inset) / _n;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragDown: _down,
              onHorizontalDragCancel: _cancel,
              onHorizontalDragStart: _start,
              onHorizontalDragUpdate: (d) => _follow(d.localPosition.dx - _inset),
              onHorizontalDragEnd: _end,
              child: AnimatedBuilder(
                animation: Listenable.merge([_pos, _lift]),
                child: bar,
                builder: (context, bar) {
                  final pos = _pos.value;
                  final lift = _lift.value.clamp(-0.3, 1.4);
                  final speed = (_dragging ? _vel : _pos.velocity).abs(); // tabs a second
                  // pulled past an end: the bar gives a little that way
                  final over = pos < 0 ? pos : (pos > _n - 1 ? pos - (_n - 1) : 0.0);
                  // the lens: lifted it swells past the bar edges; moving fast it stretches
                  final stretch = (speed * 0.035).clamp(0.0, 0.32);
                  final lw = _tabW * (1 + 0.2 * lift) * (1 + stretch);
                  final lh = (_height - 2 * _inset + 18 * lift) * (1 - 0.3 * stretch);
                  final cx = _inset + (pos + 0.5) * _tabW;
                  return Transform(
                    alignment: over < 0 ? Alignment.centerRight : Alignment.centerLeft,
                    transform: Matrix4.diagonal3Values(1 + over.abs() * 0.06, 1 - over.abs() * 0.04, 1),
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // (its own layer: the lens moving over it does not paint it again)
                        Positioned.fill(child: RepaintBoundary(child: bar!)),
                        Positioned(
                          left: cx - lw / 2,
                          top: _height / 2 - lh / 2,
                          width: lw,
                          height: lh,
                          child: IgnorePointer(
                            child: CustomPaint(painter: _LensPainter(lift: lift.clamp(0.0, 1.0), dark: dark)),
                          ),
                        ),
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.all(_inset),
                            child: Row(
                              children: [
                                for (var i = 0; i < _n; i++)
                                  Expanded(
                                    child: _GlassNavItem(
                                      item: _nav[i],
                                      selected: i == widget.selected,
                                      // how much of the lens is over this tab
                                      near: (1 - (pos - i).abs()).clamp(0.0, 1.0),
                                      lift: lift.clamp(0.0, 1.0),
                                      badge: widget.badges[i],
                                      onTap: () => widget.onSelect(i),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }
}

/// The lens: resting, a pill of accent-tinted glass; lifted, clear glass with a bright rim
/// catching the light top left and bottom right, a soft highlight and a shadow under it.
class _LensPainter extends CustomPainter {
  const _LensPainter({required this.lift, required this.dark});

  final double lift;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final r = RRect.fromRectAndRadius(rect, Radius.circular(size.height / 2));
    final rest = 1 - lift;
    // the shadow it casts once lifted (a soft gradient, not a blur: drawn every frame of a drag)
    if (lift > 0.01) {
      final shadow = Rect.fromCenter(
        center: Offset(size.width / 2, size.height / 2 + 6 * lift),
        width: size.width + 26 * lift,
        height: size.height + 26 * lift,
      );
      final a = (dark ? 0.42 : 0.2) * lift;
      canvas.save();
      canvas.translate(shadow.center.dx, shadow.center.dy);
      canvas.scale(1, shadow.height / shadow.width);
      canvas.drawCircle(
        Offset.zero,
        shadow.width / 2,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.black.withValues(alpha: a), Colors.black.withValues(alpha: a * 0.55), Colors.black.withValues(alpha: 0)],
            stops: const [0, 0.72, 1],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: shadow.width / 2)),
      );
      canvas.restore();
    }
    // the glass: the accent tint resting, clear (a little white) lifted
    final top = Color.lerp(
      Colors.white.withValues(alpha: dark ? 0.14 : 0.42),
      accent.withValues(alpha: dark ? 0.30 : 0.16),
      rest,
    )!;
    final bottom = Color.lerp(
      Colors.white.withValues(alpha: dark ? 0.05 : 0.16),
      accent.withValues(alpha: dark ? 0.16 : 0.08),
      rest,
    )!;
    canvas.drawRRect(
      r,
      Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [top, bottom]).createShader(rect),
    );
    if (lift > 0.01) {
      // a soft highlight across its top
      final hl = Rect.fromLTWH(size.width * 0.12, size.height * 0.06, size.width * 0.76, size.height * 0.42);
      canvas.drawOval(
        hl,
        Paint()
          ..shader = RadialGradient(
            colors: [Colors.white.withValues(alpha: (dark ? 0.16 : 0.38) * lift), Colors.white.withValues(alpha: 0)],
          ).createShader(hl),
      );
      // the glass thickness: light gathering just inside the edge (two faint lines, not a blur)
      final glow = (dark ? 0.07 : 0.2) * lift;
      canvas.drawRRect(
        r.deflate(2),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white.withValues(alpha: glow),
      );
      canvas.drawRRect(
        r.deflate(3.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white.withValues(alpha: glow * 0.45),
      );
    }
    // the rim: even resting; lifted it catches the light at two corners
    final rimBright = Colors.white.withValues(alpha: dark ? 0.16 + 0.42 * lift : 0.9);
    final rimDim = Colors.white.withValues(alpha: dark ? 0.16 * rest + 0.06 * lift : 0.9 * rest + 0.35 * lift);
    canvas.drawRRect(
      r.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1 + 0.4 * lift
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [rimBright, rimDim, rimDim, rimBright],
          stops: const [0, 0.35, 0.65, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_LensPainter old) => old.lift != lift || old.dark != dark;
}

class _GlassNavItem extends StatelessWidget {
  const _GlassNavItem({
    required this.item,
    required this.selected,
    required this.near,
    required this.lift,
    required this.onTap,
    this.badge,
  });

  final _NavItem item;
  final bool selected;

  /// 0..1: how much of the lens is over this tab (its colour and size follow the lens).
  final double near;

  /// 0..1: the lens lifted off the bar - the icon under it is magnified.
  final double lift;
  final VoidCallback onTap;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = Color.lerp(p.muted, accent, near)!;
    final on = near > 0.5;
    return Semantics(
      button: true,
      selected: selected,
      label: item.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Transform.scale(
              scale: 1 + near * (0.14 + 0.22 * lift),
              child: Badge(
                isLabelVisible: badge != null,
                label: Text(badge ?? ''),
                child: Icon(on ? item.selected : item.icon, color: color, size: 23),
              ),
            ),
            const SizedBox(height: 3),
            Transform.scale(
              scale: 1 + near * 0.08 * lift,
              child: Text(
                item.short,
                maxLines: 1,
                style: TextStyle(fontSize: 11, height: 1.1, color: color, fontWeight: on ? FontWeight.w800 : FontWeight.w500),
              ),
            ),
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
            child: Row(
              children: [
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
                  child: Text(
                    widget.item.label,
                    style: TextStyle(color: on ? p.text : p.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w500, fontSize: 14),
                  ),
                ),
                if (widget.badge != null)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(10)),
                    child: Text(
                      widget.badge!,
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700),
                    ),
                  ),
              ],
            ),
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
        decoration: BoxDecoration(
          color: p.raised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: p.line),
        ),
        child: Row(
          children: [
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
          ],
        ),
      ),
    );
  }
}

/// An IndexedStack (every page keeps its state and scroll) whose page fades and rises in
/// when the tab changes.
class FadeIndexedStack extends StatefulWidget {
  const FadeIndexedStack({super.key, required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack> with SingleTickerProviderStateMixin {
  // (the standard curve over 360 ms: the emphasized one is three-quarters done in 80 ms,
  // which reads as a jump on a whole page)
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 360), value: 1);
  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: Motion.standard);

  @override
  void didUpdateWidget(FadeIndexedStack old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Palette.of(context).bg;
    // The page fades in over the app's background. Done as that background laid over the page
    // and fading away - the same picture, but not the whole page (posters and all) drawn into
    // a layer of its own every frame; and not zoomed either (every poster drawn again, blurred
    // backdrops and all, each frame): both made a switch stutter.
    return AnimatedBuilder(
      animation: _a,
      builder: (_, child) {
        final t = _a.value;
        return Stack(
          fit: StackFit.expand,
          children: [
            child!,
            IgnorePointer(child: t < 1 ? ColoredBox(color: bg.withValues(alpha: 1 - t)) : const SizedBox.shrink()),
          ],
        );
      },
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}

/// The phone's lists bounce at their ends (as ColorOS / iOS lists do) instead of stretching.
class _AppScroll extends MaterialScrollBehavior {
  const _AppScroll();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => isDesktop
      ? super.getScrollPhysics(context)
      : const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
}

/// The first frames: the icon the system's splash showed, settling in with a spring, a soft
/// glow breathing behind it, the name rising under it.
class _Intro extends StatefulWidget {
  const _Intro({super.key});

  @override
  State<_Intro> createState() => _IntroState();
}

class _IntroState extends State<_Intro> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = _c.value;
            // (the system's splash before this is only the background: the logo fades in, then springs)
            final show = Curves.easeOut.transform((t / 0.22).clamp(0.0, 1.0));
            final pop = Motion.spring.transform((t / 0.7).clamp(0.0, 1.0));
            final rise = Motion.standard.transform(((t - 0.25) / 0.75).clamp(0.0, 1.0));
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Stack(alignment: Alignment.center, children: [
                // the glow
                Container(
                  width: 150,
                  height: 150,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [accent.withValues(alpha: 0.28 * rise), accent.withValues(alpha: 0)]),
                  ),
                ),
                Opacity(
                  opacity: show,
                  child: Transform.scale(scale: 0.72 + 0.28 * pop, child: const Logo(size: 84)),
                ),
              ]),
              const SizedBox(height: 6),
              Opacity(
                opacity: rise,
                child: Transform.translate(
                  offset: Offset(0, 14 * (1 - rise)),
                  child: Text('JavHub', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: p.text, letterSpacing: 0.4)),
                ),
              ),
            ]);
          },
        ),
      ),
    );
  }
}
