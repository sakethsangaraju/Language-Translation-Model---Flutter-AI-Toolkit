import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:logger/logger.dart';
import 'package:just_audio/just_audio.dart';
import 'package:record/record.dart';
import 'webrtc_helper.dart';

import 'dart:html' as html;             //ignore for now

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Echo App',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.blue,
      ),
      home: const CommunicationScreen(),
    );
  }
}

class CommunicationScreen extends StatefulWidget {
  const CommunicationScreen({super.key});
  @override
  State<CommunicationScreen> createState() => _CommunicationScreenState();
}

class _CommunicationScreenState extends State<CommunicationScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  late TabController _tabController;
  bool isLoading = false;
  String? responseText; // For REST responses and translation results
  String? imageUrl; // For uploaded image URL
  final TextEditingController _messageController = TextEditingController();
  bool isAudioMode = false;
  List<Map<String, String>> chatHistory = [];

  // Server endpoint (update if needed)
  final String serverAddress = 'http://127.0.0.1:8009';

  // Shared WebSocket connection for translation and audio streaming
  io.Socket? _socket;
  final Logger logger = Logger();


  // Add WebRTC helper


  final WebRTCHelper _webRTCHelper = WebRTCHelper();
  bool isWebRTCEnabled = false;
  bool isWebRTCConnected = false;

  @override
  void initState() {
    super.initState();
    // Three tabs: Text, Image, Audio
    _tabController = TabController(length: 3, vsync: this);

    // Clear displayed data when switching tabs
    _tabController.addListener(() {
      setState(() {
        responseText = null;
        imageUrl = null;
      });
    });


    // Initialize socket connection

    _setupSocketConnection();
  }

  void _setupSocketConnection() {

    // Your existing socket setup code

    _socket = io.io('http://127.0.0.1:8009', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': true,
    });


    // Connect the shared WebSocket
    _socket!.connect();

    // Handle socket connection events
    _socket!.on('connect', (_) {
      logger.d('Socket connected');

      // Initialize WebRTC after socket connection is established

    _socket!.connect();

    _socket!.on('connect', (_) {
      logger.d('Socket connected');


      _initializeWebRTC();
    });

    _socket!.on('disconnect', (_) {
      logger.d('Socket disconnected');
      if (mounted) {
        setState(() {
          responseText = "Server disconnected. Please reload the page.";
        });
      }

    });

    _socket!.on('connected', (data) {
      logger.d('Socket connected: $data');
    });


    });

    _socket!.on('connected', (data) {
      logger.d('Socket connected: $data');
    });


    _socket!.on('translation_final', (data) {
      logger.d('Translation final received: ${data.toString()}');
      logger.d('Translation result data: ${data['data']}');
      if (mounted) {
        setState(() {
          isLoading = false;
          responseText = data['data']?.toString().trim();
          logger.d('Updated UI with translation: $responseText');
        });
      }
    });

    _socket!.on('translation_error', (data) {
      logger.e('Translation error: $data');
      if (mounted) {
        setState(() {
          isLoading = false;
          responseText = "Error: ${data['error'] ?? 'Unknown error occurred'}";
        });
      }
    });


    // Initialize audio processing
    final sessionId = 'webrtc-${DateTime.now().millisecondsSinceEpoch}';
    logger.d('Creating new WebRTC session: $sessionId');

    // Remove channelRef initialization since it's not used
  }

  // Initialize WebRTC

    // Audio processing
    final sessionId = 'webrtc-${DateTime.now().millisecondsSinceEpoch}';
    logger.d('Creating new WebRTC session: $sessionId');

  }

  void _initializeWebRTC() {
    if (_socket != null) {
      _webRTCHelper.initialize(_socket!);


      // Set up callbacks for translation
      _webRTCHelper.onTranslation = (text) {
        logger.i('Received translation via WebRTC: $text');
      };

      setState(() {
        isWebRTCEnabled = true;
      });
      logger.i('WebRTC initialized with socket');
    }
  }


  // End WebRTC call

  void _endWebRTCCall() async {
    if (isWebRTCEnabled) {
      try {
        await _webRTCHelper.endCall();
        setState(() {
          isWebRTCConnected = false;
        });
        logger.i('WebRTC call ended');
      } catch (e) {
        logger.e('Error ending WebRTC call: $e');
      }
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _tabController.dispose();
    _endWebRTCCall();
    _socket?.disconnect();
    _messageController.dispose();
    super.dispose();
  }

  // ----------------- REST: /echo -------------------
  Future<void> sendText() async {
    final txt = _textController.text;
    if (txt.isEmpty) return;
    setState(() {
      isLoading = true;
      responseText = null;
      imageUrl = null;
    });
    try {
      final resp = await http.post(
        Uri.parse('$serverAddress/echo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': txt}),
      );
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        setState(() {
          responseText = "${data['message']} (Echo: ${data['echo']})";
        });
      } else {
        setState(() {
          responseText = 'Error: ${resp.reasonPhrase}';
        });
      }
    } catch (e) {
      setState(() {
        responseText = 'Error: $e';
      });
    }
    setState(() {
      isLoading = false;
    });
  }

  // ----------------- REST: /upload -------------------
  Future<void> sendImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    setState(() {
      isLoading = true;
      responseText = null;
      imageUrl = null;
    });
    try {
      final bytes = await file.readAsBytes();
      final request = http.MultipartRequest(
        'POST',
        Uri.parse('$serverAddress/upload'),
      );
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
      final streamed = await request.send();
      final resp = await http.Response.fromStream(streamed);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        setState(() {
          responseText = data['message'];
          imageUrl = data['url'];
        });
      } else {
        setState(() {
          responseText = 'Error: ${resp.reasonPhrase}';
        });
      }
    } catch (e) {
      setState(() {
        responseText = 'Error: $e';
      });
    }
    setState(() {
      isLoading = false;
    });
  }

  // ----------------- WebSocket: Send translation request -------------------
  void sendMessageWS() {
    final txt = _textController.text;
    if (txt.isNotEmpty) {
      // Show loading indicator
      setState(() {
        isLoading = true;
      });

      // Set a timeout to prevent indefinite loading
      Timer(const Duration(seconds: 10), () {
        if (mounted && isLoading) {
          setState(() {
            isLoading = false;

            responseText = "Request timed out.";

            responseText = "Request timed out. Please try again.";

          });
        }
      });

      final sessionId = 'session-${DateTime.now().millisecondsSinceEpoch}';
      logger.d('Sending translation request with sessionId: $sessionId');

      _socket!.emit('translate', {'sessionId': sessionId, 'text': txt});
      _textController.clear();
    }
  }

  @override
  Widget build(BuildContext ctx) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echo App'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Text'),
            Tab(text: 'Image'),
            Tab(text: 'Audio'),
          ],
        ),
      ),
      body: isLoading
          ? const Center(child: CircularProgressIndicator())
          : TabBarView(
              controller: _tabController,
              children: [
                // 1) Text tab with animations
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      TextField(
                        controller: _textController,
                        decoration: const InputDecoration(
                          hintText: 'Enter text...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton(
                            onPressed: sendText,
                            child: const Text("Send Text (REST)"),
                          ),
                          ElevatedButton(
                            onPressed: sendMessageWS,
                            child: const Text("Translate (WS)"),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (responseText != null)
                        Text(
                          responseText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                          ),
                        )
                            .animate()
                            .fadeIn(duration: const Duration(milliseconds: 600))
                            .slideY(begin: 0.5, end: 0)
                            .then(
                              delay: const Duration(milliseconds: 200),
                            )
                            .shimmer(duration: const Duration(seconds: 1)),
                    ],
                  ),
                ),

                // 2) Image tab

                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: sendImage,
                        child: const Text("Upload Image"),
                      ),
                      const SizedBox(height: 16),
                      if (responseText != null)
                        Text(
                          responseText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ).animate().fadeIn(
                            duration: const Duration(milliseconds: 600)),
                      if (imageUrl != null)
                        Image.network(imageUrl!)
                            .animate()
                            .fadeIn(
                              duration: const Duration(milliseconds: 800),
                            )
                            .slideY(begin: 0.2, end: 0),
                    ],
                  ),
                ),

                // 3) Audio Streaming Tab (WS)

                AudioStreamWidget(socket: _socket!),
              ],
            ),
    );
  }
}

