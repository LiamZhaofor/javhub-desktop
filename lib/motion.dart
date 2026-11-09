import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One way of moving, everywhere: Material 3's emphasized easing for things arriving and
/// leaving, a light spring for things that settle (a selection, a press let go).
abstract final class Motion {
  /// Arriving: quick start, long gentle landing.
  static const enter = Cubic(0.05, 0.7, 0.1, 1.0);

  /// Leaving: slow start, quick exit.
  static const exit = Cubic(0.3, 0.0, 0.8, 0.15);

  /// Moving from one place to another on screen.
  static const standard = Cubic(0.2, 0.0, 0.0, 1.0);

  /// Settling with a little give (~4 % overshoot).
  static const spring = SpringCurve();

  static const fast = Duration(milliseconds: 150);
  static const medium = Duration(milliseconds: 300);
  static const slow = Duration(milliseconds: 450);
  static const settle = Duration(milliseconds: 520);
}

/// An underdamped spring as a curve: it overshoots a touch and settles by t = 1.
class SpringCurve extends Curve {
  const SpringCurve({this.damping = 0.72, this.omega = 9.0});

  /// 0-1: lower bounces more.
  final double damping;

  /// How fast it oscillates (radians per unit of t).
  final double omega;

  @override
  double transformInternal(double t) {
    final wd = omega * math.sqrt(1 - damping * damping);
    final envelope = math.exp(-damping * omega * t);
    return 1 - envelope * (math.cos(wd * t) + damping * omega / wd * math.sin(wd * t));
  }
}

/// A hero flight between two different pictures (a poster flying into a movie page that
/// shows its fanart): the frame morphs, the pictures cross-fade, the corners round off.
Widget crossFadeShuttle(BuildContext context, Animation<double> animation, HeroFlightDirection direction,
    BuildContext fromContext, BuildContext toContext) {
  final from = (fromContext.widget as Hero).child;
  final to = (toContext.widget as Hero).child;
  final a = CurvedAnimation(parent: animation, curve: Motion.standard);
  return AnimatedBuilder(
    animation: a,
    builder: (_, _) {
      // t: 0 = the tile's picture, 1 = the page's. A push runs 0 -> 1 from the tile to the
      // page; a pop runs the page route's animation 1 -> 0, from the page back to the tile.
      final t = a.value;
      final first = direction == HeroFlightDirection.push ? from : to; // the tile's
      final second = direction == HeroFlightDirection.push ? to : from; // the page's
      return ClipRRect(
        borderRadius: BorderRadius.circular(11 + 3 * t),
        child: Stack(fit: StackFit.expand, children: [
          Opacity(opacity: 1 - Curves.easeIn.transform(t), child: first),
          Opacity(opacity: Curves.easeOut.transform(t), child: second),
        ]),
      );
    },
  );
}
