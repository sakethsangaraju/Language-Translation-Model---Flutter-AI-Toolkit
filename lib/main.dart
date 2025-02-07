import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

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
  String? responseText;
  String? imageUrl;

  final String serverAddress =
      'http://localhost:8008'; // ========================================Change this to the server address when needed ================================================================

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() {
      // Clear the response when switching tabs.
      if (_tabController.indexIsChanging) {
        setState(() {
          responseText = null;
          imageUrl = null;
        });
      }
    });
  }

  @override
  void dispose() {
    _textController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  // Send text to the /echo endpoint.
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
        // Assuming your echo server returns { "echo": "your text" }
        final data = jsonDecode(response.body);
        setState(() {
          responseText = data['echo'];
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
      // Read the file as bytes
      final bytes = await pickedFile.readAsBytes();

      // Create the multipart request using fromBytes instead of fromPath
      var request =
          http.MultipartRequest('POST', Uri.parse('$serverAddress/upload'));
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename:
              pickedFile.name, // You can also specify contentType if needed
        ),
      );

      // Send the request and get response
      var streamedResponse = await request.send();
      var response = await http.Response.fromStream(streamedResponse);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          imageUrl =
              data['url']; // Assuming the server returns the URL under 'url'
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

  Widget _buildLoading() {
    return const Center(child: CircularProgressIndicator());
  }

  Widget _buildResponseDisplay() {
    if (responseText != null) {
      return Text(
        // =========================================== Response Display ===============================================
        responseText!,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      ).animate().fadeIn(duration: 500.ms);
    } else if (imageUrl != null) {
      return Image.network(imageUrl!, fit: BoxFit.contain)
          .animate()
          .fadeIn(duration: 500.ms);
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
            Tab(text: 'Text'),
            Tab(text: 'Image'),
          ],
        ),
      ),
      body: isLoading
          ? _buildLoading()
          : TabBarView(
              controller: _tabController,
              children: [
                Padding(
                  // =============================================== Text Tab =================================================
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
                      ElevatedButton(
                        onPressed: sendText,
                        child: const Text('Send Text'),
                      ),
                      const SizedBox(height: 20),
                      _buildResponseDisplay(),
                    ],
                  ),
                ),
                Padding(
                  // ================================================ Image Upload Tab ===============================================
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
              ],
            ),
    );
  }
}
