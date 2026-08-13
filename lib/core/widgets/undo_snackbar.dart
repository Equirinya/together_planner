import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A bottom-anchored "…removed — Undo" prompt that mounts *inside* the page it
/// belongs to, rather than going through [ScaffoldMessenger].
///
/// Living in the page's own stack is what makes it possible to place it exactly
/// above whatever the page already keeps at its bottom edge (the add-item bar,
/// here), and to keep it alive across several dismissals so a run of swipes
/// collapses into a single prompt instead of a queue of them.
///
/// Both platforms get the same behaviour and the same motion; only the skin
/// differs — a Material 3 snackbar on Android, a translucent, blurred capsule
/// on iOS, which is what an undo affordance looks like there.
class UndoSnackbar extends StatefulWidget {
  const UndoSnackbar({
    super.key,
    required this.message,
    required this.onUndo,
    required this.onDismissed,
    this.actionLabel = 'Undo',
    this.duration = const Duration(seconds: 4),
    this.restartToken,
  });

  final String message;

  /// Invoked when the action is tapped. The prompt then animates out and
  /// reports [onDismissed] like any other exit.
  final VoidCallback onUndo;

  /// Called once the exit animation has finished — the cue for the parent to
  /// take the prompt out of its tree. Not called while the widget is simply
  /// being updated with a new [message].
  final VoidCallback onDismissed;

  final String actionLabel;

  /// How long the prompt stays up when it is left alone.
  final Duration duration;

  /// Change this to restart the auto-hide countdown without remounting — e.g.
  /// when a second item is swiped away while the prompt is still on screen.
  final Object? restartToken;

  @override
  State<UndoSnackbar> createState() => _UndoSnackbarState();
}

class _UndoSnackbarState extends State<UndoSnackbar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    reverseDuration: const Duration(milliseconds: 220),
  );

  late final Animation<Offset> _offset = Tween<Offset>(
    begin: const Offset(0, 1),
    end: Offset.zero,
  ).animate(CurvedAnimation(
    parent: _controller,
    // iOS leans on a softer settle, Android on Material's standard easing.
    curve: defaultTargetPlatform == TargetPlatform.iOS
        ? Curves.easeOutCubic
        : Curves.fastOutSlowIn,
    reverseCurve: Curves.easeInCubic,
  ));

  Timer? _hideTimer;

  /// Guards against reporting the exit twice (drag-dismiss racing the timer).
  bool _leaving = false;

  bool get _isIOS => defaultTargetPlatform == TargetPlatform.iOS;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _restartTimer();
  }

  @override
  void didUpdateWidget(UndoSnackbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.restartToken != oldWidget.restartToken ||
        widget.message != oldWidget.message) {
      _leaving = false;
      _controller.forward(); // no-op if it never started leaving
      _restartTimer();
    }
  }

  void _restartTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(widget.duration, _leave);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Animates out and hands control back to the parent.
  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    _hideTimer?.cancel();
    await _controller.reverse();
    if (mounted && _leaving) widget.onDismissed();
  }

  void _handleUndo() {
    HapticFeedback.selectionClick();
    widget.onUndo();
    _leave();
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _offset,
      child: FadeTransition(
        opacity: _controller,
        // Swiping the prompt away should get rid of it, on both platforms —
        // that is how a Material snackbar and an iOS banner both behave. It
        // only hides the prompt; it never counts as an undo.
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 120) _leave();
          },
          onHorizontalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0).abs() > 120) _leave();
          },
          child: _isIOS ? _cupertinoBody(context) : _materialBody(context),
        ),
      ),
    );
  }

  // ── Android ────────────────────────────────────────────────────────────────

  Widget _materialBody(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Material(
        color: cs.inverseSurface,
        elevation: 6,
        shadowColor: Colors.black45,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      widget.message,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: cs.onInverseSurface),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _handleUndo,
                  style: TextButton.styleFrom(
                    foregroundColor: cs.inversePrimary,
                    textStyle: theme.textTheme.labelLarge,
                  ),
                  child: Text(widget.actionLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── iOS ────────────────────────────────────────────────────────────────────

  /// A floating, blurred capsule. The colours come from the app's own
  /// [ColorScheme] rather than [CupertinoColors] so it still tracks the theme;
  /// the shape, the translucency and the button's press-fade are what make it
  /// read as native.
  Widget _cupertinoBody(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(22));

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: DecoratedBox(
        // The shadow has to sit outside the clip, or it gets clipped away.
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHigh.withValues(alpha: 0.82),
                borderRadius: radius,
                border: Border.all(
                  color: cs.outlineVariant.withValues(alpha: 0.4),
                  width: 0.5,
                ),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: Padding(
                  padding: const EdgeInsets.only(left: 18, right: 6),
                  child: Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Text(
                            widget.message,
                            style: TextStyle(
                              color: cs.onSurface,
                              fontSize: 15,
                              letterSpacing: -0.2,
                            ),
                          ),
                        ),
                      ),
                      CupertinoButton(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        onPressed: _handleUndo,
                        child: Text(
                          widget.actionLabel,
                          style: TextStyle(
                            color: cs.primary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
