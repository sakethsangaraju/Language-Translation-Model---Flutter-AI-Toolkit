// This file contains stub implementations for non-web platforms
// It will only be imported when running on Android, iOS, desktop, etc.

// Stub implementation of web audio initialization
bool callInitWebAudio() {
  // No-op for non-web platforms
  return true;
}

// Stub implementation of audio playback
void callPlayPcmAudio(String base64Audio) {
  // No-op for non-web platforms
}