// AudioStreamWidget: Handles audio recording and streaming via WebSocket
class AudioStreamWidget extends StatefulWidget {
  final io.Socket socket;
  const AudioStreamWidget({super.key, required this.socket});

  @override
  State<AudioStreamWidget> createState() => _AudioStreamWidgetState();
}

class _AudioStreamWidgetState extends State<AudioStreamWidget> {
  final Logger logger = Logger();
  late final io.Socket _socket;
  bool _isRecording = false;

  bool _isProcessing = false;            // planning to use this for processing state
  String? _error;
  String _status = "Connecting...";        // planning to use this for status
  bool _isConnected = false;                 // planning to use this for connection state

  bool _isProcessing = false;
  String? _error;
  String _status = "Connecting...";
  bool _isConnected = false;

  final _player = AudioPlayer();
  bool _isPlaying = false;
  String? _translatedText;
  String? _audioB64;

  String _sessionId = 'audio-session';                //ignore for now

  String _sessionId = 'audio-session';

  final _audioRecorder = AudioRecorder();
  Timer? _recordingTimer;

  // Store raw audio for direct playback
  Uint8List? _rawAudioData;

  // Web-specific variables
  dynamic _webRecorder;                                 // planning to use this for recording
  dynamic _webStream;
  List<dynamic> _recordedChunks = [];                   // planning to use this for recording
  String newSessionId = '';

