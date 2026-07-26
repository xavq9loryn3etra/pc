import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'saved_movies_service.dart';
import 'app_mode_service.dart';

class BackupService {
  static final BackupService _instance = BackupService._internal();
  factory BackupService() => _instance;
  BackupService._internal();

  Future<bool> exportData() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      final Map<String, dynamic> allData = {};

      for (String key in keys) {
        allData[key] = prefs.get(key);
      }

      final jsonString = jsonEncode(allData);
      final bytes = Uint8List.fromList(utf8.encode(jsonString));
      
      // Select location to save and write bytes
      String? outputPath = await FilePicker.saveFile(
        dialogTitle: 'Export Backup',
        fileName: 'popcorn_backup.json',
        type: FileType.custom,
        allowedExtensions: ['json'],
        bytes: bytes,
      );

      return outputPath != null;
    } catch (e) {
      print("Export error: $e");
      return false;
    }
  }

  Future<bool> importData() async {
    try {
      FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) return false;

      final file = File(result.files.single.path!);
      final jsonString = await file.readAsString();
      final Map<String, dynamic> data = jsonDecode(jsonString);

      final prefs = await SharedPreferences.getInstance();
      // Clear existing to avoid mix
      await prefs.clear();

      for (String key in data.keys) {
        final value = data[key];
        if (value is String) {
          await prefs.setString(key, value);
        } else if (value is int) {
          await prefs.setInt(key, value);
        } else if (value is double) {
          await prefs.setDouble(key, value);
        } else if (value is bool) {
          await prefs.setBool(key, value);
        } else if (value is List) {
          // SharedPreferences stores StringList for List types
          await prefs.setStringList(key, List<String>.from(value));
        }
      }

      // Re-init services to reflect new data in memory
      await SavedMoviesService().init();
      await AppModeService().init();
      
      return true;
    } catch (e) {
      print("Import error: $e");
      return false;
    }
  }
}
