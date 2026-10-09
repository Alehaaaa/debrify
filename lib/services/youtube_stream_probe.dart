import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Check the actual media request method and immediately cancel the body.
/// Some CDNs reject HEAD while accepting playback GETs. Never download the
/// entire video when a CDN ignores the requested byte range.
Future<http.Response> probeYoutubeStream(
  Uri uri, {
  http.Client? client,
  Map<String, String>? headers,
}) async {
  if ((uri.scheme != 'https' && uri.scheme != 'http') || uri.host.isEmpty) {
    throw ArgumentError.value(uri, 'uri', 'Invalid playback URL');
  }
  final transport = client ?? http.Client();
  try {
    final request = http.Request('GET', uri)
      ..headers.addAll(headers ?? const {})
      ..headers['Range'] = 'bytes=0-0';
    final response = await transport
        .send(request)
        .timeout(const Duration(seconds: 2));
    await response.stream.listen((_) {}).cancel();
    return http.Response(
      '',
      response.statusCode,
      headers: response.headers,
      request: request,
    );
  } finally {
    if (client == null) transport.close();
  }
}

/// Apply the same check to the extractor's initial stream validation. Its
/// default HEAD check can otherwise discard a manifest before we select HD.
class YoutubePlaybackHttpClient extends YoutubeHttpClient {
  YoutubePlaybackHttpClient([super.client]);

  @override
  Future<http.Response> head(Uri url, {Map<String, String>? headers}) {
    if (url.host == 'googlevideo.com' ||
        url.host.endsWith('.googlevideo.com')) {
      return probeYoutubeStream(url, client: this, headers: headers);
    }
    return super.head(url, headers: headers);
  }
}
