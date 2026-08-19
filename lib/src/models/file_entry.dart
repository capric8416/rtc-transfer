class FileEntry {
  const FileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.size,
    this.modifiedMillis,
  });

  final String name;
  final String relativePath;
  final bool isDirectory;
  final int size;
  final int? modifiedMillis;

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: json['name'] as String,
    relativePath: json['path'] as String,
    isDirectory: json['directory'] as bool,
    size: (json['size'] as num).toInt(),
    modifiedMillis: (json['modified'] as num?)?.toInt(),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'path': relativePath,
    'directory': isDirectory,
    'size': size,
    if (modifiedMillis != null) 'modified': modifiedMillis,
  };
}
