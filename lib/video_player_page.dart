import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'video_catalog.dart';
import 'video_download_store.dart';

/// 全屏视频播放页：黑底 + 自定义控制层（进度拖动、倍速、清晰度、横屏全屏）。
///
/// 交互约定（与主流播放器一致）：
/// - 点画面：显示 / 隐藏控制层；播放中 3 秒后自动隐藏。
/// - 中间大按钮：播放 / 暂停；两侧 10 秒快退 / 快进。
/// - 底部：进度条、当前时间 / 总时长、倍速、全屏。
/// - 顶部：返回、标题、清晰度（多档时才显示）、在浏览器打开。
/// - 退出时记住播放位置，下次进来接着看；播放期间保持屏幕常亮。
class VideoPlayerPage extends StatefulWidget {
  final VideoItem video;
  final VideoSource? initialSource;

  const VideoPlayerPage({
    super.key,
    required this.video,
    this.initialSource,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  VideoSource? _source;

  bool _loading = true;
  String? _error;

  /// 正在「先下载再播」：加载层显示下载进度而不是缓冲动画。
  bool _downloading = false;

  /// 手动模式：网盘分享页 + 用户自己下载分片，App 只负责导入合并。
  bool _manual = false;
  bool _merging = false;
  String? _mergeError;

  /// 起播超过 5 秒还没出来：提示换成「网络较慢」，避免用户以为卡死。
  bool _slowLoading = false;
  Timer? _slowTimer;

  /// 控制层是否可见（点画面切换，播放中自动隐藏）。
  bool _controlsVisible = true;
  Timer? _hideTimer;

  /// 定时把播放进度写进本地（防止被杀进程丢掉进度）。
  Timer? _saveTimer;

  bool _fullscreen = false;
  double _speed = 1.0;

  /// 拖动进度条时的临时值（毫秒），松手才真正 seek。
  double? _dragValue;

  bool _resumeToastShown = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _source = widget.initialSource ?? widget.video.defaultSource;
    unawaited(_open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _saveTimer?.cancel();
    _slowTimer?.cancel();
    // 先把当前进度按值抓出来，再清空 controller：
    // _persistPosition 内部有 await，晚一步读 _controller 就拿到 null 了。
    final c = _controller;
    if (c != null) {
      unawaited(_persistPosition(
        c.value.position.inMilliseconds,
        c.value.duration.inMilliseconds,
      ));
    }
    _controller = null;
    c?.removeListener(_onValueChanged);
    unawaited(c?.dispose());
    unawaited(WakelockPlus.disable());
    unawaited(_restoreSystemChrome());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      final c = _controller;
      if (c != null && c.value.isPlaying) {
        unawaited(c.pause());
        unawaited(WakelockPlus.disable());
        unawaited(_savePosition());
      }
    }
  }

  // ───────────────────────── 播放器生命周期 ─────────────────────────

  Future<void> _open() async {
    // 手动模式：用户自己在蓝奏云下载分片，App 只负责导入合并。
    if (widget.video.manualDownload) {
      final local =
          await VideoDownloadStore.instance.localFile(widget.video.id);
      if (!mounted) return;
      if (local != null) {
        await _playLocal(local);
      } else {
        setState(() {
          _manual = true;
          _loading = false;
          _downloading = false;
          _error = null;
        });
      }
      return;
    }

    // 直链/分片模式：本地有文件直接播；没有就自动下载，下完再播。
    if (widget.video.downloadFirst) {
      final local = await VideoDownloadStore.instance.localFile(widget.video.id);
      if (!mounted) return;
      if (local != null) {
        await _playLocal(local);
      } else {
        await _downloadThenPlay();
      }
      return;
    }

    final source = _source;
    if (source == null) {
      setState(() {
        _loading = false;
        _error = '这部视频还没有可播放的源';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _downloading = false;
    });
    _startSlowTimer();

    await _disposeController();
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(source.url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );
    await _attachController(controller);
  }

  /// 先下载到本地，再播本地文件。
  Future<void> _downloadThenPlay() async {
    final store = VideoDownloadStore.instance;
    final id = widget.video.id;
    setState(() {
      _loading = true;
      _downloading = true;
      _error = null;
    });
    _slowTimer?.cancel();
    // 下载期间保持屏幕常亮，避免息屏把下载挂起。
    unawaited(WakelockPlus.enable());
    await store.download(widget.video);
    // 如果已经有别的页面在下载这部，等它结束。
    var guard = 0;
    while (mounted && store.isDownloading(id) && guard < 7200) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      guard++;
    }
    unawaited(WakelockPlus.disable());
    if (!mounted) return;
    final local = await store.localFile(id);
    if (local != null) {
      await _playLocal(local);
      return;
    }
    final task = store.taskOf(id);
    setState(() {
      _loading = false;
      _downloading = false;
      _error = task.error ?? '下载失败，请重试';
    });
  }

  /// 播本地文件。
  Future<void> _playLocal(File file) async {
    setState(() {
      _loading = true;
      _downloading = false;
      _error = null;
    });
    _startSlowTimer();
    await _disposeController();
    final controller = VideoPlayerController.file(file);
    await _attachController(controller);
  }

  Future<void> _disposeController() async {
    final old = _controller;
    _controller = null;
    if (old != null) {
      old.removeListener(_onValueChanged);
      await old.dispose();
    }
  }

  /// 初始化 controller（网络 / 本地共用）：续播、倍速、开播、挂监听。
  Future<void> _attachController(VideoPlayerController controller) async {
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setPlaybackSpeed(_speed);

      // 续播：上次看到一半才跳过去，快看完的从头开始。
      final saved = await _loadSavedPosition();
      final total = controller.value.duration;
      if (saved > const Duration(seconds: 5) &&
          total > const Duration(seconds: 30) &&
          saved < total - const Duration(seconds: 10)) {
        await controller.seekTo(saved);
        _showResumeToast(saved);
      }

      await controller.play();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      controller.addListener(_onValueChanged);
      _slowTimer?.cancel();
      setState(() {
        _controller = controller;
        _loading = false;
        _downloading = false;
        _controlsVisible = true;
      });
      _scheduleHide();
      _startSaveTimer();
      unawaited(WakelockPlus.enable());
    } catch (e) {
      await controller.dispose();
      _slowTimer?.cancel();
      if (!mounted) return;
      setState(() {
        _loading = false;
        _downloading = false;
        _slowLoading = false;
        _error = _friendlyError(e);
      });
    }
  }

