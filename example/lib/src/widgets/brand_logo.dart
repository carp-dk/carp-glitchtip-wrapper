// Contains the CARP x DTU logo.
//
// Parts:
// - `BrandLogo`, the logo on a white plate, readable in light and dark mode.

import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// The CARP x DTU logo on a white plate, since the logo is drawn for a
/// light background.
class BrandLogo extends StatelessWidget {
  /// Creates the logo, [height] logical pixels high without the plate.
  const BrandLogo({super.key, this.height = 96});

  /// The asset of the logo, a copy of `images/carp-x-dtu-logo.svg`.
  static const asset = 'assets/images/carp-x-dtu-logo.svg';

  /// The height of the logo.
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
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
        child: SvgPicture.asset(
          asset,
          height: height,
          semanticsLabel: 'CARP and DTU',
          placeholderBuilder: (context) =>
              SizedBox(height: height, width: height * 576 / 243),
        ),
      ),
    );
  }
}
