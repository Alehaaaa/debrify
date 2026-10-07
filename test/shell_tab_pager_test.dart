import 'package:debrify/widgets/shell_tab_pager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records which tab pages are mounted and how often each was created.
class _Probe {
  final Set<int> mounted = <int>{};
  final Map<int, int> created = <int, int>{};
  final Map<int, GlobalKey> keys = <int, GlobalKey>{};

  GlobalKey keyFor(int tab) => keys.putIfAbsent(tab, () => GlobalKey());
}

class _TabPage extends StatefulWidget {
  const _TabPage({super.key, required this.tab, required this.probe});

  final int tab;
  final _Probe probe;

  @override
  State<_TabPage> createState() => _TabPageState();
}

class _TabPageState extends State<_TabPage> {
  int taps = 0;

  @override
  void initState() {
    super.initState();
    widget.probe.mounted.add(widget.tab);
    widget.probe.created.update(widget.tab, (n) => n + 1, ifAbsent: () => 1);
  }

  @override
  void dispose() {
    widget.probe.mounted.remove(widget.tab);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => taps++),
      child: ColoredBox(
        color: Colors.primaries[widget.tab % Colors.primaries.length],
        // A singleton-style subtree: one GlobalKey per tab. Two copies of a
        // tab in the tree at once would throw "Duplicate GlobalKey".
        child: Center(
          key: widget.probe.keyFor(widget.tab),
          child: Text('tab ${widget.tab} taps $taps'),
        ),
      ),
    );
  }
}

class _Host extends StatefulWidget {
  const _Host({
    super.key,
    required this.probe,
    required this.initialTabs,
    required this.initialSelected,
  });

  final _Probe probe;
  final List<int> initialTabs;
  final int initialSelected;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late List<int> tabs = widget.initialTabs;
  late int selected = widget.initialSelected;
  bool swipeEnabled = true;
  final List<int> reports = <int>[];

  void select(int tab) => setState(() => selected = tab);
  void setTabs(List<int> next) => setState(() => tabs = next);
  void setSwipe(bool enabled) => setState(() => swipeEnabled = enabled);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ShellTabPager(
        tabs: tabs,
        selectedTab: selected,
        fallbackTab: 15,
        swipeEnabled: swipeEnabled,
        onTabSelected: (tab) {
          reports.add(tab);
          setState(() => selected = tab);
        },
        pageBuilder: (context, tab) =>
            _TabPage(key: ValueKey('page-$tab'), tab: tab, probe: widget.probe),
      ),
    );
  }
}

// Ids with gaps, as the app's tab ids have.
const _tabs = <int>[15, 16, 2, 8, 19];

