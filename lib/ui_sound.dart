import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局 UI 音效：底部菜单点击音（水泡爆破音）。
class UiSound {
  UiSound._();
  static final UiSound instance = UiSound._();

  /// 设置页「菜单音效」开关的存储键。
  static const _enabledKey = 'menu_click_sound';

  bool _enabled = true;
  bool _enabledLoaded = false;

  AudioPool? _pool;
  Future<void>? _init;

  /// 菜单音效是否开启（默认开启）。
  Future<bool> isEnabled() async {
    await _loadEnabled();
    return _enabled;
  }

  Future<void> _loadEnabled() async {
    if (_enabledLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_enabledKey) ?? true;
    _enabledLoaded = true;
  }

  /// 开关存入本地，即时生效。
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _enabledLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  /// 预热：提前拷贝资源并创建播放器，保证首次点击立即有声音。
  Future<void> warmup() async {
    await _ensure();
  }

  Future<void> _ensure() async {
    if (_pool != null) return;
    _init ??= _build();
    await _init;
  }

  Future<void> _build() async {
    try {
      _pool = await AudioPool.createFromAsset(
        // 低延迟模式：Android 用 SoundPool，适合短促、可连点的 UI 音效。
        path: 'sounds/ui_click.wav',
        minPlayers: 1,
        maxPlayers: 4,
        playerMode: PlayerMode.lowLatency,
      );
    } catch (_) {
      _init = null;
    }
  }

  /// 播放水泡点击音；仅在开启时播放，失败时静默忽略。
  Future<void> playClick() async {
    await _loadEnabled();
    if (!_enabled) return;
    await _ensure();
    try {
      // 音量压低到 25%，避免点击音过响。
      await _pool?.start(volume: 0.0625);
    } catch (_) {}
  }
}