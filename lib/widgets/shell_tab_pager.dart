import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The touch-layout app shell: every visible tab on one continuous horizontal
/// surface, so a swipe drags the outgoing tab out while the incoming one
/// follows it in, instead of swapping pages at the end of a gesture.
///
/// Declarative on purpose. The host owns [selectedTab]; the pager reports
/// where the user swiped to through [onTabSelected] and, when the host changes
/// [selectedTab] itself (a tab-bar tap, a deep link, a fallback after a tab
/// was hidden), slides — or for a far jump, hops next to the target and
/// slides one page — to it.
///
/// Rules this widget keeps:
///  * Pages are built only while visible. At rest exactly one tab is mounted;
///    mid-swipe, two. Offscreen neighbours would start feeds and players.
///  * A page is keyed by its tab id, never its position, so a tab keeps its
///    state when the visible list changes around it, and the same tab can
///    never be in the tree twice.
///  * Programmatic animations never "select" the tabs they cross.
///  * A changed tab list is swapped in together with the controller move,
///    after the frame, so page indices and tab ids never disagree on screen.
class ShellTabPager extends StatefulWidget {
  const ShellTabPager({
    super.key,
    required this.tabs,
    required this.selectedTab,
    required this.onTabSelected,
    required this.pageBuilder,
    this.fallbackTab,
    this.swipeEnabled = true,
    this.duration = const Duration(milliseconds: 280),
    this.curve = Curves.easeOutCubic,
  });

  /// Visible tab ids, in on-screen order. Ids may have gaps.
  final List<int> tabs;

  /// The tab the host considers active.
  final int selectedTab;

  /// The user settled on (or swiped past the midpoint of) a different tab, or
  /// [selectedTab] is no longer visible and the pager fell back.
  final ValueChanged<int> onTabSelected;

  final Widget Function(BuildContext context, int tab) pageBuilder;

  /// Where to land when [selectedTab] is not in [tabs]. Defaults to the first
  /// tab.
  final int? fallbackTab;

  /// Off while something else (a player) owns every gesture. Detail routes,
  /// sheets and dialogs cover the pager and win hit-testing on their own;
  /// inner horizontal scrollables win the gesture arena on their own.
  final bool swipeEnabled;

  final Duration duration;
  final Curve curve;

  @override
  State<ShellTabPager> createState() => ShellTabPagerState();
}

@visibleForTesting
class ShellTabPagerState extends State<ShellTabPager> {
  late PageController _controller;

  /// The list the controller's offset belongs to. Lags [ShellTabPager.tabs]
  /// by one frame when the visible tabs change.
  late List<int> _tabs;

  /// Page a programmatic animation is heading to. While set, the pages it
  /// crosses never become the tab.
  int? _target;

  /// Set around controller jumps so their synchronous scroll notifications
  /// are not mistaken for user navigation.
  bool _jumping = false;

  /// The last tab this pager reported, so the host echoing it back as
  /// [ShellTabPager.selectedTab] doesn't trigger an animation.
  int? _reported;

  bool _syncScheduled = false;

