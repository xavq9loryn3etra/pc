import 'package:flutter/foundation.dart';

/// The title Continue Watching's play button is starting (its
/// `Movie.storageKey`), or null: that card's play button turns into a
/// loading ring meanwhile (see MoviePoster), instead of a popup over the
/// home — what's going on behind (finding a copy, connecting) isn't the
/// viewer's concern. See quickPlay.
final ValueNotifier<String?> quickPlayStarting = ValueNotifier(null);
