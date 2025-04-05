// This file contains the actual web implementation of JavaScript interop
// It will only be imported in web environments

import 'dart:developer' as developer;
// ignore: avoid_web_libraries_in_flutter
import 'dart:js' as js;

// Try to initialize Web Audio - returns true if successful
void callInitWebAudio() {
  try {
    // The JavaScript function now returns a boolean indicating success
    final result = js.context.callMethod('initWebAudio');
    developer.log(
      'Web Audio API initialization attempt: ${result == true ? 'successful' : 'failed'}',
    );
  } catch (e) {
    developer.log('Error initializing Web Audio API: $e');
  }
}

// Queue audio for playback when possible
void callPlayPcmAudio(String base64Audio) {
  try {
    js.context.callMethod('playPcmAudio', [base64Audio]);
    developer.log('Audio passed to Web Audio API for playback');
  } catch (e) {
    developer.log('Error playing audio on web: $e');
  }
}
