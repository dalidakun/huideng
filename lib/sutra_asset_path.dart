/// Helpers for resolving sutra text file paths packaged as Flutter assets.
///
/// This app historically used a different assets root folder name. To keep
/// backward compatibility (e.g. for saved preferences), we normalize legacy
/// paths to the current `assets/sutras/...` layout.
class SutraAssetPath {
  // IMPORTANT:
  // Android APK assets inside a ZIP can be problematic with non-ASCII filenames
  // (encoding/flags). To make loading reliable, we package sutras under an
  // ASCII-only path and filename scheme:
  //   assets/sutras_ascii/T01/T01n0031_001.txt
  static const String currentRoot = 'assets/sutras_ascii/';
  static const String legacyRoot = 'assets/大正藏经简体txt/';
  // Support canonical IDs including optional letter suffix after the n#### part,
  // e.g. T02n0150A_001 / T03n0181a_001.
  static final RegExp _idRe = RegExp(r'(T\d{2}n\d{4}[A-Za-z]?_\d{3})');

  static String? _extractId(String? s) {
    if (s == null) return null;
    final m = _idRe.firstMatch(s);
    return m?.group(1);
  }

  static String _buildFromId(String id) {
    final vol = id.substring(0, 3); // e.g. "T01"
    return '$currentRoot$vol/$id.txt';
  }

  /// Resolve the sutra asset path to an ASCII-only packaged path.
  ///
  /// We try to extract the canonical sutra ID (e.g. "T01n0031_001") from:
  /// - [filePath] (legacy or current)
  /// - then [title]
  ///
  /// If we can find an ID, we map it to:
  ///   assets/sutras_ascii/T01/T01n0031_001.txt
  ///
  /// As a last resort, we still normalize the original path separators and
  /// return it (may fail if it contains non-ASCII chars in APK assets).
  static String resolve({
    required String title,
    String? filePath,
  }) {
    final id = _extractId(filePath) ?? _extractId(title);
    if (id != null) {
      return _buildFromId(id);
    }

    // Fallback: normalize separators and legacy root mapping (best effort).
    var p = (filePath ?? '').replaceAll('\\', '/').trim();
    if (p.startsWith(legacyRoot)) {
      // Keep relative path, but under ASCII root this likely won't exist.
      p = currentRoot + p.substring(legacyRoot.length);
    }
    return p.isEmpty ? '$currentRoot$title.txt' : p;
  }
}


