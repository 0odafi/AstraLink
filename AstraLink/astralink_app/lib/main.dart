import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
export 'src/app.dart' show AstraMessengerApp;

void main() {
  runApp(const ProviderScope(child: AstraMessengerApp()));
}
