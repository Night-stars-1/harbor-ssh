import 'dart:convert';

import 'package:file_picker/file_picker.dart';

Future<String?> pickUtf8File() async {
  final file = await FilePicker.pickFile();
  if (file == null) return null;
  return utf8.decode(await file.readAsBytes());
}
