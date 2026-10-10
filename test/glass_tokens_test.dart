import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:debrify/screens/video_player/widgets/liquid_glass.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('compiled glass defaults match assets/design/glass_tokens.json', () {
    // The defaults paint the first frame before the asset loads; if they
    // drift from the JSON the glass visibly changes a moment after opening.
    final json =
        jsonDecode(File(GlassTokens.asset).readAsStringSync())
            as Map<String, dynamic>;
    expect(
      GlassTokens.fromJson(json).signature,
      GlassTokens.defaults.signature,
    );
  });

  test('dynamic glass thickens over bright frames', () {
    const t = GlassTokens.defaults;
    final dark = t.look(GlassVariant.dynamic, 0.05);
    final bright = t.look(GlassVariant.dynamic, 0.95);
    expect(dark.blur, t.dynamicDim.blur);
    expect(bright.blur, t.dynamicBright.blur);
    expect(bright.shade.a, greaterThan(dark.shade.a));
    expect(bright.saturation, lessThan(dark.saturation));
  });

  test('frosted is high blur, translucent is low blur with a strong base', () {
    const t = GlassTokens.defaults;
    expect(t.frosted.blur, greaterThan(t.translucent.blur));
    expect(t.translucent.shade.a, greaterThan(t.frosted.shade.a));
  });

  test('luma sampling reads black and white frames', () async {
    Future<double?> lumaOfSolid(Color c) async {
      final recorder = PictureRecorder();
      Canvas(recorder).drawColor(c, BlendMode.src);
      final image = await recorder.endRecording().toImage(8, 8);
      final png = await image.toByteData(format: ImageByteFormat.png);
      image.dispose();
      return GlassBrightnessProbe.lumaOf(png!.buffer.asUint8List());
    }

    expect(await lumaOfSolid(const Color(0xFF000000)), closeTo(0, 0.01));
    expect(await lumaOfSolid(const Color(0xFFFFFFFF)), closeTo(1, 0.01));
  });
}
