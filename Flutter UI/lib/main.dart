import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:logger/logger.dart';
// We need to continue using the old libraries until the codebase is fully migrated
import 'dart:js_util' as js_util;
import 'dart:html' as html;
import 'dart:js' as js;
import 'package:flutter_animate/flutter_animate.dart';

void main() {
  if (kIsWeb) {
    // Force HTML renderer for webcam support.
    html.window.document.documentElement!
        .setAttribute('data-flutter-web-renderer', 'html');
  }

  // Initialize Animate package
  Animate.restartOnHotReload = true;

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
        colorSchemeSeed: const Color.fromARGB(255, 101, 208, 223),
        brightness: Brightness.light,
      ),
      home: const GeminiLiveScreen()
          .animate()
          .fadeIn(duration: 600.ms, curve: Curves.easeOutQuad),
      debugShowCheckedModeBanner: false,
    );
  }
}

class GeminiLiveScreen extends StatefulWidget {
  const GeminiLiveScreen({super.key});
  @override
  State<GeminiLiveScreen> createState() => _GeminiLiveScreenState();
}

class _GeminiLiveScreenState extends State<GeminiLiveScreen> {
  final Logger logger = Logger();
  bool _audioWorkletInitialized = false;
  html.WebSocket? _webSocket;
  // For webcam and audio recording
  html.VideoElement? _videoElement;
  html.CanvasElement? _canvasElement;
  html.MediaStream? _videoStream;
  bool _webcamViewRegistered = false;
  // For recording state
  bool _isRecording = false;
  // For chat messages
  final List<ChatMessage> _chatMessages = [];
  // For audio processing
  Timer? _audioChunkTimer;
  bool _webSocketConnected = false;
  // UI transition state
  bool _usingFlutterUI = false;
  // Text field controller
  final TextEditingController _textController = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      logger.i('Initializing web elements');
      try {
        // Initialize Flutter bridge
        _initializeJSBridge();
        // Setup video and audio components
        _setupVideoElement();
        _setupAudioWorklet();
        _registerChatCallback();
        // Check connection status periodically
        Timer.periodic(const Duration(seconds: 2), _checkConnectionStatus);
      } catch (e) {
        logger.e('Error in initState: $e');
      }
    }
  }

  /// Initialize audio worklet for playback
  Future<void> _setupAudioWorklet() async {
    if (!kIsWeb || _audioWorkletInitialized) return;
    try {
      // Get the global window object.
      var windowObj = html.window;
      // Try to retrieve an existing audioContext; if not, create one.
      var audioContext = js_util.getProperty(windowObj, 'audioContext');
      if (audioContext == null) {
        // Retrieve AudioContext constructor (or webkitAudioContext for compatibility).
        var audioContextClass =
            js_util.getProperty(windowObj, 'AudioContext') ??
                js_util.getProperty(windowObj, 'webkitAudioContext');
        audioContext = js_util.callConstructor(audioContextClass, [
          js_util.jsify({'sampleRate': 24000})
        ]);
        js_util.setProperty(windowObj, 'audioContext', audioContext);
      }

      // Load the external processor module. Ensure that "pcm-processor.js" is in your web folder.
      await js_util.promiseToFuture(js_util.callMethod(
          js_util.getProperty(audioContext, 'audioWorklet'),
          'addModule',
          ['pcm-processor.js']));

      // Create the worklet node and connect it to the destination.
      var workletNode = js_util.callConstructor(
          js_util.getProperty(audioContext, 'AudioWorkletNode'),
          [audioContext, 'pcm-processor']);
      js_util.callMethod(workletNode, 'connect',
          [js_util.getProperty(audioContext, 'destination')]);

      // Store the node globally if needed.
      js_util.setProperty(windowObj, 'workletNode', workletNode);

      _audioWorkletInitialized = true;
      logger.i('AudioWorklet initialized successfully');
    } catch (e) {
      logger.e('Error initializing AudioWorklet: $e');
      setState(() {});
    }
  }

  // Setup video element and add to DOM.
  void _setupVideoElement() {
    try {
      // Check if video element already exists
      _videoElement = html.window.document.getElementById('videoElement')
          as html.VideoElement?;

      if (_videoElement == null) {
        // Create new if it doesn't exist
        _videoElement = html.VideoElement()
          ..id = 'videoElement'
          ..autoplay = true
          ..muted = true
          ..style.width = '320px'
          ..style.height = '240px'
          ..style.borderRadius = '20px'
          ..style.display = 'none'; // Initially hidden until placed in Flutter

        _canvasElement = html.CanvasElement()
          ..id = 'canvasElement'
          ..style.display = 'none';

        html.document.body?.append(_videoElement!);
        html.document.body?.append(_canvasElement!);
        _startWebcam();
      } else {
        // Reuse existing video element
        _canvasElement = html.document.getElementById('canvasElement')
            as html.CanvasElement?;

        // Make sure the element is visible for Flutter
        _videoElement!.style.display = 'block';

        // Check if stream is active
        if (_videoElement!.srcObject == null) {
          _startWebcam();
        }
      }

      _webcamViewRegistered = true;
      logger.i('Video element setup complete');
    } catch (e) {
      logger.e('Error setting up video element: $e');
    }
  }

  // Start webcam stream
  Future<void> _startWebcam() async {
    try {
      final mediaConstraints = {
        'video': {
          'width': {'max': 640},
          'height': {'max': 480},
        }
      };

      _videoStream = await html.window.navigator.mediaDevices!
          .getUserMedia(mediaConstraints);
      _videoElement!.srcObject = _videoStream;

      // Start capturing images at intervals
      Timer.periodic(const Duration(seconds: 3), (_) => _captureImage());

      logger.i('Webcam started successfully');
    } catch (e) {
      logger.e('Error starting webcam: $e');
    }
  }

  // Capture image from webcam
  void _captureImage() {
    if (_videoElement == null ||
        _canvasElement == null ||
        !_videoElement!.videoWidth.isFinite) {
      return;
    }

    try {
      _canvasElement!.width = _videoElement!.videoWidth;
      _canvasElement!.height = _videoElement!.videoHeight;
      _canvasElement!.context2D.drawImage(_videoElement!, 0, 0);
    } catch (e) {
      logger.e('Error capturing image: $e');
    }
  }

  // Initialize the JavaScript bridge
  void _initializeJSBridge() {
    try {
      // Debug JS errors
      js_util.callMethod(js.context, 'eval', [
        'window.onerror = function(message, source, lineno, colno, error) { console.log("JS ERROR:", message, "at", source, lineno, colno, error); }'
      ]);

      // Initialize the bridge
      final result = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.initialize()']);
      logger.i('Flutter bridge initialized: $result');
    } catch (e) {
      logger.e('Error initializing JS bridge: $e');
    }
  }

  // Register callback for chat messages
  void _registerChatCallback() {
    try {
      // Create a callback function in the global scope
      js_util.setProperty(html.window, 'onChatMessage',
          js.allowInterop((String text, bool isUser) {
        logger.i('Chat message received: ${isUser ? "USER" : "GEMINI"}: $text');
        setState(() {
          // Check for duplicates to avoid adding the same message multiple times
          final isDuplicate = _chatMessages
              .any((msg) => msg.text == text && msg.isUser == isUser);

          if (!isDuplicate) {
            _chatMessages.add(ChatMessage(text: text, isUser: isUser));
            logger
                .i('Added chat message: ${isUser ? "USER" : "GEMINI"}: $text');
          }
        });
        return true;
      }));

      // Register with the bridge
      js_util.callMethod(js.context, 'eval', [
        'window.flutterBridge.registerCallback("onChatMessage", function(text, isUser) { return window.onChatMessage(text, isUser); })'
      ]);

      // Register the callback with the bridge
      js_util.callMethod(js.context, 'eval',
          ['window.flutterBridge.registerChatCallback("onChatMessage")']);

      logger.i('Chat callback registered');
    } catch (e) {
      logger.e('Error registering chat callback: $e');
    }
  }

  // Check WebSocket connection status
  void _checkConnectionStatus(Timer timer) {
    if (!kIsWeb) return;

    try {
      final isConnected = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.isWebSocketConnected()']);

      setState(() {
        _webSocketConnected = isConnected == true;
      });
    } catch (e) {
      logger.e('Error checking connection status: $e');
    }
  }

  // Activate Flutter UI
  void _activateFlutterUI() {
    if (!kIsWeb) return;

    logger.i('Starting Flutter UI activation');
    try {
      // Make sure video element is ready
      if (!_webcamViewRegistered) {
        logger.i('Video element not registered, setting up');
        _setupVideoElement();
      }

      // Add debug statement to console to track progress
      js_util.callMethod(js.context, 'eval',
          ['console.log("Activating Flutter UI from Dart")']);

      // Make video element visible
      if (_videoElement != null) {
        _videoElement!.style.display = 'block';
        logger.i('Made video element visible');
      } else {
        logger.e('Video element not found!');
      }

      // Handle UI transition via JS bridge
      final result = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.activateFlutterUI()']);

      if (result == true) {
        setState(() {
          _usingFlutterUI = true;
        });

        // Force refresh the connection status
        _updateConnectionStatus();

        logger.i('Flutter UI activated successfully');
      } else {
        logger.e('Failed to activate Flutter UI');
      }
    } catch (e) {
      logger.e('Error activating Flutter UI: $e');
      // Add debug output to console
      js_util.callMethod(js.context, 'eval', [
        'console.error("Error activating Flutter UI:", ${jsonEncode(e.toString())})'
      ]);
    }
  }

  // Update connection status immediately without timer
  void _updateConnectionStatus() {
    if (!kIsWeb) return;

    try {
      final isConnected = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.isWebSocketConnected()']);

      setState(() {
        _webSocketConnected = isConnected == true;
      });
    } catch (e) {
      logger.e('Error checking connection status: $e');
    }
  }

  // Start recording using JS bridge
  void _startRecording() {
    if (!kIsWeb || _isRecording) return;

    try {
      final result = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.startAudioRecording()']);

      if (result == true) {
        setState(() {
          _isRecording = true;
        });
        logger.i('Started audio recording via JS bridge');
      }
    } catch (e) {
      logger.e('Error starting recording: $e');
    }
  }

  // Stop recording using JS bridge
  void _stopRecording() {
    if (!kIsWeb || !_isRecording) return;

    try {
      final result = js_util.callMethod(
          js.context, 'eval', ['window.flutterBridge.stopAudioRecording()']);

      if (result == true) {
        setState(() {
          _isRecording = false;
        });
        logger.i('Stopped audio recording via JS bridge');
      }
    } catch (e) {
      logger.e('Error stopping recording: $e');
    }
  }

  // Add a user message to the chat
  void _addUserMessage(String text) {
    setState(() {
      _chatMessages.add(ChatMessage(text: text, isUser: true));
    });
  }

  // Send a text message to Gemini
  void _sendTextMessage(String text) {
    if (!kIsWeb || text.isEmpty) return;

    try {
      // First add to chat UI
      _addUserMessage(text);

      // Send to Gemini via JS bridge
      final result = js_util.callMethod(js.context, 'eval',
          ['window.flutterBridge.sendTextMessage(${jsonEncode(text)})']);

      if (result != true) {
        logger.e('Failed to send message through JS bridge');
      } else {
        logger.i('Sent text message: $text');
      }
    } catch (e) {
      logger.e('Error sending text message: $e');
    }
  }

  @override
  void dispose() {
    _webSocket?.close();
    _videoElement?.remove();
    _canvasElement?.remove();
    _audioChunkTimer?.cancel();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Live Demo')
            .animate()
            .fadeIn(duration: 500.ms)
            .shimmer(duration: 1200.ms, color: Colors.white.withAlpha(204)),
        backgroundColor: Colors.indigo,
        actions: [
          Chip(
            label: Text(
              _webSocketConnected ? 'Connected' : 'Disconnected',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: _webSocketConnected ? Colors.green : Colors.red,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ).animate(target: _webSocketConnected ? 1 : 0).custom(
                duration: 400.ms,
                builder: (context, value, child) => Container(
                  decoration: BoxDecoration(
                    boxShadow: [
                      BoxShadow(
                        color: (_webSocketConnected ? Colors.green : Colors.red)
                            .withAlpha((0.3 * value * 255).toInt()),
                        blurRadius: 8 * value,
                        spreadRadius: 2 * value,
                      ),
                    ],
                  ),
                  child: child,
                ),
              ),
          const SizedBox(width: 16),
          if (!_usingFlutterUI)
            TextButton.icon(
              onPressed: _activateFlutterUI,
              icon: const Icon(Icons.swap_horiz, color: Colors.white),
              label: const Text('Switch to Flutter UI',
                  style: TextStyle(color: Colors.white)),
            ).animate().fadeIn(delay: 300.ms).scale(delay: 300.ms),
        ],
      ),
      body: !_usingFlutterUI
          ? Center(
              child: const Text(
                'Click "Switch to Flutter UI" to activate the Flutter interface',
              ).animate().fadeIn(duration: 600.ms).scale(delay: 200.ms),
            )
          : Column(
              children: [
                // Video feed container
                Container(
                  height: 320,
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  child: Center(
                    child: HtmlElementView(viewType: 'videoElement'),
                  ).animate().fadeIn(duration: 800.ms).moveY(
                      begin: -20, duration: 600.ms, curve: Curves.easeOutQuad),
                ),

                // Chat messages
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    child: ListView.builder(
                      itemCount: _chatMessages.length,
                      itemBuilder: (context, index) {
                        final message = _chatMessages[index];
                        return ChatBubble(message: message);
                      },
                    ),
                  ),
                ),

                // Controls
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      // Text input field
                      Container(
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: TextField(
                                  controller: _textController,
                                  decoration: const InputDecoration(
                                    hintText: 'Type a message...',
                                    border: InputBorder.none,
                                  ),
                                  onSubmitted: (text) {
                                    if (text.isNotEmpty) {
                                      _sendTextMessage(text);
                                    }
                                  },
                                ),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.send),
                              onPressed: () {
                                final text = _textController.text;
                                if (text.isNotEmpty) {
                                  _sendTextMessage(text);
                                  _textController.clear();
                                }
                              },
                            ),
                          ],
                        ),
                      ).animate().fadeIn(delay: 400.ms, duration: 800.ms).moveY(
                          begin: 20,
                          duration: 600.ms,
                          curve: Curves.easeOutQuad),

                      // Mic control buttons
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          FloatingActionButton(
                            onPressed: _isRecording ? null : _startRecording,
                            backgroundColor:
                                _isRecording ? Colors.grey : Colors.indigo,
                            child: const Icon(Icons.mic),
                          )
                              .animate(target: _isRecording ? 1 : 0)
                              .scaleXY(end: 0.9, duration: 300.ms)
                              .animate()
                              .fadeIn(delay: 300.ms, duration: 500.ms),
                          const SizedBox(width: 16),
                          FloatingActionButton(
                            onPressed: _isRecording ? _stopRecording : null,
                            backgroundColor: _isRecording
                                ? const Color.fromARGB(255, 218, 49, 37)
                                : Colors.grey,
                            child: const Icon(Icons.mic_off),
                          )
                              .animate(target: _isRecording ? 1 : 0)
                              .scaleXY(begin: 0.9, end: 1.0, duration: 300.ms)
                              .custom(
                                duration: 1000.ms,
                                curve: Curves.easeInOut,
                                builder: (context, value, child) => _isRecording
                                    ? Container(
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.red.withAlpha((0.5 *
                                                      (0.5 +
                                                          math.sin(value *
                                                                  math.pi *
                                                                  2) /
                                                              2) *
                                                      255)
                                                  .toInt()),
                                              blurRadius: 12,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: child,
                                      )
                                    : child!,
                              )
                              .animate()
                              .fadeIn(delay: 450.ms, duration: 500.ms),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ).animate().fadeIn(duration: 800.ms),
    );
  }
}

// Chat message data class
class ChatMessage {
  final String text;
  final bool isUser;

  ChatMessage({required this.text, required this.isUser});
}

// Chat bubble widget
class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: message.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: message.isUser ? Colors.indigo : Colors.grey[300],
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: message.isUser ? Colors.white : Colors.black,
          ),
        ),
      )
          .animate()
          .scale(
              begin: const Offset(0.8, 0.8),
              duration: 300.ms,
              curve: Curves.easeOutBack)
          .fade(duration: 300.ms)
          .slide(
              begin: Offset(message.isUser ? 0.3 : -0.3, 0), duration: 300.ms),
    );
  }
}
