import 'package:file_picker/file_picker.dart';
import 'package:pasteboard/pasteboard.dart';

import 'ai_image.dart';

class AiImageSource {
  const AiImageSource(this.name, this.openRead);
  final String name;
  final Stream<List<int>> Function() openRead;
  Future<AiImage> read() => AiImage.fromStream(name, openRead());
}

abstract interface class AiImageInput {
  Future<List<AiImageSource>> pick();
  Future<AiImage?> clipboard();
}

class NativeAiImageInput implements AiImageInput {
  const NativeAiImageInput();

  @override
  Future<List<AiImageSource>> pick() async {
    final files = await FilePicker.pickFiles(
      dialogTitle: '选择图片',
      type: FileType.custom,
      allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
    );
    return [
      for (final file in files) AiImageSource(file.name, file.readAsByteStream),
    ];
  }

  @override
  Future<AiImage?> clipboard() async {
    final bytes = await Pasteboard.image;
    return bytes == null ? null : AiImage.fromBytes('剪贴板图片', bytes);
  }
}
