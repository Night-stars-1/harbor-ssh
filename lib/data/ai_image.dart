import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'terminal_ai.dart';

/// Validated, in-memory attachment. Images are never added to cloud sync.
class AiImage {
  AiImage._(this.name, this.mimeType, this.bytes);

  static const maxCount = 4;
  static const maxBytes = 5 * 1024 * 1024;
  static const maxTotalBytes = 12 * 1024 * 1024;
  final String name, mimeType;
  final Uint8List bytes;

  Map<String, Object> toContent() => {
    'type': 'image_url',
    'image_url': {'url': 'data:$mimeType;base64,${base64Encode(bytes)}'},
  };

  static void validateBatch(List<AiImage> images) {
    if (images.length > maxCount) throw const AiFailure('每条消息最多添加 4 张图片');
    if (images.fold<int>(0, (sum, image) => sum + image.bytes.length) >
        maxTotalBytes) {
      throw const AiFailure('图片总大小不能超过 12 MB');
    }
  }

  static Future<AiImage> fromStream(
    String name,
    Stream<List<int>> stream,
  ) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      if (builder.length + chunk.length > maxBytes) {
        throw const AiFailure('单张图片不能超过 5 MB');
      }
      builder.add(chunk);
    }
    return fromBytes(name, builder.takeBytes());
  }

  static Future<AiImage> fromBytes(String name, Uint8List bytes) async {
    if (bytes.length > maxBytes) throw const AiFailure('单张图片不能超过 5 MB');
    bool starts(List<int> signature, [int offset = 0]) =>
        bytes.length >= offset + signature.length &&
        Iterable<int>.generate(signature.length)
            .every((i) => bytes[i + offset] == signature[i]);
    final mime = starts([137, 80, 78, 71, 13, 10, 26, 10])
        ? 'image/png'
        : starts([255, 216, 255])
        ? 'image/jpeg'
        : starts(ascii.encode('RIFF')) && starts(ascii.encode('WEBP'), 8)
        ? 'image/webp'
        : starts(ascii.encode('GIF87a')) || starts(ascii.encode('GIF89a'))
        ? 'image/gif'
        : null;
    if (mime == null) throw const AiFailure('请选择 PNG、JPEG、WebP 或静态 GIF 图片');
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      if (descriptor.width > 8000 ||
          descriptor.height > 8000 ||
          descriptor.width * descriptor.height > 32000000) {
        throw const AiFailure('图片尺寸过大，请缩小到 8000 × 8000 以内且不超过 3200 万像素');
      }
      final scale = math.min(
        1.0,
        64 / math.max(descriptor.width, descriptor.height),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (descriptor.width * scale).round()),
        targetHeight: math.max(1, (descriptor.height * scale).round()),
      );
      if (codec.frameCount > 1) throw const AiFailure('暂不支持动态图，请选择静态图片');
      final frame = await codec.getNextFrame();
      frame.image.dispose();
      return AiImage._(
        name,
        mime,
        Uint8List.fromList(bytes).asUnmodifiableView(),
      );
    } on AiFailure {
      rethrow;
    } catch (_) {
      throw const AiFailure('无法读取图片，文件可能已损坏');
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
