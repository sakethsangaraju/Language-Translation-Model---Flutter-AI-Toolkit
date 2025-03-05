import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:socket_io_client/socket_io_client.dart' as socketio;
import 'package:logger/logger.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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

  // REST server endpoint (update if needed—for emulators, use proper IP)
  final String serverAddress = 'http://localhost:8008';

  // Shared WebSocket connection for translation and audio streaming.
  final socketio.Socket _socket = socketio.io(
    'http://localhost:8008',
    <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    },
  );

  final Logger logger = Logger();

  @override
  void initState() {
    super.initState();
    // Three tabs: Text (REST), Image (REST), Audio (WS)
    _tabController = TabController(length: 3, vsync: this);

    // Clear displayed data when switching tabs.
    _tabController.addListener(() {
      setState(() {
        responseText = null;
        imageUrl = null;
      });
    });

    // Connect the shared WebSocket.
    _socket.connect();
    _socket.on('connected', (data) {
      logger.d('WebSocket connected: $data');
    });
    _socket.on('translation_update', (data) {
      logger.d('Translation Update: ${data['data']}');
    });
    _socket.on('translation_final', (data) {
      logger.d('Translation Final: ${data['data']}');
      setState(() {
        responseText = data['data'];
      });
    });
    _socket.on('audio_ack', (data) {
      logger.d('Audio ack: $data');
    });
    _socket.on('error', (data) {
      logger.e('Socket error: $data');
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _tabController.dispose();
    _socket.dispose();
    super.dispose();
  }

  // ----------------- REST: /echo -------------------
  Future<void> sendText() async {
    final text = _textController.text;
    if (text.isEmpty) return;
    setState(() {
      isLoading = true;
      responseText = null;
      imageUrl = null;
    });
    try {
      final response = await http.post(
        Uri.parse('$serverAddress/echo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'text': text}),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          responseText = "${data['message']} (Echo: ${data['echo']})";
        });
      } else {
        setState(() {
          responseText = 'Error: ${response.reasonPhrase}';
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
    final XFile? pickedFile =
        await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;
    setState(() {
      isLoading = true;
      responseText = null;
      imageUrl = null;
    });
    try {
      final bytes = await pickedFile.readAsBytes();
      var request =
          http.MultipartRequest('POST', Uri.parse('$serverAddress/upload'));
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: pickedFile.name,
        ),
      );
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          responseText = data['message'];
          imageUrl = data['url'];
        });
      } else {
        setState(() {
          responseText = 'Error: ${response.reasonPhrase}';
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
  void sendMessageWebSocket() {
    final text = _textController.text;
    if (text.isNotEmpty) {
      _socket.emit('translate', {
        'sessionId': 'session-${DateTime.now().millisecondsSinceEpoch}',
        'text': text
      });
      _textController.clear();
    }
  }

  // Simple loading widget.
  Widget _buildLoading() {
    return const Center(child: CircularProgressIndicator());
  }

  // Display responses (text and/or image).
  Widget _buildResponseDisplay() {
    if (responseText != null || imageUrl != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (responseText != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                responseText!,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          if (imageUrl != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Image.network(imageUrl!, fit: BoxFit.contain),
            ),
        ],
      ).animate().fadeIn(duration: 500.ms);
    }
    return const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Echo App'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Text (REST)'),
            Tab(text: 'Image (REST)'),
            Tab(text: 'Audio (WS)'),
          ],
        ),
      ),
      body: isLoading
          ? _buildLoading()
          : TabBarView(
              controller: _tabController,
              children: [
                // Text Tab (REST)
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
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          ElevatedButton(
                            onPressed: sendText,
                            child: const Text('Send Text (REST)'),
                          ),
                          ElevatedButton(
                            onPressed: sendMessageWebSocket,
                            child: const Text('Translate (WS)'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildResponseDisplay(),
                    ],
                  ),
                ),
                // Image Upload Tab (REST)
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      ElevatedButton(
                        onPressed: sendImage,
                        child: const Text('Upload Image'),
                      ),
                      const SizedBox(height: 20),
                      _buildResponseDisplay(),
                    ],
                  ),
                ),
                // Audio Streaming Tab (WS)
                AudioStreamWidget(sharedSocket: _socket),
              ],
            ),
    );
  }
}

// AudioStreamWidget: Handles audio recording and streaming via the shared WebSocket.
class AudioStreamWidget extends StatefulWidget {
  final socketio.Socket? sharedSocket;
  const AudioStreamWidget({super.key, this.sharedSocket});
  @override
  _AudioStreamWidgetState createState() => _AudioStreamWidgetState();
}

class _AudioStreamWidgetState extends State<AudioStreamWidget> {
  late socketio.Socket _audioSocket;
  MediaStream? _mediaStream;
  bool _isRecording = false;
  Timer? _audioTimer;
  final Logger logger = Logger();
  String _audioAckMessage = ""; // New state variable to store the ack message

  @override
  void initState() {
    super.initState();
    _audioSocket = widget.sharedSocket ??
        socketio.io('http://localhost:8008', <String, dynamic>{
          'transports': ['websocket'],
          'autoConnect': false,
        });
    if (widget.sharedSocket == null) {
      _audioSocket.connect();
    }
    _audioSocket.on('audio_ack', (data) {
      logger.d('Audio ack: $data');
      setState(() {
        _audioAckMessage = data['message'] ?? "";
      });
    });
  }

  @override
  void dispose() {
    _mediaStream?.dispose();
    _audioTimer?.cancel();
    if (widget.sharedSocket == null) {
      _audioSocket.dispose();
    }
    super.dispose();
  }

  Future<void> _startRecording() async {
    final Map<String, dynamic> mediaConstraints = {
      'audio': true,
      'video': false,
    };

    try {
      _mediaStream =
          await navigator.mediaDevices.getUserMedia(mediaConstraints);
      setState(() {
        _isRecording = true;
      });
      logger.d('Audio recording started.');

      _audioTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
        int chunkSize = 100 + Random().nextInt(50);
        List<int> randomBytes =
            List.generate(chunkSize, (_) => Random().nextInt(256));
        String audioBase64 = base64Encode(randomBytes);
        _audioSocket.emit('audio_stream', {
          'sessionId': 'session-${DateTime.now().millisecondsSinceEpoch}',
          'data': audioBase64,
        });
        logger.d('Sent audio chunk of $chunkSize bytes');
      });
    } catch (e) {
      logger.e('Error starting audio capture: $e');
    }
  }

  void _stopRecording() {
    _audioTimer?.cancel();
    _audioTimer = null;
    _mediaStream?.getAudioTracks().forEach((track) {
      track.stop();
    });
    _mediaStream = null;
    setState(() {
      _isRecording = false;
    });
    String finalMessage = 'audio_stream_ended';
    String finalBase64 = base64Encode(utf8.encode(finalMessage));
    _audioSocket.emit('audio_stream', {
      'sessionId': 'session-${DateTime.now().millisecondsSinceEpoch}',
      'data': finalBase64,
    });
    logger.d('Audio recording stopped. Sent final message.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Audio Streaming'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(_isRecording ? 'Recording audio...' : 'Not Recording'),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : _startRecording,
              child: Text(_isRecording ? 'Stop Recording' : 'Start Recording'),
            ),
            const SizedBox(height: 20),
            if (_audioAckMessage.isNotEmpty)
              Text('Ack: $_audioAckMessage',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
