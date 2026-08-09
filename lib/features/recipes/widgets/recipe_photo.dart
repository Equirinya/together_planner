import 'package:flutter/material.dart';

import 'package:couple_planner/core/widgets/storage_image.dart';

/// A recipe photo shown a little zoomed out, with the space that frees up
/// filled by stretching the photo's own outermost rows.
///
/// Plain `BoxFit.cover` on a tall card is driven by the frame's height, so a
/// landscape food photo gets scaled until it's a close-up of one corner of the
/// plate. This still covers — no letterboxing — but covers a *shorter* box,
/// which lowers the scale factor and brings the whole dish back into view.
///
/// The bands above and below take a sliver from the very edge of the photo and
/// stretch it to fill, so the extension can only ever be made of pixels that
/// were already at that edge. Two earlier versions blurred instead — first a
/// full-frame copy (which sampled the dish and tinted the bands), then a
/// vertical smear over the slice. Both are gone: a blur is re-rendered every
/// frame, which is expensive while a card is being dragged, and its edge
/// sampling produced visible artefacts as the card moved. Taking a thin enough
/// sliver removes the need for one — there is almost no vertical texture left
/// in a few rows of pixels to band in the first place.
class RecipePhoto extends StatelessWidget {
  const RecipePhoto({
    super.key,
    required this.storagePath,
    this.memCacheWidth,
    this.coverHeightFactor = 0.82,
  });

  final String storagePath;
  final int? memCacheWidth;

  /// Fraction of the frame's height the sharp photo covers. Lower means more of
  /// the dish and wider bands; 1.0 is ordinary `BoxFit.cover`.
  final double coverHeightFactor;

  /// How much of the photo's height each band is stretched from. Deliberately
  /// tiny: a couple of pixels of a food photo's edge is tablecloth, and with so
  /// little vertical variation the stretch reads as a flat colour field.
  static const double _sliceFraction = 0.012;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameHeight =
            constraints.hasBoundedHeight ? constraints.maxHeight : kToolbarHeight * 3;
        final photoHeight = frameHeight * coverHeightFactor;
        final bandHeight = (frameHeight - photoHeight) / 2;

        Widget photo() => StorageImage(
              storagePath: storagePath,
              fit: BoxFit.cover,
              memCacheWidth: memCacheWidth,
            );

        // Renders the photo at its real size, keeps only [_sliceFraction] of it
        // from [edge], and stretches that sliver over the band.
        Widget band(Alignment edge) => ClipRect(
              child: FittedBox(
                fit: BoxFit.fill,
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: Align(
                    alignment: edge,
                    heightFactor: _sliceFraction,
                    child: SizedBox(height: photoHeight, child: photo()),
                  ),
                ),
              ),
            );

        // A Stack with the bands overlapping the photo by a pixel, not a Column
        // of three exact boxes. Fractional heights don't land on device pixel
        // boundaries, so the Column left a sub-pixel gap at each join and the
        // card's dark surface showed through as a hairline. The bands are made
        // of the photo's own edge rows, so overlapping them is invisible.
        //
        // The whole thing is a RepaintBoundary: the swiper moves the card by
        // transforming it, and without this the photo and both stretched bands
        // are re-rasterised on every frame of the drag.
        return RepaintBoundary(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Center(child: SizedBox(height: photoHeight, child: photo())),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: bandHeight + 1,
                child: band(Alignment.topCenter),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                height: bandHeight + 1,
                child: band(Alignment.bottomCenter),
              ),
            ],
          ),
        );
      },
    );
  }
}