  @visibleForTesting
  List<int> get builtTabs => _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = List<int>.of(widget.tabs);
    final page = _pageFor(_tabs, widget.selectedTab);
    // Start AT the selected page: jumping after a frame would mount whatever
    // tab sat at page 0 first.
    _controller = PageController(initialPage: page, keepPage: false);
    if (_tabs.isNotEmpty && _tabs[page] != widget.selectedTab) {
      _scheduleSync();
    }
  }

  @override
  void didUpdateWidget(ShellTabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final tabsChanged = !listEquals(widget.tabs, _tabs);
    final selectionChanged =
        widget.selectedTab != oldWidget.selectedTab &&
        widget.selectedTab != _reported;
    if (tabsChanged || selectionChanged) _scheduleSync();
    if (widget.selectedTab != _reported) _reported = null;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  int _pageFor(List<int> tabs, int tab) {
    if (tabs.isEmpty) return 0;
    final page = tabs.indexOf(tab);
    if (page >= 0) return page;
    final fallback = widget.fallbackTab == null
        ? -1
        : tabs.indexOf(widget.fallbackTab!);
    return fallback >= 0 ? fallback : 0;
  }

  /// Applies list and selection changes after the frame. Moving the
  /// controller during build dispatches scroll notifications mid-build.
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) _sync();
    });
  }

  void _sync() {
    final next = widget.tabs;
    if (next.isEmpty) return;
    if (!listEquals(next, _tabs)) {
      // The visible tabs changed: rebuild with the new list and move the
      // controller to the selected tab's new position in the same frame.
      final page = _pageFor(next, widget.selectedTab);
      _target = null;
      setState(() => _tabs = List<int>.of(next));
      _moveWithoutScrolling(page);
      if (next[page] != widget.selectedTab) _report(next[page]);
      return;
    }
    final page = _tabs.indexOf(widget.selectedTab);
    if (page < 0) {
      final fallback = _pageFor(_tabs, widget.selectedTab);
      _jump(fallback);
      _report(_tabs[fallback]);
      return;
    }
    if (_currentPage == page && _target == null) return;
    animateToPage(page);
  }

  int? get _currentPage {
    if (!_controller.hasClients) return null;
    return (_controller.page ?? _controller.initialPage.toDouble()).round();
  }

  /// Slides to [page]. A far target first jumps next to it, so only the
  /// destination and one neighbour are ever built — crossing every tab in
  /// between would mount (and start loading) each of them.
  @visibleForTesting
  void animateToPage(int page) {
    if (!_controller.hasClients) return;
    final current = _currentPage ?? page;
    if (current == page) {
      _target = null;
      return;
    }
    _target = page;
    if ((page - current).abs() > 1) {
      _jump(page > current ? page - 1 : page + 1);
    }
    _controller.animateToPage(page, duration: widget.duration, curve: widget.curve);
  }

  /// Re-points the offset at [page] of the list being swapped in. Not a
  /// jump: the new page may lie past the OLD list's extent, and a jump there
  /// would start a bounce back before the new list is laid out. The rebuild
  /// already scheduled by the list swap lays the viewport out at this offset.
  void _moveWithoutScrolling(int page) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (!position.hasViewportDimension) return;
    position.correctPixels(page * position.viewportDimension);
  }

  void _jump(int page) {
    if (!_controller.hasClients) return;
    _jumping = true;
    try {
      _controller.jumpToPage(page);
    } finally {
      _jumping = false;
    }
  }

  void _report(int tab) {
    if (tab == widget.selectedTab) return;
    _reported = tab;
    widget.onTabSelected(tab);
  }

  void _onPageChanged(int page) {
    // Mid-animation pages and controller jumps are not navigation.
    if (_jumping || _target != null) return;
    if (page < 0 || page >= _tabs.length) return;
    _report(_tabs[page]);
  }

  /// Reconciles the selection with wherever the pager actually settled: a
  /// user grabbing a programmatic slide mid-flight can leave it on a page
  /// that differs from the requested tab.
  bool _onScrollEnd(ScrollEndNotification notification) {
    if (notification.depth != 0 || _jumping) return false;
    _target = null;
    final page = _currentPage;
    if (page != null && page >= 0 && page < _tabs.length) {
      _report(_tabs[page]);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs;
    if (tabs.isEmpty) return const SizedBox.shrink();
    return NotificationListener<ScrollEndNotification>(
      onNotification: _onScrollEnd,
      child: PageView.builder(
        controller: _controller,
        itemCount: tabs.length,
        // No implicit cache extent: build only what is on screen.
        allowImplicitScrolling: false,
        physics: widget.swipeEnabled
            ? const PageScrollPhysics(parent: ClampingScrollPhysics())
            : const NeverScrollableScrollPhysics(),
        onPageChanged: _onPageChanged,
        // Lets the sliver find a tab's element by id after the list changes,
        // so a tab that moved position keeps its state.
        findChildIndexCallback: (key) {
          if (key is! ValueKey<String>) return null;
          final tab = int.tryParse(key.value.substring(_keyPrefix.length));
          if (tab == null) return null;
          final page = tabs.indexOf(tab);
          return page < 0 ? null : page;
        },
        itemBuilder: (context, page) {
          final tab = tabs[page];
          return KeyedSubtree(
            key: ValueKey<String>('$_keyPrefix$tab'),
            child: widget.pageBuilder(context, tab),
          );
        },
      ),
    );
  }

  static const String _keyPrefix = 'tab-page-';
}
