// This file provides JavaScript interoperability with conditional imports
// so that we can use web-specific features without breaking Android builds

import 'package:flutter/foundation.dart' show kIsWeb;

// Web-specific interop
import 'js_interop_web.dart' if (dart.library.io) 'js_interop_stub.dart';

// Re-export the JavaScript functions
void initWebAudio() {
  if (kIsWeb) {
    callInitWebAudio();
  }
}

void playWebAudio(String base64Audio) {
  if (kIsWeb) {
    callPlayPcmAudio(base64Audio);
  }
}
