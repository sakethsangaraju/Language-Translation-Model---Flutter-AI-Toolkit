import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late WebSocketChannel channel;
  final record = AudioRecorder();
  bool isRecording = false;
  List<int> audioBuffer = [];
  Timer? sendTimer;
  String serverResponse = '';

  // Playback
  List<int> _pcmData = [];
  bool isSetup = false;

  @override
  void initState() {
    super.initState();
    channel = WebSocketChannel.connect(Uri.parse('ws://10.0.2.2:9083'));
    log('WebSocket initialized');
    _setupPcmSound();
    _listenForAudioStream();
  }

  @override
  void dispose() {
    sendTimer?.cancel();
    if (isRecording) stopStream();
    record.dispose();
    channel.sink.close();
    super.dispose();
    log('Disposed');
  }

  void sendJsonAudioStream() async {
    if (!isRecording && await record.hasPermission()) {
      channel.sink.add(jsonEncode({"setup": {"generation_config": {"language": "en"}}}));
      log('Config sent');

      final stream = await record.startStream(
        const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1),
      );

      audioBuffer.clear();
      sendTimer?.cancel();
      sendTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        if (audioBuffer.isNotEmpty) sendBufferedAudio();
      });

      stream.listen(
        (List<int> chunk) {
          audioBuffer.addAll(chunk);
          log('Buffered ${chunk.length} bytes, Total: ${audioBuffer.length}');
        },
        onError: (error) {
          log('Stream error: $error');
          setState(() => isRecording = false);
          sendTimer?.cancel();
        },
        onDone: () {
          log('Stream done');
          sendTimer?.cancel();
          if (audioBuffer.isNotEmpty) sendBufferedAudio();
          setState(() => isRecording = false);
        },
      );

      setState(() => isRecording = true);
    } else {
      log('Microphone permission denied');
    }
  }

  void _listenForAudioStream() {
    channel.stream.listen(
      (message) {
        try {
          var data = jsonDecode(message as String);
          if (data['text'] != null) {
            setState(() => serverResponse = "Text: ${data['text']}");
          }
          if (data['audio'] != null) {
            var pcmBytes = base64Decode(data['audio']);
            log('Received ${pcmBytes.length} bytes');
            _pcmData.addAll(pcmBytes);
            if (!isSetup){
              _setupPcmSound();
            }else{
              FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.view(pcmBytes.buffer)));
            }
          }
        } catch (e) {
          log('Decoding error: $e');
        }
      },
      onError: (error) => log('WebSocket error: $error'),
      onDone: () => log('WebSocket closed'),
    );
  }

  Future<void> _setupPcmSound() async {
    try {
      if (!isSetup) {
        FlutterPcmSound.setFeedCallback(_onFeed);
        await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
        FlutterPcmSound.start();
        isSetup = true;
      }
    } catch (e) {
      log('PCM Sound setup error: $e');
    }
  }

  void _onFeed(int remainingFrames) {
    if (_pcmData.isNotEmpty) {
      final feedSize = _pcmData.length > 8000 ? 8000 : _pcmData.length;
      final frame = _pcmData.sublist(0, feedSize);
      FlutterPcmSound.feed(PcmArrayInt16.fromList(frame));
      _pcmData.removeRange(0, feedSize);
      log('Fed $feedSize samples, remaining: ${_pcmData.length}');
    } else {
      FlutterPcmSound.feed(PcmArrayInt16.fromList(List.filled(8000, 0))); // Feed silence if no data
      log('Fed silence');
    }
  }


  void sendBufferedAudio() {
    if (audioBuffer.isNotEmpty) {
      String base64Audio = base64Encode(audioBuffer);
      channel.sink.add(jsonEncode({"realtime_input": {"media_chunks": [{"mime_type": "audio/pcm", "data": base64Audio}]}}));
      log('Sent ${audioBuffer.length} bytes');
      audioBuffer.clear();
    }
  }

  void stopStream() async {
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();
    channel.sink.close();
    log('Stream & WebSocket closed');
  }

  void stopRecordingOnly() async {
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();
    log('Recording stopped');
  }

  Widget _recordingButton() {
    return FloatingActionButton(
      onPressed: () async {
        if (isRecording) {
          stopRecordingOnly();
          setState(() => isRecording = false);
        } else {
          sendJsonAudioStream();
        }
      },
      child: Icon(isRecording ? Icons.stop : Icons.mic),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Google Flow: The Live Translation App')),
      body: Center(child: Text(serverResponse.isNotEmpty ? serverResponse : 'Press to start recording')),
      floatingActionButton: _recordingButton(),
    );
  }
}
