/// A book in the public library: one EPUB file in the library bucket.
///
/// There is no catalog yet, so everything shown comes from the object itself.
class LibraryBook {
  /// The object's path in the bucket, which is also how it is downloaded.
  final String path;
  final int? sizeBytes;

  const LibraryBook({required this.path, this.sizeBytes});

  String get fileName => path.split('/').last;

  /// The file name is the title. Storage keys are often written with
  /// underscores for spaces, so those read as spaces.
  String get title {
    final name = fileName;
    final withoutExtension = name.toLowerCase().endsWith('.epub')
        ? name.substring(0, name.length - '.epub'.length)
        : name;
    final title = withoutExtension.replaceAll('_', ' ').trim();
    return title.isEmpty ? name : title;
  }

  String? get sizeFormatted {
    final bytes = sizeBytes;
    if (bytes == null) return null;
    if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  bool operator ==(Object other) =>
      other is LibraryBook &&
      other.path == path &&
      other.sizeBytes == sizeBytes;

  @override
  int get hashCode => Object.hash(path, sizeBytes);
}
