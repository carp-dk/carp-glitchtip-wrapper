// Contains the app bar of the example's pages.
//
// Parts:
// - `PageAppBar`, an expressive flexible sliver app bar whose title and
//   subtitle always fit its height.

import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:material_ui/material_ui.dart'
    hide CornerRounding, RoundedPolygon;

/// A flexible sliver app bar for a [CustomScrollView], with a back button
/// when the page can go back.
///
/// The bar has a fixed height, so the [title] and [subtitle] get one line
/// each and the text scale is clamped, as for the app bars of the Material
/// library; the page content scales fully.
class PageAppBar extends StatelessWidget {
  /// Creates an app bar with [title].
  const PageAppBar({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.variant = M3EAppBarVariant.largeFlexible,
  });

  /// The headline.
  final String title;

  /// An optional line below the headline.
  final String? subtitle;

  /// Actions at the end of the bar.
  final List<Widget> actions;

  /// The size of the bar.
  final M3EAppBarVariant variant;

  @override
  Widget build(BuildContext context) {
    final subtitle = this.subtitle;
    // the headline and the subtitle fit the bar's height up to 1.2
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: M3EAppBar.sliver(
        variant: variant,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: actions,
      ),
    );
  }
}
