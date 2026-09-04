import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The "nothing on the list yet" state of the shopping list.
///
/// Deliberately a little playful rather than a single grey sentence: an empty
/// basket that bobs gently, a tumbleweed that rolls through it every few
/// seconds (the joke being how very empty it is), and a caption that swaps
/// itself out while you look at it. The layout leaves room at the bottom for
/// the add-item bar and points at it, since that's the way out of this state.
class EmptyShoppingList extends StatefulWidget {
  const EmptyShoppingList({super.key});

  @override
  State<EmptyShoppingList> createState() => _EmptyShoppingListState();
}

class _EmptyShoppingListState extends State<EmptyShoppingList>
    with TickerProviderStateMixin {
  /// One slow up-and-down, driving both the basket's float and its shadow.
  late final AnimationController _bob = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2600),
  )..repeat(reverse: true);

  /// One full pass of the tumbleweed across the basket. It's only on screen
  /// for the first stretch of the cycle; the rest is the pause in between.
  late final AnimationController _roll = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 9),
  )..repeat();

  static const _captions = <String>[
    'Nothing on the list.',
    'The basket is echoing.',
    'Not even a lemon in here.',
    'Suspiciously empty.',
    'A blank slate. Or a blank fridge.',
    'Dinner is a rumour at this point.',
  ];

  /// Where in [_captions] we currently are. Starts somewhere random so the
  /// screen doesn't open with the same line every single time.
  late int _caption = math.Random().nextInt(_captions.length);
  Timer? _captionTimer;

  @override
  void initState() {
    super.initState();
    _captionTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted) return;
      setState(() => _caption = (_caption + 1) % _captions.length);
    });
  }

  @override
  void dispose() {
    _captionTimer?.cancel();
    _bob.dispose();
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return SafeArea(
      child: Padding(
        // Clear of the add-item bar sitting at the bottom of the stack.
        padding: const EdgeInsets.only(bottom: 96, left: 32, right: 32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 150,
                width: 220,
                child: AnimatedBuilder(
                  animation: Listenable.merge([_bob, _roll]),
                  builder: (context, _) {
                    final bob = Curves.easeInOut.transform(_bob.value);
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        // The tumbleweed passes behind the basket, so it looks
                        // like it's rolling through the scene rather than on
                        // top of it.
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _TumbleweedPainter(
                              progress: _roll.value,
                              color: cs.outline,
                            ),
                          ),
                        ),
                        // Shadow: tightens and darkens as the basket comes down.
                        Positioned(
                          bottom: 18,
                          child: Transform.scale(
                            scaleX: 1 - bob * 0.18,
                            child: Container(
                              width: 74,
                              height: 12,
                              decoration: BoxDecoration(
                                color: cs.outlineVariant
                                    .withValues(alpha: 0.30 + bob * 0.18),
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                          ),
                        ),
                        Transform.translate(
                          offset: Offset(0, -12 - bob * 10),
                          child: Transform.rotate(
                            angle: (bob - 0.5) * 0.06,
                            child: Icon(
                              Icons.shopping_basket_outlined,
                              size: 92,
                              color: cs.primary.withValues(alpha: 0.75),
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 450),
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.35),
                      end: Offset.zero,
                    ).animate(CurvedAnimation(
                        parent: animation, curve: Curves.easeOutCubic)),
                    child: child,
                  ),
                ),
                child: Text(
                  _captions[_caption],
                  key: ValueKey(_caption),
                  textAlign: TextAlign.center,
                  style: text.titleMedium?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Add something down there',
                    style: text.bodyMedium?.copyWith(
                      color: cs.outline,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Nudges downward, in time with the basket, to point at the
                  // add-item bar.
                  AnimatedBuilder(
                    animation: _bob,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(0, Curves.easeInOut.transform(_bob.value) * 5),
                      child: child,
                    ),
                    child: Icon(Icons.south_rounded, size: 18, color: cs.outline),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A little ball of twigs that rolls left to right across the empty basket.
///
/// [progress] is the full cycle 0..1; the weed is only drawn during the first
/// [_visibleUntil] of it, and the remainder is the beat of nothing in between.
class _TumbleweedPainter extends CustomPainter {
  _TumbleweedPainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  static const double _visibleUntil = 0.45;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress > _visibleUntil) return;
    final t = progress / _visibleUntil;

    const radius = 16.0;
    // Rolls in from just off the left edge to just off the right one, hopping
    // a little as it goes.
    final x = -radius * 2 + t * (size.width + radius * 4);
    final hop = math.sin(t * math.pi * 5).abs() * 8;
    final y = size.height - 30 - hop;
    // Fades in and out at the edges so it doesn't pop into existence.
    final fade = math.min(1.0, math.min(t, 1 - t) * 6);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = color.withValues(alpha: 0.55 * fade);

    canvas.save();
    canvas.translate(x, y);
    // A rolling ball turns in the direction it travels, at a rate set by its
    // circumference rather than an arbitrary spin speed.
    canvas.rotate((x / radius));

    // Seven spokes with a kink in each, plus a loop around them: enough to
    // read as a tangle of twigs at this size.
    for (var i = 0; i < 7; i++) {
      final a = i * (math.pi * 2 / 7);
      final mid = Offset(math.cos(a) * radius * 0.55, math.sin(a) * radius * 0.55);
      final kink = a + 0.7;
      final end = Offset(math.cos(kink) * radius, math.sin(kink) * radius);
      canvas.drawPath(Path()..moveTo(0, 0)..lineTo(mid.dx, mid.dy)..lineTo(end.dx, end.dy), paint);
    }
    canvas.drawCircle(Offset.zero, radius * 0.72, paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TumbleweedPainter old) =>
      old.progress != progress || old.color != color;
}