Future<_HostState> _pump(
  WidgetTester tester,
  _Probe probe, {
  List<int> tabs = _tabs,
  int selected = 15,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final key = GlobalKey<_HostState>();
  await tester.pumpWidget(
    _Host(key: key, probe: probe, initialTabs: tabs, initialSelected: selected),
  );
  await tester.pumpAndSettle();
  return key.currentState!;
}

void main() {
  testWidgets('starts on the selected tab without mounting others', (
    tester,
  ) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 8);
    expect(find.text('tab 8 taps 0'), findsOneWidget);
    expect(probe.mounted, {8});
    expect(probe.created.keys, [8], reason: 'no wrong tab for a frame');
    expect(host.reports, isEmpty);
  });

  testWidgets('swiping left and right follows the finger and selects', (
    tester,
  ) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 16);

    // Mid-drag both pages are on screen at once.
    final gesture = await tester.startGesture(const Offset(300, 400));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(probe.mounted, {16, 2});
    expect(tester.getTopLeft(find.text('tab 2 taps 0')).dx, lessThan(400));
    for (var i = 0; i < 4; i++) {
      await gesture.moveBy(const Offset(-30, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    expect(host.selected, 2);
    expect(host.reports, [2]);
    expect(probe.mounted, {2}, reason: 'outgoing tab released at rest');

    await tester.fling(find.text('tab 2 taps 0'), const Offset(300, 0), 1000);
    await tester.pumpAndSettle();
    expect(host.selected, 16);
    expect(host.reports, [2, 16]);
  });

  testWidgets('a cancelled swipe stays on the current tab', (tester) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 16);
    await tester.drag(find.text('tab 16 taps 0'), const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(host.selected, 16);
    expect(host.reports, isEmpty);
    expect(probe.mounted, {16});
  });

  testWidgets('tab-bar selection slides there without selecting crossed tabs',
      (tester) async {
    final probe = _Probe();
    final host = await _pump(tester, probe);

    host.select(19); // far jump: 15 → 19 crosses 16, 2, 8
    await tester.pump(); // post-frame: hop beside the target, start slide
    await tester.pump(); // first animation tick
    await tester.pump(const Duration(milliseconds: 140));
    // Only the destination and one neighbour are ever built.
    expect(probe.created.keys.toSet(), {15, 8, 19});
    await tester.pumpAndSettle();

    expect(find.text('tab 19 taps 0'), findsOneWidget);
    expect(host.selected, 19);
    expect(host.reports, isEmpty, reason: 'no intermediate tab selected');
    expect(probe.mounted, {19});

    host.select(8); // adjacent
    await tester.pumpAndSettle();
    expect(find.text('tab 8 taps 0'), findsOneWidget);
    expect(host.reports, isEmpty);
  });

  testWidgets('grabbing a tab-bar slide mid-flight reconciles on settle', (
    tester,
  ) async {
    final probe = _Probe();
    final host = await _pump(tester, probe);
    host.select(16);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    // Pull it back to where it came from.
    await tester.fling(
      find.byType(PageView),
      const Offset(400, 0),
      2000,
      warnIfMissed: false,
    );
    await tester.pumpAndSettle();
    final shown = probe.mounted.single;
    expect(host.selected, shown, reason: 'selection matches the settled page');
  });

  testWidgets('settings/auth changes remap the current tab by id', (
    tester,
  ) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 8);
    await tester.tap(find.text('tab 8 taps 0'));
    await tester.pump();
    expect(find.text('tab 8 taps 1'), findsOneWidget);

    // Tabs inserted before the current one push it past the old list's end.
    host.setTabs(const [15, 3, 4, 5, 6, 16, 2, 8, 19]);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('tab 8 taps 1'), findsOneWidget, reason: 'state kept');
    expect(probe.created[8], 1, reason: 'not rebuilt from scratch');
    expect(probe.mounted, {8});
    expect(host.reports, isEmpty);
    for (final tab in const [3, 4, 5, 6]) {
      expect(probe.created[tab], isNull, reason: 'tab $tab never mounted');
    }

    // Tabs removed before it.
    host.setTabs(const [8, 19]);
    await tester.pumpAndSettle();
    expect(find.text('tab 8 taps 1'), findsOneWidget);
    expect(probe.created[8], 1);

    // Swiping still works on the new list.
    await tester.fling(find.text('tab 8 taps 1'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(host.selected, 19);
  });

  testWidgets('a hidden current tab falls back to Home', (tester) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 2);
    host.setTabs(const [15, 16, 8, 19]);
    await tester.pumpAndSettle();
    expect(host.selected, 15);
    expect(host.reports, [15]);
    expect(probe.mounted, {15});
  });

  testWidgets('disabled swipes ignore horizontal drags', (tester) async {
    final probe = _Probe();
    final host = await _pump(tester, probe, selected: 16);
    host.setSwipe(false);
    await tester.pump();
    await tester.fling(find.text('tab 16 taps 0'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(host.selected, 16);
    // Programmatic selection still works.
    host.select(2);
    await tester.pumpAndSettle();
    expect(find.text('tab 2 taps 0'), findsOneWidget);
  });

  testWidgets('inner horizontal scrollables win over the tab swipe', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var selected = 15;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => ShellTabPager(
            tabs: const [15, 16],
            selectedTab: selected,
            onTabSelected: (tab) => setState(() => selected = tab),
            pageBuilder: (context, tab) => Column(
              children: [
                SizedBox(
                  height: 120,
                  child: ListView(
                    key: ValueKey('row-$tab'),
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (var i = 0; i < 20; i++)
                        SizedBox(width: 100, child: Text('card $i')),
                    ],
                  ),
                ),
                Expanded(child: Text('body $tab')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('row-15')), const Offset(-250, 0));
    await tester.pumpAndSettle();
    expect(selected, 15, reason: 'the card row scrolled, not the tabs');
    await tester.fling(find.text('body 15'), const Offset(-300, 0), 1000);
    await tester.pumpAndSettle();
    expect(selected, 16);
  });
}
