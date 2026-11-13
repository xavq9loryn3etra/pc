package com.popcorn.flutter_client

import androidx.core.content.FileProvider

/// Lets Android's installer read the downloaded update (res/xml/update_paths.xml).
/// Its own class, so it can't clash with a plugin's FileProvider.
class UpdateFileProvider : FileProvider()