  /// 起播超过 5 秒还没出来，把提示换成「网络较慢」。
  void _startSlowTimer() {
    _slowTimer?.cancel();
    _slowLoading = false;
    _slowTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _loading) setState(() => _slowLoading = true);
    });
  }

  /// 播放器状态变化：播完把进度清零并露出控制层。
  void _onValueChanged() {
    final c = _controller;
    if (c == null || !mounted) return;
    final v = c.value;
    if (v.isCompleted) {
      unawaited(WakelockPlus.disable());
      unawaited(_savePosition(forceZero: true));
      if (!_controlsVisible) setState(() => _controlsVisible = true);
    }
  }

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      final c = _controller;
      if (c != null && c.value.isPlaying) unawaited(_savePosition());
    });
  }

  Future<Duration> _loadSavedPosition() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final ms = prefs.getInt(_posKey) ?? 0;
      return Duration(milliseconds: ms);
    } catch (_) {
      return Duration.zero;
    }
  }

  String get _posKey => 'video_pos_${widget.video.id}';

  Future<void> _savePosition({bool forceZero = false}) {
    final c = _controller;
    if (forceZero) return _persistPosition(0, 0);
    if (c == null) return Future<void>.value();
    return _persistPosition(
      c.value.position.inMilliseconds,
      c.value.duration.inMilliseconds,
    );
  }

  /// 把毫秒进度写进本地：快看完的（剩不到 10 秒）直接清零，下次从头播。
  Future<void> _persistPosition(int ms, int totalMs) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ms <= 0 || (totalMs > 0 && ms >= totalMs - 10000)) {
        await prefs.setInt(_posKey, 0);
      } else if (ms > 3000) {
        await prefs.setInt(_posKey, ms);
      }
    } catch (_) {
      // 进度存不下不影响播放。
    }
  }

  void _showResumeToast(Duration at) {
    if (_resumeToastShown || !mounted) return;
    _resumeToastShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已从上次 ${formatVideoDuration(at)} 继续播放',
              style: const TextStyle(fontSize: 13)),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.black.withValues(alpha: 0.82),
          margin: const EdgeInsets.fromLTRB(40, 0, 40, 90),
        ),
      );
    });
  }

  String _friendlyError(Object e) {
    final text = '$e';
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection')) {
      return '网络连接失败，请检查网络后重试。';
    }
    if (text.contains('403')) return '视频地址无权访问（403）。';
    if (text.contains('404')) return '视频文件不存在（404）。';
    return '播放失败：$text';
  }

  // ───────────────────────── 控制层动作 ─────────────────────────

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    final c = _controller;
    if (c == null || !c.value.isPlaying) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && (_controller?.value.isPlaying ?? false)) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  Future<void> _togglePlay() async {
    final c = _controller;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
      unawaited(WakelockPlus.disable());
      _hideTimer?.cancel();
      unawaited(_savePosition());
      if (mounted) setState(() => _controlsVisible = true);
    } else {
      final total = c.value.duration;
      if (total > Duration.zero &&
          c.value.position >= total - const Duration(seconds: 2)) {
        await c.seekTo(Duration.zero);
      }
      await c.play();
      unawaited(WakelockPlus.enable());
      if (mounted) setState(() {});
      _scheduleHide();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final c = _controller;
    if (c == null) return;
    final total = c.value.duration;
    var target = c.value.position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    if (total > Duration.zero && target > total) target = total;
    await c.seekTo(target);
    _scheduleHide();
  }

  Future<void> _onSeekEnd(double ms) async {
    final c = _controller;
    if (c == null) return;
    final total = c.value.duration.inMilliseconds.toDouble();
    final target = total <= 0 ? ms : ms.clamp(0.0, total);
    await c.seekTo(Duration(milliseconds: target.round()));
    if (mounted) setState(() => _dragValue = null);
    _scheduleHide();
  }

  Future<void> _setSpeed(double speed) async {
    final c = _controller;
    if (mounted) {
      setState(() {
        _speed = speed;
        _controlsVisible = true;
      });
    }
    if (c != null) await c.setPlaybackSpeed(speed);
    _scheduleHide();
  }

  Future<void> _switchSource(VideoSource source) async {
    if (source.url == _source?.url) return;
    final c = _controller;
    final pos = c?.value.position ?? Duration.zero;
    final wasPlaying = c?.value.isPlaying ?? false;
    await _savePosition();
    // 记住位置，重开时由 _open 的续播逻辑接上。
    if (pos > const Duration(seconds: 3)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_posKey, pos.inMilliseconds);
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _source = source;
      _loading = true;
      _error = null;
    });
    await _open();
    if (!wasPlaying && mounted) {
      final next = _controller;
      if (next != null) await next.pause();
    }
  }

  Future<void> _toggleFullscreen() async {
    final next = !_fullscreen;
    setState(() {
      _fullscreen = next;
      _controlsVisible = true;
    });
    try {
      if (next) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations(const [
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await _restoreSystemChrome();
      }
    } catch (_) {
      // 某些平台（桌面 / Web）不支持方向切换，忽略即可。
    }
  }

  Future<void> _restoreSystemChrome() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    } catch (_) {}
  }

  Future<void> _openInBrowser() async {
    final url = (_source?.url.isNotEmpty ?? false)
        ? _source!.url
        : (widget.video.parts.isNotEmpty
            ? widget.video.parts.first.url
            : (widget.video.downloadUrl.isNotEmpty
                ? widget.video.downloadUrl
                : null));
    if (url == null || url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('无法打开浏览器'), duration: Duration(seconds: 2)),
      );
    }
  }

  // ───────────────────────── 视图 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_manual) return _buildManualPage();
    final c = _controller;
    return PopScope(
      canPop: !_fullscreen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _fullscreen) unawaited(_toggleFullscreen());
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 画面：黑底居中，上下留黑边（竖屏观感与主流播放器一致）。
            if (c != null && c.value.isInitialized)
              Center(
                child: AspectRatio(
                  aspectRatio: c.value.aspectRatio <= 0
                      ? 16 / 9
                      : c.value.aspectRatio,
                  child: VideoPlayer(c),
                ),
              ),
            // 点击层：点画面显示 / 隐藏控制层（放在控制层下方，不抢按钮点击）。
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
              ),
            ),
            if (_loading) _buildLoading(),
            if (_error != null) _buildError(_error!),
            if (c != null && !_loading && _error == null) ...[
              _buildTopBar(c),
              _buildCenterControls(c),
              _buildBottomBar(c),
            ],
          ],
        ),
      ),
    );
  }

  // ───────────────────── 手动模式（网盘下载 + 导入合并） ─────────────────────

  Widget _buildManualPage() {
    final v = widget.video;
    final count = v.partSizes.isNotEmpty ? v.partSizes.length : 0;
    final total = v.expectedBytes;
    return Scaffold(
      backgroundColor: const Color(0xFF111111),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back_ios_new,
                        size: 18, color: Colors.white),
                  ),
                  Expanded(
                    child: Text(
                      v.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (v.coverUrl.isNotEmpty)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: AspectRatio(
                          aspectRatio: 16 / 9,
                          child: Image.network(
                            v.coverUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const SizedBox.shrink(),
                          ),
                        ),
                      ),
                    const SizedBox(height: 20),
                    const Text(
                      '先在蓝奏云下载，再回到 App 播放',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      count > 0
                          ? '这部视频分成了 $count 个分片（每个不到 100MB）。'
                          : '这部视频分成了几个分片（每个不到 100MB）。',
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.7,
                        color: Colors.white54,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _manualStep('1', '点下面的按钮，打开蓝奏云下载页面'),
                    _manualStep('2',
                        count > 0 ? '把 $count 个 part-xxx.mp4 全部下载到手机' : '把全部分片下载到手机'),
                    _manualStep('3', '回到这里点「选择已下载的分片」，全选后 App 自动合并播放'),
                    if (total > 0) ...[
                      const SizedBox(height: 12),
                      Text(
                        '合并后约 ${_fmtBytes(total)}，请预留足够存储空间',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white30),
                      ),
                    ],
                    const SizedBox(height: 24),
                    _manualButton(
                      label: '打开蓝奏云下载页面',
                      icon: Icons.open_in_new,
                      filled: true,
                      onTap: _openSharePage,
                    ),
                    const SizedBox(height: 12),
                    _manualButton(
                      label: _merging ? '正在合并…' : '选择已下载的分片',
                      icon: Icons.video_library_outlined,
                      filled: false,
                      onTap: _merging ? null : _pickAndMerge,
                    ),
                    if (_merging) ...[
                      const SizedBox(height: 18),
                      const Center(
                        child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white54,
                          ),
                        ),
                      ),
                    ],
                    if (_mergeError != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _mergeError!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFFF8A80), height: 1.5),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _manualStep(String index, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 18,
            height: 18,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.12),
            ),
            child: Text(index,
                style: const TextStyle(
                    fontSize: 10.5, color: Colors.white70)),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                  fontSize: 12.5, height: 1.55, color: Colors.white60),
            ),
          ),
        ],
      ),
    );
  }

  Widget _manualButton({
    required String label,
    required IconData icon,
    required bool filled,
    required VoidCallback? onTap,
  }) {
    return SizedBox(
      height: 46,
      child: filled
          ? FilledButton.icon(
              onPressed: onTap,
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFF1C1C1C),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23)),
              ),
              icon: Icon(icon, size: 18),
              label: Text(label,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w600)),
            )
          : OutlinedButton.icon(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.28)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(23)),
              ),
              icon: Icon(icon, size: 18),
              label: Text(label,
                  style: const TextStyle(fontSize: 14)),
            ),
    );
  }

  Future<void> _openSharePage() async {
    final url = widget.video.shareUrl;
    if (url.isEmpty) return;
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('无法打开浏览器'), duration: Duration(seconds: 2)),
      );
    }
  }

  Future<void> _pickAndMerge() async {
    setState(() => _mergeError = null);
    try {
      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.custom,
        allowedExtensions: const ['mp4'],
      );
      if (result == null || result.files.isEmpty) return;
      final paths = result.files
          .map((f) => f.path)
          .whereType<String>()
          .toList()
        ..sort();
      final expected = widget.video.partSizes.length;
      if (expected > 0 && paths.length != expected) {
        throw Exception('需要 $expected 个分片，当前选了 ${paths.length} 个');
      }
      if (!mounted) return;
      setState(() => _merging = true);
      final file = await VideoDownloadStore.instance.mergeLocalFiles(
        widget.video.id,
        paths,
        expectedBytes: widget.video.expectedBytes,
      );
      if (!mounted) return;
      setState(() {
        _merging = false;
        _manual = false;
      });
      await _playLocal(file);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _merging = false;
        _mergeError = '$e';
      });
    }
  }

  Widget _buildLoading() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 先把封面垫在画面位置：起播这几秒看到的是海报，不是一块黑屏。
        if (widget.video.coverUrl.isNotEmpty)
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Image.network(
                widget.video.coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          ),
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.62),
          child: Center(
            child: _downloading
                ? _buildDownloadProgress()
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 30,
                        height: 30,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.2,
                          color: Colors.white70,
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        _slowLoading ? '网络较慢，正在缓冲…' : '正在加载视频…',
                        style: const TextStyle(
                            fontSize: 12.5, color: Colors.white54),
                      ),
                      if (_slowLoading) ...[
                        const SizedBox(height: 6),
                        const Text(
                          '首次播放需要几秒，之后会快很多',
                          style: TextStyle(
                              fontSize: 10.5, color: Colors.white30),
                        ),
                      ],
                    ],
                  ),
          ),
        ),
        // 加载期间也给一个返回键，避免慢网时卡在黑屏只能等。
        Positioned(
          left: 6,
          top: 6,
          child: SafeArea(
            child: IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.arrow_back_ios_new,
                  size: 18, color: Colors.white),
              tooltip: '返回',
            ),
          ),
        ),
      ],
    );
  }

  /// 下载进度：进度条 + 已下载/总量 + 速度/剩余时间 + 取消。
  Widget _buildDownloadProgress() {
    final store = VideoDownloadStore.instance;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final task = store.taskOf(widget.video.id);
        final progress = task.progress;
        final total = task.totalBytes;
        final received = task.receivedBytes;
        final speed = task.bytesPerSecond;
        final remainSeconds = speed > 0 && total > received
            ? ((total - received) / speed).ceil()
            : 0;
        return SizedBox(
          width: 252,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '首次播放会先下载到手机',
                style: TextStyle(fontSize: 13, color: Colors.white70),
              ),
              const SizedBox(height: 4),
              const Text(
                '下载完会自动播放，下次打开秒开',
                style: TextStyle(fontSize: 10.5, color: Colors.white38),
              ),
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ),
              const SizedBox(height: 9),
              Text(
                '${(progress * 100).toStringAsFixed(0)}%  ·  '
                '${_fmtBytes(received)} / ${total > 0 ? _fmtBytes(total) : '—'}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: Colors.white60,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              if (speed > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${_fmtBytes(speed.round())}/s'
                  '${remainSeconds > 0 ? '  ·  约 ${_remainLabel(remainSeconds)}' : ''}',
                  style: const TextStyle(fontSize: 10.5, color: Colors.white30),
                ),
              ],
              const SizedBox(height: 16),
              _errorButton('取消下载', () {
                VideoDownloadStore.instance.cancel(widget.video.id);
              }),
            ],
          ),
        );
      },
    );
  }

  String _fmtBytes(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _remainLabel(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final minutes = (seconds / 60).ceil();
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rest = minutes % 60;
    return '$hours 小时${rest > 0 ? ' $rest 分' : ''}';
  }

  Widget _buildError(String message) {    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 36),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  size: 40, color: Colors.white38),
              const SizedBox(height: 16),
              const Text('视频加载失败',
                  style: TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 12.5, color: Colors.white54, height: 1.6),
              ),
              const SizedBox(height: 22),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _errorButton('重试', () => unawaited(_open())),
                  _errorButton('在浏览器打开', () => unawaited(_openInBrowser())),
                  _errorButton('返回', () => Navigator.of(context).maybePop()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _errorButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.white)),
      ),
    );
  }

  Widget _buildTopBar(VideoPlayerController c) {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.72),
                  Colors.transparent,
                ],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 10, 14),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.arrow_back_ios_new,
                          size: 18, color: Colors.white),
                      tooltip: '返回',
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.video.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              letterSpacing: 0.3,
                            ),
                          ),
                          if (widget.video.subtitle.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.video.subtitle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (widget.video.sources.length > 1) _buildQualityButton(),
                    IconButton(
                      onPressed: () => unawaited(_openInBrowser()),
                      icon: const Icon(Icons.open_in_new,
                          size: 18, color: Colors.white70),
                      tooltip: '在浏览器打开',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildQualityButton() {
    final label = _source?.label ?? '清晰度';
    return PopupMenuButton<VideoSource>(
      tooltip: '切换清晰度',
      color: const Color(0xFF242424),
      onSelected: (s) => unawaited(_switchSource(s)),
      itemBuilder: (context) => [
        for (final s in widget.video.sources)
          PopupMenuItem<VideoSource>(
            value: s,
            child: Row(
              children: [
                Text(s.label,
                    style: TextStyle(
                      fontSize: 13,
                      color:
                          s.url == _source?.url ? Colors.white : Colors.white70,
                    )),
                const SizedBox(width: 8),
                if (s.url == _source?.url)
                  const Icon(Icons.check, size: 15, color: Colors.white),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: const TextStyle(fontSize: 11.5, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildCenterControls(VideoPlayerController c) {
    return ValueListenableBuilder<VideoPlayerValue>(
      valueListenable: c,
      builder: (context, value, _) {
        final playing = value.isPlaying;
        return Center(
          child: AnimatedOpacity(
            opacity: _controlsVisible ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !_controlsVisible,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _circleButton(
                    size: 44,
                    icon: Icons.replay_10_rounded,
                    onTap: () => unawaited(_seekRelative(-10)),
                  ),
                  const SizedBox(width: 28),
                  _circleButton(
                    size: 66,
                    icon:
                        playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    onTap: () => unawaited(_togglePlay()),
                  ),
                  const SizedBox(width: 28),
                  _circleButton(
                    size: 44,
                    icon: Icons.forward_10_rounded,
                    onTap: () => unawaited(_seekRelative(10)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _circleButton({
    required double size,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.42),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
        ),
        child: Icon(icon, size: size * 0.46, color: Colors.white),
      ),
    );
  }

  Widget _buildBottomBar(VideoPlayerController c) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedOpacity(
        opacity: _controlsVisible ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: IgnorePointer(
          ignoring: !_controlsVisible,
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.78),
                  Colors.transparent,
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 18, 10, 6),
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (context, value, _) {
                    final totalMs = value.duration.inMilliseconds.toDouble();
                    final posMs = value.position.inMilliseconds.toDouble();
                    final maxMs = totalMs <= 0 ? 1.0 : totalMs;
                    final valueMs = (_dragValue ?? posMs).clamp(0.0, maxMs);
                    final shown = Duration(milliseconds: valueMs.round());
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SliderTheme(
                          data: SliderThemeData(
                            trackHeight: 2.6,
                            activeTrackColor: Colors.white,
                            inactiveTrackColor:
                                Colors.white.withValues(alpha: 0.24),
                            thumbColor: Colors.white,
                            overlayColor: Colors.white.withValues(alpha: 0.12),
                            thumbShape: const RoundSliderThumbShape(
                                enabledThumbRadius: 5),
                            overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 14),
                          ),
                          child: Slider(
                            value: valueMs,
                            max: maxMs,
                            onChanged: (v) => setState(() => _dragValue = v),
                            onChangeEnd: (v) => unawaited(_onSeekEnd(v)),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 4),
                          child: Row(
                            children: [
                              Text(
                                '${formatVideoDuration(shown)} / ${formatVideoDuration(value.duration)}',
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Colors.white70,
                                  fontFeatures: [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                              if (value.isBuffering) ...[
                                const SizedBox(width: 10),
                                const SizedBox(
                                  width: 11,
                                  height: 11,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.6,
                                    color: Colors.white54,
                                  ),
                                ),
                              ],
                              const Spacer(),
                              _textButton(
                                '${_speedLabel(_speed)}x',
                                onTap: _showSpeedMenu,
                              ),
                              const SizedBox(width: 6),
                              _textButton(
                                _fullscreen ? '退出全屏' : '全屏',
                                icon: _fullscreen
                                    ? Icons.fullscreen_exit
                                    : Icons.fullscreen,
                                onTap: () => unawaited(_toggleFullscreen()),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _speedLabel(double speed) {
    if (speed == speed.roundToDouble()) return speed.toStringAsFixed(1);
    return speed.toString();
  }

  Widget _textButton(String label,
      {IconData? icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: Colors.white70),
              const SizedBox(width: 4),
            ],
            Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
          ],
        ),
      ),
    );
  }

  void _showSpeedMenu() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF1C1C1C),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) {
        const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('播放速度',
                      style: TextStyle(
                          fontSize: 14,
                          color: Colors.white,
                          fontWeight: FontWeight.w600)),
                ),
              ),
              for (final s in speeds)
                InkWell(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_setSpeed(s));
                  },
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
                    child: Row(
                      children: [
                        Text('${_speedLabel(s)}x',
                            style: TextStyle(
                              fontSize: 14,
                              color: s == _speed ? Colors.white : Colors.white70,
                            )),
                        const Spacer(),
                        if (s == _speed)
                          const Icon(Icons.check, size: 16, color: Colors.white),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }
}

/// 把时长格式化成 `41:30` / `1:02:03`，用于卡片和播放页。
String formatVideoDuration(Duration d) {
  final total = d.inSeconds;
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  final s = total % 60;
  final mm = h > 0 ? m.toString().padLeft(2, '0') : m.toString();
  final ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}