  // WebRTC-related variables
  bool _useWebRTC = false; // Toggle between WebRTC and WebSocket

  dynamic _webRecorder;
  dynamic _webStream;
  List<dynamic> _recordedChunks = [];
  String newSessionId = '';

  bool _useWebRTC = false; // WebRTC vs WebSocket

  bool _isWebRTCConnected = false;
  final WebRTCHelper _webRTCHelper = WebRTCHelper();

  @override
  void initState() {
    super.initState();
    _socket = widget.socket;
    _setupSocketListeners();
    _preloadPlayer();

    // Initialize WebRTC helper
    _initializeWebRTC();


    // Listen to player state changes (restored from original code)

    _player.playerStateStream.listen((state) {
      if (state.processingState == ProcessingState.completed) {
        if (mounted) {
          setState(() {
            _isPlaying = false;
          });
        }
      }
    });
  }

  void _initializeWebRTC() {
    _webRTCHelper.initialize(_socket);

    // callbacks
    _webRTCHelper.onTranscription = (text) {
      setState(() {
        // We need to keep track of the text even though we don't display it directly
        // It's used internally by the WebRTC helper
        _translatedText = text;
      });
    };

    _webRTCHelper.onTranslation = (text) {
      setState(() {
        _translatedText = text;
      });
    };

    _webRTCHelper.onError = (error) {
      setState(() {
        _error = error;
      });
    };

    _webRTCHelper.onAudioReceived = (audioBase64) {
      setState(() {
        _audioB64 = audioBase64;
        //_isProcessing = false;
      });


      // Play the received audio
      _playTTS();
    };

    // Add callback for raw audio capture

      _playTTS();
    };

    _webRTCHelper.onRawAudioCaptured = (rawAudio) {
      setState(() {
        _rawAudioData = rawAudio;
        //_isProcessing = false;
      });
      logger.i("Received raw audio from WebRTC: ${rawAudio.length} bytes");
    };

