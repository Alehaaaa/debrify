import 'package:debrify/widgets/home/raised_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget row(int? raised) => Directionality(
    textDirection: TextDirection.ltr,
    child: SizedBox(
      height: 100,
      child: RaisedRow(
        padding: EdgeInsets.zero,
        itemCount: 4,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, i) => PaintRaised(
          raised: i == raised,
          child: SizedBox(width: 100, child: Text('$i')),
        ),
      ),
    ),
  );

  /// Item ids in the order their layers composite (later = on top).
  List<int> stacking(WidgetTester tester) {
    Layer layerOf(int i) {
      final box = tester.renderObject(find.text('$i'));
      RenderObject? node = box;
      while (node != null && node is! RenderRepaintBoundary) {
        node = node.parent;
      }
      return node!.debugLayer!;
    }

    final layers = {for (var i = 0; i < 4; i++) layerOf(i): i};
    final order = <int>[];
    for (
      Layer? l = layers.keys.first.parent!.firstChild;
      l != null;
      l = l.nextSibling
    ) {
      final id = layers[l];
      if (id != null) order.add(id);
    }
    return order;
  }

  testWidgets('a raised item composites above the items after it', (
    tester,
  ) async {
    await tester.pumpWidget(row(null));
    expect(stacking(tester), [0, 1, 2, 3]);

    await tester.pumpWidget(row(1));
    // Item 1 must be on top so its lift covers item 2's edge.
    expect(stacking(tester), [0, 2, 3, 1]);

    await tester.pumpWidget(row(null));
    expect(stacking(tester), [0, 1, 2, 3]);
  });
}
