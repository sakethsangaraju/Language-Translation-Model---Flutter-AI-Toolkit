import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:socket_io_client/socket_io_client.dart' as socketio;
import 'package:logger/logger.dart';

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
  String? responseText; // For server messages
  String? imageUrl; // For the uploaded image URL

  // For REST endpoints (change "localhost" if running on another IP)
  final String serverAddress = 'http://localhost:8008';

  // WebSocket Connection (used for the REST WebSocket tab)
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
    _tabController = TabController(length: 3, vsync: this);

    // Clear displayed data when switching tabs
    _tabController.addListener(() {
      setState(() {
        responseText = null;
        imageUrl = null;
      });
    });

    // Connect to the WebSocket server
    _socket.connect();

    _socket.on('connected', (data) {
      logger.d('WebSocket connected: $data');
    });

    // Listen for partial translation updates
    _socket.on('translation_update', (data) {
      logger.d('Translation Update: ${data['data']}');
    });

    // Listen for final translation message
    _socket.on('translation_final', (data) {
      logger.d('Translation Final: ${data['data']}');
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
          // Combine 'message' and 'echo' from the server
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
          // Set both the message and image URL
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

  // ----------------- WebSocket: send 'translate' event -------------------
  void sendMessageWebSocket() {
    final text = _textController.text;
    if (text.isNotEmpty) {
      _socket.emit('translate', {'sessionId': 'session-123', 'text': text});
      _textController.clear();
    }
  }

  // Simple loading widget
  Widget _buildLoading() {
    return const Center(child: CircularProgressIndicator());
  }

  // Updated response display to show both text and image if available.
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
            Tab(text: 'WebSocket'),
          ],
        ),
      ),
      body: isLoading
          ? _buildLoading()
          : TabBarView(
              controller: _tabController,
              children: [
                // -------------------- Text Tab (REST) --------------------
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
                            child: const Text('Send (WebSocket)'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _buildResponseDisplay(),
                    ],
                  ),
                ),

                // -------------------- Image Upload Tab (REST) --------------------
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

                // -------------------- WebSocket Tab --------------------
                const GeminiWebSocket(),
              ],
            ),
    );
  }
}

// WebSocket widget for real-time "Gemini" mock translation
class GeminiWebSocket extends StatefulWidget {
  const GeminiWebSocket({super.key});
  @override
  GeminiWebSocketState createState() => GeminiWebSocketState();
}

class GeminiWebSocketState extends State<GeminiWebSocket> {
  late socketio.Socket socket;
  final TextEditingController _controller = TextEditingController();
  final Logger logger = Logger();
  late final StreamController<String> translationStreamController;

  @override
  void initState() {
    super.initState();
    translationStreamController = StreamController<String>();

    // Connect to the WebSocket server
    socket = socketio.io('http://localhost:8008', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false,
    });
    socket.connect();

    socket.on('connected', (data) {
      logger.d('WebSocket connected: $data');
    });

    // Listen for partial translation updates
    socket.on('translation_update', (data) {
      String update = 'Partial: ${data['data']}';
      translationStreamController.add(update);
    });

    // Listen for final translation update
    socket.on('translation_final', (data) {
      String finalMsg = 'Final: ${data['data']}';
      translationStreamController.add(finalMsg);
    });
  }

  void sendTranslationRequest() {
    final text = _controller.text;
    if (text.isNotEmpty) {
      socket.emit('translate', {'sessionId': 'session-123', 'text': text});
      _controller.clear();
    }
  }

  @override
  void dispose() {
    socket.dispose();
    _controller.dispose();
    translationStreamController.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _controller,
              decoration: const InputDecoration(
                  labelText: 'Enter text for translation'),
            ),
            ElevatedButton(
              onPressed: sendTranslationRequest,
              child: const Text('Send Translation Request'),
            ),
            const SizedBox(height: 20),
            Expanded(
              child: StreamBuilder<String>(
                stream: translationStreamController.stream,
                builder: (context, snapshot) {
                  return Text(
                    snapshot.hasData ? snapshot.data! : '',
                    style: const TextStyle(fontSize: 16),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
