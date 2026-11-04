import 'package:flutter/material.dart';

import '../utils/platform_util.dart';

/// Shell tab transitions. Android TV fades in only the selected page, so an
/// outgoing Home cannot keep painting or publishing artwork behind another tab.
/// Elsewhere, the outgoing page remains opaque underneath the incoming page.
/// This avoids exposing the shell while a newly selected page is still doing
/// its first build or loading its initial content.
class AppTabSwitcher extends StatelessWidget {
  const AppTabSwitcher({
    super.key,
    required this.selectedIndex,
    required this.isTelevision,
    required this.entranceAnimation,
    required this.child,
  });

  final int selectedIndex;
  final bool isTelevision;
  final Animation<double> entranceAnimation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final androidTv = isTelevision && PlatformUtil.isAndroidTvCached;
    final switcher = AnimatedSwitcher(
      duration: Duration(milliseconds: isTelevision ? 150 : 260),
      layoutBuilder: androidTv
          ? (current, previous) => Stack(
              alignment: Alignment.center,
              // Unmount outgoing pages in this frame. Keeping Home alive for
              // the fade also keeps its hero timers and post-frame publishers
              // alive, which can overwrite a rapidly reopened Home's artwork.
              children: [if (current case final Widget current) current],
            )
          : AnimatedSwitcher.defaultLayoutBuilder,
      transitionBuilder: (child, animation) {
        // AnimatedSwitcher reverses the same animation for the previous
        // child. Letting that child fade out at the same time as the next one
        // fades in creates a momentary empty-looking shell on data-heavy tabs.
        // Keep it painted as the underlay and only animate the incoming page.
        // AnimatedSwitcher wraps our keyed subtree in an internal key, so the
        // child's key cannot identify the direction reliably. Its controller
        // does: the previous entry is always reversing.
        final incoming = animation.status != AnimationStatus.reverse;
        if (!incoming) {
          // Keep this tied to AnimatedSwitcher's reverse controller: a plain
          // child can be retired immediately because it has no animation
          // dependency. Its opacity is intentionally constant, though.
          return FadeTransition(
            opacity: Tween<double>(begin: 1, end: 1).animate(animation),
            child: child,
          );
        }
        if (isTelevision) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
            ),
            child: child,
          );
        }
        final offsetAnimation =
            Tween<Offset>(
              begin: const Offset(0.02, 0.02),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            );
        return FadeTransition(
          opacity: CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          ),
          child: SlideTransition(position: offsetAnimation, child: child),
        );
      },
      child: KeyedSubtree(key: ValueKey<int>(selectedIndex), child: child),
    );
    // The old outer fade reset ALL tab content to zero on each selection,
    // exposing the shell backdrop even beneath normally opaque pages.
    return androidTv
        ? switcher
        : FadeTransition(opacity: entranceAnimation, child: switcher);
  }
}