    logger.i('WebRTC initialized in AudioStreamWidget');
  }


  // Toggle WebRTC mode

  // Toggle WebRTC

  void _toggleWebRTC(bool useWebRTC) {
    if (useWebRTC == _useWebRTC) return;

    setState(() {
      _useWebRTC = useWebRTC;
    });

    if (useWebRTC) {

      // Start WebRTC call when switching to WebRTC mode
      _startWebRTCCall();
    } else {
      // End WebRTC call when switching to WebSocket mode

      _startWebRTCCall();
    } else {

      _endWebRTCCall();
    }
  }


  // Start WebRTC call


  void _startWebRTCCall() async {
    try {
      bool success = await _webRTCHelper.startCall();
      setState(() {
        _isWebRTCConnected = success;
        _status = success ? "WebRTC connected" : "WebRTC connection failed";
      });
      logger.i(
          'WebRTC call ${success ? "started" : "failed"} in AudioStreamWidget');
    } catch (e) {
      logger.e('Error starting WebRTC call: $e');
      setState(() {
        _error = "Error starting WebRTC call: $e";
      });
    }
  }

  // End WebRTC call

  void _endWebRTCCall() async {
    try {
      await _webRTCHelper.endCall();
      setState(() {
        _isWebRTCConnected = false;
        _status = "WebRTC call ended";
      });
      logger.i('WebRTC call ended in AudioStreamWidget');
    } catch (e) {
      logger.e('Error ending WebRTC call: $e');
    }
  }

  // Toggle WebRTC recording
  void _toggleWebRTCRecording() {
    if (_isRecording) {
      // Stop recording


  void _toggleWebRTCRecording() {
    if (_isRecording) {

      _webRTCHelper.stopRecording();
      setState(() {
        _isRecording = false;
        _isProcessing = true;
        _status = "Processing WebRTC audio...";

      });
    } else {
      // Start recording
      _webRTCHelper.startRecording();
      setState(() {
        _isRecording = true;
        _status = "Recording via WebRTC...";
        _translatedText = null;
        _audioB64 = null;
        _rawAudioData = null;
        _error = null;
      });

      });
    } else {
      _webRTCHelper.startRecording();
      setState(() {
        _isRecording = true;
        _status = "Recording via WebRTC...";
        _translatedText = null;
        _audioB64 = null;
        _rawAudioData = null;
        _error = null;
      });

    }
  }

  // Preload the audio player to solve the "first play doesn't work" issue
  Future<void> _preloadPlayer() async {
    try {
      // Create silent audio data and play it to initialize the player
      final silentAudioBase64 =
          "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA//tAwAAAAAAAAAAAAAAAAAAAAAAAWGluZwAAAA8AAAACAAADwAD///////////////////////////////////////////8AAAA8TEFNRTMuMTAwAc0AAAAAAAAAABSAJAJAQgAAgAAAA8DWxzxJAAAAAAAAAAAAAAAAAAAA";
      final silentAudioUrl = 'data:audio/mp3;base64,$silentAudioBase64';

      if (kIsWeb) {
        logger.i("Web platform detected, preparing audio player");
      } else {
        await _player.setUrl(silentAudioUrl);
        await _player.play();
        await _player.stop();
        logger.i("Preloaded audio player successfully");
      }
    } catch (e) {
      logger.e("Error preloading audio player: $e");
    }
  }

  void _setupSocketListeners() {
    // Listen for translation results
    widget.socket.on('translation_result', (data) {
      final responseSessionId = data['sessionId'];
      logger.i(
          "Received translation result for session: $responseSessionId (current: $_sessionId)");

      if (responseSessionId != _sessionId) {
        logger.w("Session ID mismatch, ignoring response");
        return;
      }

      final audioData = data['audio'];

      final englishText = data['english_text'];     //  planning to use this for english text

      final englishText = data['english_text'];

      final spanishText = data['spanish_text'];

      setState(() {
        _status = "Translation received";
        _isProcessing = false;
        _audioB64 = audioData;
        _translatedText = spanishText;
        _error = null;
      });

      // Play the audio automatically
      if (audioData != null && audioData.isNotEmpty) {
        _playTTS();
      }
    });

    // Listen for errors
    widget.socket.on('audio_error', (data) {
      final responseSessionId = data['sessionId'];
      logger.e(
          "Audio error for session: $responseSessionId (current: $_sessionId): ${data['error']}");

      if (responseSessionId == _sessionId) {
        setState(() {
          _status = "Error";
          _isProcessing = false;
          _error = data['error'];
          _translatedText = data['spanish_text'];
        });
      }
    });

    // Listen for connection events
    widget.socket.on('connect', (_) {
      logger.i("Socket connected");
      setState(() {
        _isConnected = true;
        _status = "Connected";
      });
    });

    widget.socket.on('disconnect', (_) {
      logger.w("Socket disconnected");
      setState(() {
        _isConnected = false;
        _status = "Disconnected";
      });
    });
  }

  Future<void> _playTTS() async {
    if (_audioB64 == null || _audioB64!.isEmpty) {
      logger.e("No audio data to play");
      setState(() {
        _error = "No audio data to play";
      });
      return;
    }

    setState(() {
      _isPlaying = true;
      _error = null;
    });

    try {
      logger.i("Decoding audio data from base64 (${_audioB64!.length} chars)");

      // Stop any current playback
      await _player.stop();

      // Make sure base64 is properly padded

      await _player.stop();

      // Make sure base64 is padded

      String paddedAudio = _audioB64!;
      while (paddedAudio.length % 4 != 0) {
        paddedAudio += '=';
      }


      // Decode the base64 string to bytes

      //base64 string to bytes

      final bytes = base64Decode(paddedAudio);
      logger.i("Decoded audio data: ${bytes.length} bytes");

      if (bytes.length < 100) {
        logger.e("Audio data too small: ${bytes.length} bytes");
        setState(() {
          _error = "Audio data too small";
          _isPlaying = false;
        });
        return;
      }


      // Create a data URL and play
      final base64Sound = base64Encode(bytes);
      final url = 'data:audio/mp3;base64,$base64Sound';

      // Set the audio source and play
      await _player.setUrl(url);

      // Play the audio

      final base64Sound = base64Encode(bytes);
      final url = 'data:audio/mp3;base64,$base64Sound';

      await _player.setUrl(url);


      await _player.play();
      logger.i("Audio playback started");
    } catch (e) {
      logger.e("Error playing TTS: $e");
      setState(() {
        _error = "Playback error: $e";
        _isPlaying = false;
      });
    }
  }


  // Method to play back the raw recording

  // playback recording

  Future<void> _playRawRecording() async {
    if (_rawAudioData == null || _rawAudioData!.isEmpty) {
      setState(() {
        _error = 'No recording available to play';
      });
      return;
    }

    try {
      setState(() {
        _isPlaying = true;
        _error = null;
      });

      logger.i("Playing raw recording (${_rawAudioData!.length} bytes)");


      // Create a URL from the raw audio data
      final blob = html.Blob([_rawAudioData!], 'audio/webm');
      final url = html.Url.createObjectUrl(blob);

      // Play the audio
      await _player.setUrl(url);
      await _player.play();

      // Listen for completion

      final blob = html.Blob([_rawAudioData!], 'audio/webm');
      final url = html.Url.createObjectUrl(blob);

      await _player.setUrl(url);
      await _player.play();


      _player.playerStateStream.listen((state) {
        if (state.processingState == ProcessingState.completed) {
          if (mounted) {
            setState(() {
              _isPlaying = false;
            });
          }

          // Clean up URL

          html.Url.revokeObjectUrl(url);
        }
      });
    } catch (e) {
      logger.e("Error playing raw recording: $e");
      setState(() {
        _error = 'Error playing: $e';
        _isPlaying = false;
      });
    }
  }

  @override
  void dispose() {
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _player.dispose();
    // Clean up web resources
    if (kIsWeb && _webStream != null) {
      _webStream!.getTracks().forEach((track) => track.stop());
      _webStream = null;
    }

    _socket.disconnect();
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [

            // Simplified WebRTC Controls

            Container(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // Title - simplified
                  Text("Audio Recording"),
                  SizedBox(height: 8),

                  // Toggle Switch - simplified

                  Text("Audio Recording"),
                  SizedBox(height: 8),
                  // Toggle Switch 
                  Row(
                    children: [
                      Text("Use WebRTC: "),
                      Switch(
                        value: _useWebRTC,
                        onChanged: _toggleWebRTC,
                      ),
                    ],
                  ),


                  // Status - no colors

                  Text(
                    "Status: ${_useWebRTC ? (_isWebRTCConnected ? 'Connected' : 'Connecting...') : 'Not using WebRTC'}",
                  ),

                  SizedBox(height: 8),
                  // Start/Stop Recording Button - no colors
                  // Start/Stop Recording Button
                  if (_useWebRTC)
                    ElevatedButton(
                      onPressed:
                          _isWebRTCConnected ? _toggleWebRTCRecording : null,
                      child: Text(
                          _isRecording ? "Stop Speaking" : "Start Speaking"),
                    ),


                  // Play Raw Audio button - no colors
                  // Play Raw Audio button
                  if (_useWebRTC && !_isRecording && _rawAudioData != null) ...[
                    SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: !_isPlaying ? _playRawRecording : null,
                      child: Text("Play Raw Recording"),
                    ),
                    Text(
                        "Raw recording size: ${_rawAudioData?.length ?? 0} bytes"),
                  ],

                  // Translation text - simplified

                  if (_useWebRTC && _translatedText != null) ...[
                    SizedBox(height: 8),
                    Text("Translation: $_translatedText"),
                  ],
                  // Error display - simplified
                  if (_error != null) ...[
                    SizedBox(height: 8),
                    Text("Error: $_error"),
                  ],
                ],
              ),
            ),
            // Only show original UI if not in WebRTC mode - simplified

            // Only show original UI if not in WebRTC mode
            if (!_useWebRTC) ...[
              SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8.0),
                child: Text("WebSocket mode not currently in use"),
              ),
            ],
          ],
        ),
      ),
    );
  }
}