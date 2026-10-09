import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A horizontal, separated, lazily built row whose RAISED items paint above
/// their neighbours.
///
/// A plain [ListView] paints its children in order, so a card that scales up
/// on hover/focus covers the card BEFORE it but slides UNDER the card after
/// it. Flutter slivers have no z-index; this row's sliver paints every item
/// in order and then repaints the ones marked by [PaintRaised] last.
///
/// Mirrors the [ListView.separated] arguments the Spotlight shelves use.
class RaisedRow extends StatelessWidget {
  final EdgeInsetsGeometry padding;
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final IndexedWidgetBuilder separatorBuilder;
  final Clip clipBehavior;
  final Axis scrollDirection;

  const RaisedRow({
    super.key,
    required this.padding,
    required this.itemCount,
    required this.itemBuilder,
    required this.separatorBuilder,
    this.clipBehavior = Clip.hardEdge,
    this.scrollDirection = Axis.horizontal,
  });

  @override
  Widget build(BuildContext context) => CustomScrollView(
    scrollDirection: scrollDirection,
    clipBehavior: clipBehavior,
    semanticChildCount: itemCount,
    slivers: [
      SliverPadding(
        padding: padding,
        sliver: _RaisedSliverList(
          delegate: SliverChildBuilderDelegate(
            (context, index) {
              final item = index ~/ 2;
              return index.isEven
                  ? itemBuilder(context, item)
                  : separatorBuilder(context, item);
            },
            childCount: itemCount == 0 ? 0 : itemCount * 2 - 1,
            semanticIndexCallback: (_, index) =>
                index.isEven ? index ~/ 2 : null,
          ),
        ),
      ),
    ],
  );
}

/// Marks its subtree as raised while [raised] is true. Inside a [RaisedRow]
/// the whole row item containing it paints above its neighbours; anywhere
/// else it does nothing.
class PaintRaised extends SingleChildRenderObjectWidget {
  final bool raised;

  const PaintRaised({super.key, required this.raised, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintRaised(raised);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderPaintRaised).raised = raised;
}

class _RenderPaintRaised extends RenderProxyBox {
  _RenderPaintRaised(this._raised);

  bool _raised;
  _RenderRaisedSliverList? _row;

  set raised(bool value) {
    if (value == _raised) return;
    _raised = value;
    _sync();
  }

  void _sync() {
    _row?._lower(this);
    _row = null;
    if (!_raised || !attached) return;
    // Walk up to the row; the node just below it is this item's row slot.
    RenderObject node = this;
    RenderObject? parent = node.parent;
    while (parent != null && parent is! _RenderRaisedSliverList) {
      node = parent;
      parent = parent.parent;
    }
    if (parent is _RenderRaisedSliverList && node is RenderBox) {
      _row = parent.._raise(this, node);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _sync();
  }

  @override
  void detach() {
    _row?._lower(this);
    _row = null;
    super.detach();
  }
}

class _RaisedSliverList extends SliverList {
  const _RaisedSliverList({required super.delegate});

  @override
  RenderSliverList createRenderObject(BuildContext context) =>
      _RenderRaisedSliverList(
        childManager: context as SliverMultiBoxAdaptorElement,
      );
}

class _RenderRaisedSliverList extends RenderSliverList {
  _RenderRaisedSliverList({required super.childManager});

  final Map<_RenderPaintRaised, RenderBox> _raised = {};

  void _raise(_RenderPaintRaised marker, RenderBox slot) {
    _raised[marker] = slot;
    markNeedsPaint();
  }

  void _lower(_RenderPaintRaised marker) {
    if (_raised.remove(marker) != null && attached) markNeedsPaint();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final raised = {
      for (final slot in _raised.values)
        if (slot.parent == this) slot,
    };
    if (raised.isEmpty || firstChild == null) {
      super.paint(context, offset);
      return;
    }
    for (
      RenderBox? child = firstChild;
      child != null;
      child = childAfter(child)
    ) {
      if (!raised.contains(child)) _paintSlot(context, offset, child);
    }
    for (final child in raised) {
      _paintSlot(context, offset, child);
    }
  }

  void _paintSlot(PaintingContext context, Offset offset, RenderBox child) {
    final main = childMainAxisPosition(child);
    if (main >= constraints.remainingPaintExtent ||
        main + paintExtentOf(child) <= 0) {
      return;
    }
    final transform = Matrix4.identity();
    applyPaintTransform(child, transform);
    final translation = MatrixUtils.getAsTranslation(transform);
    if (translation == null) return;
    context.paintChild(child, offset + translation);
  }
}
