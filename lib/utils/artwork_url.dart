/// Returns MetaHub's high-resolution equivalent of an artwork URL.
///
/// MetaHub catalog payloads intentionally use `small`/`medium` images for shelves,
/// where a smaller transfer and decode are the right trade-off. A full-screen
/// hero is the exception: it is enlarged to the display and needs the larger
/// source. URLs from every other provider are returned unchanged.
String? highQualityArtworkUrl(String? url) {
  if (url == null || url.isEmpty) return url;

  final uri = Uri.tryParse(url);
  if (uri?.host.toLowerCase() != 'images.metahub.space') return url;

  return url
      .replaceFirst(RegExp(r'/poster/(?:small|medium)/'), '/poster/large/')
      .replaceFirst(
        RegExp(r'/background/(?:small|medium)/'),
        '/background/large/',
      );
}
