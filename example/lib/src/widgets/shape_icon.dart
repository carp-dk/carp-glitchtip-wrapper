// Contains icons in Material 3 Expressive shapes.
//
// Parts:
// - `IconShape`, the expressive shapes the example uses.
// - `ShapeIcon`, an icon on a shaped container that morphs when its shape
//   changes.

import 'package:material_3_expressive/material_3_expressive.dart'
    hide CornerRounding, RoundedPolygon;
import 'package:material_ui/material_ui.dart';

/// The Material 3 Expressive shapes of the example's icon containers.
enum IconShape {
  /// A circle.
  circle,

  /// A four-sided cookie.
  cookie4,

  /// A six-sided cookie.
  cookie6,

  /// A nine-sided cookie.
  cookie9,

  /// A twelve-sided cookie.
  cookie12,

  /// A four-leaf clover.
  clover4,

  /// An eight-leaf clover.
  clover8,

  /// A soft burst.
  softBurst,

  /// A sunny star.
  sunny,

  /// A flower.
  flower,

  /// A puffy cloud.
  puffy,

  /// A pill.
  pill,

  /// A gem.
  gem,

  /// A pentagon.
  pentagon,

  /// An arch.
  arch,

  /// A slanted square.
  slanted,

  /// A ghost.
  ghostish,

  /// A soft boom.
  softBoom;

  /// The polygon of this shape.
  RoundedPolygon get polygon => switch (this) {
    circle => MaterialShapes.circle,
    cookie4 => MaterialShapes.cookie4Sided,
    cookie6 => MaterialShapes.cookie6Sided,
    cookie9 => MaterialShapes.cookie9Sided,
    cookie12 => MaterialShapes.cookie12Sided,
    clover4 => MaterialShapes.clover4Leaf,
    clover8 => MaterialShapes.clover8Leaf,
    softBurst => MaterialShapes.softBurst,
    sunny => MaterialShapes.sunny,
    flower => MaterialShapes.flower,
    puffy => MaterialShapes.puffy,
    pill => MaterialShapes.pill,
    gem => MaterialShapes.gem,
    pentagon => MaterialShapes.pentagon,
    arch => MaterialShapes.arch,
    slanted => MaterialShapes.slanted,
    ghostish => MaterialShapes.ghostish,
    softBoom => MaterialShapes.softBoom,
  };

  /// A border of this shape, e.g. for a [ShapeDecoration].
  MaterialShapeBorder get border => MaterialShapeBorder(shape: polygon);
}

/// An [icon] on a container of an expressive [shape].
///
/// Changing the shape or the colors morphs the container, e.g. when the
/// network condition changes.
class ShapeIcon extends StatelessWidget {
  /// Creates a shaped icon of [size] logical pixels.
  const ShapeIcon(
    this.icon, {
    super.key,
    this.shape = IconShape.cookie9,
    this.size = 48,
    this.color,
    this.iconColor,
    this.semanticLabel,
  });

  /// The icon.
  final IconData icon;

  /// The shape of the container.
  final IconShape shape;

  /// The width and height.
  final double size;

  /// The container color; the primary container by default.
  final Color? color;

  /// The icon color; on primary container by default.
  final Color? iconColor;

  /// What the icon means, for screen readers; decorative when `null`.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = M3ETheme.of(context).colorScheme;
    return AnimatedContainer(
      duration: M3EMotion.long2,
      curve: M3EMotion.emphasizedDecelerate,
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: ShapeDecoration(
        color: color ?? scheme.primaryContainer,
        shape: shape.border,
      ),
      child: Icon(
        icon,
        size: size * 0.46,
        color: iconColor ?? scheme.onPrimaryContainer,
        semanticLabel: semanticLabel,
      ),
    );
  }
}
