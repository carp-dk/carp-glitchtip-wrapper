// Contains the CARP x DTU logo.
//
// Parts:
// - `BrandLogo`, the logo on a white plate, readable in light and dark mode.

import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// The CARP x DTU logo on a white plate, since the logo is drawn for a
/// light background.
///
/// The DTU half of the SVG is a PNG that fills a rectangle through a
/// pattern, which flutter_svg does not draw: the widget draws that PNG
/// itself, read from the same SVG, where the rectangle is.
class BrandLogo extends StatelessWidget {
  /// Creates the logo, [height] logical pixels high without the plate.
  const BrandLogo({super.key, this.height = 96});

  /// The asset of the logo, a copy of `images/carp-x-dtu-logo.svg`.
  static const asset = 'assets/images/carp-x-dtu-logo.svg';

  // the view box of the SVG, and the left edge of the rectangle with the
  // DTU logo, which reaches to its right edge
  static const _viewBox = Size(576, 243);
  static const _dtuLeft = 410.0;

  static Future<Uint8List?>? _dtu;

  /// The height of the logo.
  final double height;

  // the PNG embedded in the SVG, or null
  static Future<Uint8List?> _loadDtu(AssetBundle bundle) async {
    final svg = await bundle.loadString(asset);
    final png = RegExp(r'xlink:href="data:image/png;base64,([^"]+)"')
        .firstMatch(svg)?[1];
    return png == null ? null : base64Decode(png);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    final dtu = _dtu ??= _loadDtu(DefaultAssetBundle.of(context));
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(32),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
        child: SizedBox(
          height: height,
          width: height * _viewBox.width / _viewBox.height,
          child: Stack(
            fit: StackFit.expand,
            children: [
              SvgPicture.asset(asset, semanticsLabel: 'CARP and DTU'),
              FutureBuilder(
                future: dtu,
                builder: (context, snapshot) => switch (snapshot.data) {
                  final png? => Align(
                    // the logo is not mirrored for right-to-left languages
                    alignment: Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: (_viewBox.width - _dtuLeft) / _viewBox.width,
                      child: Image.memory(
                        png,
                        // decoded at the size it is shown, not 1951 x 2846
                        cacheHeight:
                            (height * MediaQuery.devicePixelRatioOf(context))
                                .ceil(),
                        fit: BoxFit.fill,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                  null => const SizedBox.shrink(),
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
