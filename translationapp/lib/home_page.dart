import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';

class NativeFlowTheme {
  static const Color primaryBlue = Color(0xFF4D96FF);
  static const Color accentPurple = Color(0xFF5C33FF);
  static const Color lightBlue = Color(0xFF8BC7FF);
  static const Color backgroundGrey = Color(0xFFF9FAFC);
  static const Color textDark = Color(0xFF2D3748);
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primaryBlue, accentPurple],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with TickerProviderStateMixin {
  late WebSocketChannel channel;
  final record = AudioRecorder();
  bool isRecording = false;
  List<int> audioBuffer = [];
  Timer? sendTimer;
  String serverResponse = '';
  final List<int> _pcmData = [];
  bool isSetup = false;

  bool isConnecting = true;
  String connectionStatus = 'Connecting to server...';
  bool isAiSpeaking = false;
  int silentSeconds = 0;
  Timer? silenceTimer;

  late AnimationController _logoAnimationController;
  late AnimationController _buttonScaleController;
  late AnimationController _buttonSlideController;
  late AnimationController _statusAnimationController;
  late AnimationController _micIconController;
  late AnimationController _speakingAnimationController;
  late AnimationController _progressAnimationController;
  late Animation<double> _logoFadeAnimation;
  late Animation<Offset> _logoSlideAnimation;
  late Animation<double> _buttonScaleAnimation;
  late Animation<Offset> _buttonSlideAnimation;
  late Animation<double> _statusFadeAnimation;
  late Animation<Offset> _statusSlideAnimation;
  late Animation<double> _micIconScaleAnimation;
  late Animation<double> _speakingScaleAnimation;
  late Animation<double> _progressFadeAnimation;

  @override
  void initState() {
    super.initState();
    _logoAnimationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _buttonScaleController = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
    _buttonSlideController = AnimationController(vsync: this, duration: const Duration(milliseconds: 400));
    _statusAnimationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
    _micIconController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1000))..repeat(reverse: true);
    _speakingAnimationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 700))..repeat(reverse: true);
    _progressAnimationController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1500))..repeat();
    _logoFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _logoAnimationController, curve: Curves.easeOut));
    _logoSlideAnimation = Tween<Offset>(begin: const Offset(-0.2, 0.0), end: Offset.zero).animate(CurvedAnimation(parent: _logoAnimationController, curve: Curves.easeOutQuad));
    _buttonScaleAnimation = Tween<double>(begin: 1.0, end: 1.1).animate(CurvedAnimation(parent: _buttonScaleController, curve: Curves.easeInOutCubic));
    _buttonSlideAnimation = Tween<Offset>(begin: const Offset(0.0, 0.5), end: Offset.zero).animate(CurvedAnimation(parent: _buttonSlideController, curve: Curves.easeOutQuad));
    _statusFadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(parent: _statusAnimationController, curve: Curves.easeOut));
    _statusSlideAnimation = Tween<Offset>(begin: const Offset(0.0, 0.2), end: Offset.zero).animate(CurvedAnimation(parent: _statusAnimationController, curve: Curves.easeOutQuad));
    _micIconScaleAnimation = Tween<double>(begin: 0.8, end: 1.0).animate(CurvedAnimation(parent: _micIconController, curve: Curves.easeInOut));
    _speakingScaleAnimation = Tween<double>(begin: 0.9, end: 1.1).animate(CurvedAnimation(parent: _speakingAnimationController, curve: Curves.easeInOut));
    _progressFadeAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(CurvedAnimation(parent: _progressAnimationController, curve: Curves.easeInOut));
    _logoAnimationController.forward();
    _buttonSlideController.forward();
    _statusAnimationController.forward();

     if (mounted) { setState(() { isConnecting = true; connectionStatus = 'Connecting to server...'; }); }
    try {
      channel = WebSocketChannel.connect(Uri.parse('ws://10.0.2.2:9083'));
      log('WebSocket initialized');
      _setupPcmSound();
      _listenForAudioStream();
      if (mounted) { setState(() { isConnecting = false; connectionStatus = 'Connected'; }); }
    } catch (e) {
       log('Error during initState logic: $e');
       if (mounted) { setState(() { isConnecting = false; connectionStatus = 'Connection failed'; serverResponse = 'Init Error: $e'; }); }
    }
  }

  @override
  void dispose() {
    _logoAnimationController.dispose();
    _buttonScaleController.dispose();
    _buttonSlideController.dispose();
    _statusAnimationController.dispose();
    _micIconController.dispose();
    _speakingAnimationController.dispose();
    _progressAnimationController.dispose();
    silenceTimer?.cancel();
    sendTimer?.cancel();
    isSetup = false;
    isAiSpeaking = false;
    _pcmData.clear();
    log('Ensured PCM feeding is stopped in dispose.');
    if (isRecording) stopStream();
    record.dispose();
    channel.sink.close();
    super.dispose();
    log('Disposed');
  }

  void _startSilenceDetection() {
    silenceTimer?.cancel();
    silentSeconds = 0;
    silenceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
       if (mounted) { silentSeconds++; }
      if (silentSeconds >= 5) {
        log('5 seconds of silence detected - initiating stopRecordingOnly()');
        if (isRecording) {
            stopRecordingOnly();
            if (mounted) setState(() => isRecording = false);
        }
        silenceTimer?.cancel();
      }
    });
  }

  void _showPermissionAlert(BuildContext context) {
     showDialog(
       context: context,
       builder: (BuildContext context) {
         return AlertDialog(
           title: const Text('Microphone Permission Required'),
           content: const Text(
             'This app needs microphone access to record audio. '
             'Please enable microphone access in your device settings.',
           ),
           actions: [
             TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
             TextButton(onPressed: () { Navigator.of(context).pop(); _openAppSettings(); }, child: const Text('Open Settings')),
           ],
         );
       },
     );
  }

  void _openAppSettings() async { log('Opening app settings (app_settings package needed for real functionality)'); }

  void sendJsonAudioStream() async {
    if (isConnecting) { log('Cannot record while connecting'); return; }

    bool hasPermission = await record.hasPermission();
    if (!isRecording && hasPermission) {
      channel.sink.add(jsonEncode({"setup": {"generation_config": {"language": "en"}}}));
      log('Config sent');
      try {
          final stream = await record.startStream( const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1), );
          audioBuffer.clear();
          sendTimer?.cancel();
          sendTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
            if (audioBuffer.isNotEmpty) sendBufferedAudio();
             if (mounted) setState(() => silentSeconds = 0);
          });
           _startSilenceDetection();
          stream.listen(
            (List<int> chunk) {
              audioBuffer.addAll(chunk);
              log('Buffered ${chunk.length} bytes, Total: ${audioBuffer.length}');
               if (mounted) setState(() => silentSeconds = 0);
            },
            onError: (error) {
              log('Stream error: $error');
               if (mounted) { setState(() { isRecording = false; serverResponse = "Recording Error: $error"; }); }
              sendTimer?.cancel();
              silenceTimer?.cancel();
            },
            onDone: () {
              log('Stream done');
              sendTimer?.cancel();
              silenceTimer?.cancel();
              if (audioBuffer.isNotEmpty) sendBufferedAudio();
              if (mounted) setState(() => isRecording = false);
            },
          );
           if (mounted) setState(() { isRecording = true; serverResponse = ''; });
      } catch (e) {
          log('Error starting recording stream: $e');
          if (mounted) { setState(() { serverResponse = "Error starting recording."; isRecording = false; }); }
          sendTimer?.cancel();
          silenceTimer?.cancel();
      }
    } else if (!hasPermission) {
      log('Microphone permission denied');
      _showPermissionAlert(context);
    } else {
       log('Already recording or permission denied');
    }
  }

  void _listenForAudioStream() {
    channel.stream.listen(
      (message) {
        bool audioStartReceived = false;
        bool turnCompleteReceived = false;
        bool audioChunkReceived = false;

        try {
          var data = jsonDecode(message as String);

           if (data['audio_start'] == true) {
               audioStartReceived = true;
               log('audio_start received.');
               if (mounted) setState(() { isAiSpeaking = true; serverResponse = ''; });
               _pcmData.clear();
            } else if (data['turn_complete'] == true) {
                turnCompleteReceived = true;
                log('turn_complete received.');
                _pcmData.clear();
                isSetup = false;
                log('PCM Player feeding stopped due to turn_complete (cleared buffer, reset setup flag).');
                if (mounted) setState(() => isAiSpeaking = false);
            }

          if (data['text'] != null) {
             String receivedText = data['text'] as String;
             log('Received text: $receivedText');
             if(mounted) setState(() => serverResponse = receivedText);
          }
          if (data['audio'] != null) {
            audioChunkReceived = true;
            var pcmBytes = base64Decode(data['audio']);
            log('Received ${pcmBytes.length} audio bytes');
            _pcmData.addAll(pcmBytes);
            if (!isSetup){
              _setupPcmSound();
            }else{
              FlutterPcmSound.feed(PcmArrayInt16(bytes: ByteData.view(Uint8List.fromList(pcmBytes).buffer)));
            }
             if (!isAiSpeaking && mounted) {
               setState(() => isAiSpeaking = true);
             }
          }
        } catch (e) {
          log('Decoding error: $e');
           if(mounted) setState(() => serverResponse = "Decoding Error.");
        }
      },
      onError: (error) {
         log('WebSocket error: $error');
         if(mounted) setState(() { isConnecting = false; connectionStatus = "WebSocket Error"; isRecording = false; isAiSpeaking = false; serverResponse = "WebSocket Error: $error"; });
         _resetStateAfterError();
      },
      onDone: () {
        log('WebSocket closed');
         if(mounted) setState(() { isConnecting = false; connectionStatus = "Connection Closed"; isRecording = false; isAiSpeaking = false; serverResponse = "Connection Closed"; });
        _resetStateAfterError();
      },
    );
  }

  void _resetStateAfterError() { silenceTimer?.cancel(); }

  Future<void> _setupPcmSound() async {
    try {
      if (!isSetup) {
        FlutterPcmSound.setFeedCallback(_onFeed);
        await FlutterPcmSound.setup(sampleRate: 24000, channelCount: 1);
        FlutterPcmSound.start();
        isSetup = true;
        log('PCM sound setup complete');
      }
    } catch (e) {
      log('PCM Sound setup error: $e');
      if(mounted) setState(() => serverResponse = "Audio Setup Error.");
    }
  }

