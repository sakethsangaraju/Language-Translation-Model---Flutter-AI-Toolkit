// This is a dummy implementation for web platform
// It provides empty implementations of FlutterPcmSound and PcmArrayInt16
// to avoid 'getter isn't defined' errors during compilation

class FlutterPcmSound {
  static void release() {}
  static void setFeedCallback(Function callback) {}
  static Future<void> setup({
    required int sampleRate,
    required int channelCount,
  }) async {}
  static void start() {}
  static void feed(dynamic pcmArray) {}
}

class PcmArrayInt16 {
  PcmArrayInt16({dynamic bytes});

  static PcmArrayInt16 fromList(List<int> list) {
    return PcmArrayInt16();
  }
}
