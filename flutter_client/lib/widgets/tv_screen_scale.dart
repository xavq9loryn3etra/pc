import 'package:flutter/material.dart';

import '../services/tv_device.dart';

/// On a TV, lays the app out as if on a 1280-wide window, then scales the
/// result to fill the screen.
///
/// A 1080p TV tells apps it's only 960×540 (it draws two pixels per unit),
/// smaller than the laptop windows the wide layouts were made for, so text
/// and artwork came out oversized and lines wrapped where they shouldn't.
/// Scaling keeps the proportions those layouts were designed with; text
/// and artwork are drawn at the TV's own resolution, so nothing blurs.
///
/// Off a TV it's just [child].
class TvScreenScale extends StatelessWidget {
  const TvScreenScale({super.key, required this.child});

  final Widget child;

  static const _designWidth = 1280.0;

  @override
  Widget build(BuildContext context) {
    if (!TvDevice.isTv) return child;
    final media = MediaQuery.of(context);
    final real = media.size;
    if (real.width <= 0 || real.width >= _designWidth) return child;
    final scale = real.width / _designWidth;
    final size = real / scale;
    return FittedBox(
      fit: BoxFit.fill,
      alignment: Alignment.topLeft,
      child: SizedBox.fromSize(
        size: size,
        child: MediaQuery(
          data: media.copyWith(
            size: size,
            devicePixelRatio: media.devicePixelRatio * scale,
            padding: media.padding / scale,
            viewPadding: media.viewPadding / scale,
            viewInsets: media.viewInsets / scale,
          ),
          child: child,
        ),
      ),
    );
  }
}
