import 'package:flutter/material.dart';

class DebrifyTvFocusState {
  final TextEditingController channelSearchController = TextEditingController();
  String channelSearchTerm = '';
  bool showSearchBar = false;
  late final FocusNode channelSearchFocusNode;
  final FocusNode quickPlayFocusNode = FocusNode(
    debugLabel: 'NextupTVQuickPlay',
  );
  final FocusNode channelSearchButtonFocusNode = FocusNode(
    debugLabel: 'NextupTVChannelSearchButton',
  );
  final FocusNode channelSearchClearFocusNode = FocusNode(
    debugLabel: 'NextupTVChannelSearchClear',
  );
  final FocusNode channelMenuFocusNode = FocusNode(
    debugLabel: 'NextupTVChannelMenu',
  );
  final MenuController channelMenuController = MenuController();
  // TV content focus handler (stored for proper unregistration)
  VoidCallback? tvContentFocusHandler;
}
