import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'dart:developer' as dev;
import 'package:logging/logging.dart';
import 'package:flutter/foundation.dart';
import 'home_page.dart';

void main() async {
  // Make main async
  // Optional: Configure logging for flutter_soloud
  Logger.root.level = kDebugMode ? Level.FINE : Level.INFO;
  Logger.root.onRecord.listen((record) {
    dev.log(
      record.message,
      time: record.time,
      level: record.level.value,
      name: record.loggerName,
      zone: record.zone,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  });

  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SoLoud instance
  try {
    await SoLoud.instance.init();
    dev.log('SoLoud initialized successfully');
  } catch (e) {
    dev.log('Error initializing SoLoud: $e');
    // Handle initialization error if needed
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Ensure SoLoud is initialized before building HomePage
    // or handle the uninitialized state within HomePage itself.
    // The HomePage code below handles the uninitialized state.
    return const MaterialApp(home: HomePage());
  }
}