void _onFeed(int remainingFrames) {
  if (!isSetup || !isAiSpeaking) {
    return;
  }
  if (_pcmData.isNotEmpty) {
    final feedSize = _pcmData.length > 8000 ? 8000 : _pcmData.length;
    final frame = _pcmData.sublist(0, feedSize);
    try {
      FlutterPcmSound.feed(PcmArrayInt16.fromList(frame));
       _pcmData.removeRange(0, feedSize);
    } catch (e) { log('Error feeding audio in _onFeed: $e'); _pcmData.clear(); }
  } else {
    try {
      FlutterPcmSound.feed(PcmArrayInt16.fromList(List.filled(1024, 0)));
    } catch(e) { log('Error feeding silence in _onFeed: $e'); }
  }
}

  void sendBufferedAudio() {
    if (audioBuffer.isNotEmpty) {
      String base64Audio = base64Encode(audioBuffer);
      channel.sink.add(jsonEncode({"realtime_input": {"media_chunks": [{"mime_type": "audio/pcm", "data": base64Audio}]}}));
      log('Sent ${audioBuffer.length} audio bytes');
      audioBuffer.clear();
    }
  }

  void stopStream() async {
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();

    _pcmData.clear();
    isSetup = false;
    log('PCM Player feeding stopped in stopStream.');

    channel.sink.close();
    log('Stream & WebSocket closed');
    silenceTimer?.cancel();
    if (mounted) { setState(() { isRecording = false; isAiSpeaking = false; isConnecting = false; connectionStatus = 'Disconnected'; }); }
  }

  void stopRecordingOnly() async {
    await record.stop();
    sendTimer?.cancel();
    if (audioBuffer.isNotEmpty) sendBufferedAudio();

    if (isAiSpeaking) {
      _pcmData.clear();
      isSetup = false;
      log('PCM Player feeding stopped in stopRecordingOnly (during AI speech).');
        if (mounted) setState(() => isAiSpeaking = false);
    }

    log('Recording stopped');
    silenceTimer?.cancel();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_statusAnimationController.status != AnimationStatus.forward) {
       _statusAnimationController.forward(from: 0.0);
    }
  }

  Widget _recordingButton() {
    return SlideTransition(
      position: _buttonSlideAnimation,
      child: ScaleTransition(
        scale: isRecording || isAiSpeaking ? _buttonScaleAnimation : const AlwaysStoppedAnimation(1.0),
        child: FloatingActionButton(
         onPressed: isConnecting
           ? null
           : () async {
               if (isRecording) {
                 stopRecordingOnly();
                 _pcmData.clear();
                 isSetup = false;
                 log('PCM Player feeding stopped manually (cleared buffer, reset setup flag).');
                 if (mounted) {
                   setState(() {
                     isRecording = false;
                     isAiSpeaking = false;
                   });
                 }
               } else {
                  sendJsonAudioStream();
               }
             },
          backgroundColor: isRecording ? Colors.red : (isAiSpeaking ? NativeFlowTheme.accentPurple : NativeFlowTheme.primaryBlue),
          child: Icon(isRecording ? Icons.stop : (isAiSpeaking ? Icons.hearing : Icons.mic), color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildLogo() {
     return FadeTransition(opacity: _logoFadeAnimation, child: SlideTransition(position: _logoSlideAnimation, child: Row(mainAxisSize: MainAxisSize.min, children: [ Text('Native', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: NativeFlowTheme.primaryBlue)), Text('Flow', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: NativeFlowTheme.accentPurple)), ],),),);
  }

  Widget _buildStatusMessage() {
    final message =
        isConnecting
            ? connectionStatus
            : serverResponse.isNotEmpty
                ? serverResponse
                : isAiSpeaking
                    ? 'Gemini is speaking...'
                    : isRecording
                        ? 'Listening...'
                        : 'Press microphone to start speaking';

    final textColor = isAiSpeaking ? NativeFlowTheme.accentPurple : (isRecording ? NativeFlowTheme.primaryBlue : NativeFlowTheme.textDark);

    return FadeTransition(
      opacity: _statusFadeAnimation,
      child: SlideTransition(
        position: _statusSlideAnimation,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          decoration: BoxDecoration( color: Colors.white, borderRadius: BorderRadius.circular(12), boxShadow: [ BoxShadow( color: Colors.black.withAlpha(13), blurRadius: 10, spreadRadius: 0, offset: const Offset(0, 2), ), ], ),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle( fontSize: 18, fontWeight: isAiSpeaking || isRecording ? FontWeight.bold : FontWeight.normal, color: textColor, ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: NativeFlowTheme.backgroundGrey,
      appBar: AppBar(title: _buildLogo(), elevation: 0, backgroundColor: Colors.white, centerTitle: true),
      body: Container(
        decoration: BoxDecoration( gradient: LinearGradient( begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, NativeFlowTheme.backgroundGrey], ), ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isConnecting) FadeTransition(opacity: _progressFadeAnimation, child: const CircularProgressIndicator()),
              Padding(padding: const EdgeInsets.all(20.0), child: _buildStatusMessage()),
              if (isRecording) Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: FadeTransition(
                    opacity: const AlwaysStoppedAnimation(1.0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ScaleTransition(scale: _micIconScaleAnimation, child: Icon(Icons.mic, color: NativeFlowTheme.primaryBlue)),
                        const SizedBox(width: 8),
                        Text('Recording will auto-stop after 5 seconds of silence', style: TextStyle(color: Colors.grey[600], fontSize: 14)),
                      ],
                    ),
                  ),
                ),
              if (isAiSpeaking) ScaleTransition(
                  scale: _speakingScaleAnimation,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 20),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(50), color: NativeFlowTheme.accentPurple.withAlpha(26)),
                    child: Icon(Icons.hearing, color: NativeFlowTheme.accentPurple, size: 28),
                  ),
                ),
            ],
          ),
        ),
      ),
      floatingActionButton: _recordingButton(),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}