import 'dart:io';

import 'package:image_picker/image_picker.dart';

import 'receipt_service.dart';

class ReceiptPhotoPicker {
  ReceiptPhotoPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  Future<ReceiptPhoto?> pick(ImageSource source) async {
    final file = await _picker.pickImage(source: source, imageQuality: 94,
        maxWidth: 2400, maxHeight: 3200, requestFullMetadata: false);
    return file == null ? null : ReceiptPhoto(await file.readAsBytes(), file.name);
  }

  Future<ReceiptPhoto?> recover() async {
    if (!Platform.isAndroid) return null;
    final result = await _picker.retrieveLostData();
    if (result.isEmpty || result.files == null || result.files!.isEmpty) return null;
    final file = result.files!.first;
    return ReceiptPhoto(await file.readAsBytes(), file.name);
  }
}
