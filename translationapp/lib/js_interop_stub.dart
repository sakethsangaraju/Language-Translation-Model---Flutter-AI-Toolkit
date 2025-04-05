// This file provides stub implementations for non-web platforms
// so that the code compiles on all platforms without errors

import 'dart:developer' as developer;

void callInitWebAudio() {
  // This is a stub that does nothing in non-web environments
  developer.log('Web Audio init called in non-web environment (no-op)');
}

void callPlayPcmAudio(String base64Audio) {
  // This is a stub that does nothing in non-web environments
  developer.log('Web Audio playback called in non-web environment (no-op)');
}
