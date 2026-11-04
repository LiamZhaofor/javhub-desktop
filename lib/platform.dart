import 'dart:io';

import 'package:flutter/widgets.dart';

/// Windows / macOS / Linux: mouse, keyboard, a window.
final bool isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// A phone (or a narrow window): bottom navigation, stacked layouts.
bool isCompact(BuildContext context) => MediaQuery.sizeOf(context).width < 720;

/// Side padding of a page.
double pagePad(BuildContext context) => isCompact(context) ? 14 : 28;

/// Space a scrolling page leaves at its end so the last row clears the phone's
/// floating navigation bar (the Scaffold reports the bar as bottom padding; 0 on desktop).
double bottomGap(BuildContext context, [double extra = 32]) => extra + MediaQuery.paddingOf(context).bottom;
