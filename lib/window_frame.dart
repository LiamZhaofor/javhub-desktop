import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';

/// Windows draws no title bar of its own (TitleBarStyle.hidden): the app's backgrounds run
/// to the top edge, and a band of [titleBarHeight] on top moves the window, maximizes on a
/// double click and holds the caption buttons. (Linux keeps GNOME's header bar.)
final bool customTitleBar = Platform.isWindows;

const titleBarHeight = 36.0;

/// The main window's frame: the band over every page (pages and pushed routes alike), and
/// [titleBarHeight] more top padding for the pages, so nothing to click sits under it.
class TitleBarFrame extends StatelessWidget {
  const TitleBarFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!customTitleBar) return child;
    final mq = MediaQuery.of(context);
    return Stack(children: [
      MediaQuery(
        data: mq.copyWith(
          padding: mq.padding.copyWith(top: mq.padding.top + titleBarHeight),
          viewPadding: mq.viewPadding.copyWith(top: mq.viewPadding.top + titleBarHeight),
        ),
        child: child,
      ),
      const Positioned(left: 0, top: 0, right: 0, height: titleBarHeight, child: TitleBar()),
    ]);
  }
}

/// A draggable band (double click: maximize / restore) with the caption buttons on the right.
class TitleBar extends StatelessWidget {
  const TitleBar({super.key, this.light = false, this.leading});

  /// White buttons (over a video) instead of the theme's.
  final bool light;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: WindowDragArea(child: leading ?? const SizedBox.expand())),
    CaptionButtons(light: light),
  ]);
}

/// Drags the window; a double click maximizes or restores it.
class WindowDragArea extends StatelessWidget {
  const WindowDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => unawaited(windowManager.startDragging()),
    onDoubleTap: () async {
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    },
    child: child,
  );
}

/// Minimize, maximize / restore, close - drawn in the app's own hand.
class CaptionButtons extends StatefulWidget {
  const CaptionButtons({super.key, this.light = false});

  final bool light;

  @override
  State<CaptionButtons> createState() => _CaptionButtonsState();
}

class _CaptionButtonsState extends State<CaptionButtons> with WindowListener {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    unawaited(windowManager.isMaximized().then((m) {
      if (mounted) setState(() => _maximized = m);
    }));
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _maximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _maximized = false);

  @override
  Widget build(BuildContext context) {
    final color = widget.light ? Colors.white : Palette.of(context).text;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _CaptionButton(glyph: _Glyph.minimize, color: color, tooltip: '最小化', onTap: () => unawaited(windowManager.minimize())),
      _CaptionButton(
        glyph: _maximized ? _Glyph.restore : _Glyph.maximize,
        color: color,
        tooltip: _maximized ? '还原' : '最大化',
        onTap: () => unawaited(_maximized ? windowManager.unmaximize() : windowManager.maximize()),
      ),
      _CaptionButton(glyph: _Glyph.close, color: color, tooltip: '关闭', danger: true, onTap: () => unawaited(windowManager.close())),
    ]);
  }
}

enum _Glyph { minimize, maximize, restore, close }

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({required this.glyph, required this.color, required this.tooltip, required this.onTap, this.danger = false});

  final _Glyph glyph;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.danger
        ? (_down ? const Color(0xFFC42B1C) : const Color(0xFFE81123))
        : widget.color.withValues(alpha: _down ? 0.16 : 0.09);
    final fg = widget.danger && _hover ? Colors.white : widget.color.withValues(alpha: _hover ? 1 : 0.78);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 46,
          height: titleBarHeight,
          color: _hover ? bg : bg.withValues(alpha: 0),
          alignment: Alignment.center,
          child: CustomPaint(size: const Size(10, 10), painter: _GlyphPainter(widget.glyph, fg)),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  _GlyphPainter(this.glyph, this.color);

  final _Glyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    switch (glyph) {
      case _Glyph.minimize:
        canvas.drawLine(Offset(0, s.height / 2), Offset(s.width, s.height / 2), p);
      case _Glyph.maximize:
        canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, const Radius.circular(1.5)), p);
      case _Glyph.restore:
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, 2.5, s.width - 2.5, s.height - 2.5), const Radius.circular(1.2)), p);
        canvas.drawPath(
          Path()
            ..moveTo(2.5, 2.5)
            ..lineTo(2.5, 0.5)
            ..arcToPoint(const Offset(3.5, 0), radius: const Radius.circular(1))
            ..lineTo(s.width - 1, 0)
            ..arcToPoint(Offset(s.width, 1), radius: const Radius.circular(1))
            ..lineTo(s.width, s.height - 3.5)
            ..arcToPoint(Offset(s.width - 1, s.height - 2.5), radius: const Radius.circular(1))
            ..lineTo(s.width - 2.5, s.height - 2.5),
          p,
        );
      case _Glyph.close:
        canvas.drawLine(Offset.zero, Offset(s.width, s.height), p);
        canvas.drawLine(Offset(s.width, 0), Offset(0, s.height), p);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter old) => old.glyph != glyph || old.color != color;
}
