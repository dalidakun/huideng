import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'pull_reveal.dart';
import 'auth_service.dart';
import 'login_page.dart';
import 'user_avatar.dart';
import 'reading_page.dart';
import 'checkin_hub_page.dart';
import 'sutra_list_page.dart';
import 'sutra_favorites.dart';
import 'sutra_read_later.dart';
import 'calendar_page.dart';
import 'checkin_history_stats.dart';
import 'cloud_notes_service.dart';
import 'sync_service.dart';
import 'reading_time_service.dart';
import 'sutra_downloader.dart';
import 'note_sutra_links.dart';
import 'dedication_page.dart';
import 'dedication_store.dart';
import 'blessing_page.dart';
import 'blessing_service.dart';

import 'app_palette.dart';

Color get _primary => AppPalette.p.primary;
Color get _primaryLight => AppPalette.p.textSec;
Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
Color get _overlay => AppPalette.p.tintBg;

/// 素白外观下主页大卡片（精读经文/功课打卡）用纯白底；
/// 暖黄外观下用低饱和浅暖灰，比原奶油黄更素净（仅精读/历史统计两张卡生效）。
Color get _cardSurface =>
    AppPalette.instance.isPlain ? Colors.white : const Color(0xFFF6F1EB);

/// 功课打卡卡背景：比上方精读卡略深一层，形成层次区分但保持整体和谐。
Color get _checkinCardBg => AppPalette.instance.isPlain
    ? const Color(0xFFF2F5EF)
    : const Color(0xFFF8EED9);

class StudyHubPage extends StatefulWidget {
  /// 左上角头像点击回调：从左侧滑出个人菜单。
  final VoidCallback? onOpenSideMenu;

  /// 精读卡长按菜单修改收藏/已读状态后回调（用于通知经藏页刷新列表与收藏）。
  final VoidCallback? onSutraStateChanged;

  const StudyHubPage(
      {super.key, this.onOpenSideMenu, this.onSutraStateChanged});

  @override
  State<StudyHubPage> createState() => StudyHubPageState();
}

class StudyHubPageState extends State<StudyHubPage>
    with TickerProviderStateMixin, RouteAware {
  static SharedPreferences? _warmPrefs;

  /// DeepSeek 下拉露出手势：跟手擦洗，松手按进度决定展开/收回。
  /// 仅在列表已滚到最顶部时才可接管：否则从中间往下拉会先把 DeepSeek 露出，
  /// 而不是先滚回顶部（这就是「上面还有内容却出现 DeepSeek 页」的 bug）。
  late final PullRevealTracker _pullReveal;

  static Future<void> warmPrefs() async {
    _warmPrefs = await SharedPreferences.getInstance();
  }

  void reload() {
    _loadData();
  }

  /// 点击底部「首页」菜单图标：回到页面最顶部。
  void scrollToTop() {
    if (_scrollController.hasClients && _scrollController.offset > 0) {
      _scrollController.animateTo(0,
          duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
    }
  }

  String? _currentTitle;
  String? _currentFilePath;
  double _progress = 0.0;
  List<Map<String, String>> _todayCheckIns = [];
  int _checkinTotalDays = 0;

  /// 历史统计的自定义顺序（类型 key），空表示未自定义。
  List<String> _historyStatsOrder = [];

  /// 功课回向内容（愿我的功课回向）。
  String _dedication = '';

  /// 默认回向文：用户未输入直接保存时使用。
  static const String _kDefaultDedication =
      '愿以此功德，回向于法界，庄严佛净土；上报四重恩，下济三途苦；若有见闻者，悉发菩提心。';

  /// 首次启动写入第 1 天时的本地标记；云端有累计天数时可覆盖。
  static const String _kProvisionalStudyDay = '_provisional_study_day';
  String? _lockedTitle;
  String? _lockedFilePath;
  bool _currentFavorite = false;

  /// 当前精读经文是否已标记完成阅读（青色标题）。
  bool _currentRead = false;

  /// 当前精读经文是否已标记稍后阅读。
  bool _currentReadLater = false;

  /// 多卷经书的基础经名集合，用于显示「卷X」卷标。
  Set<String> _multiVolumeBases = const {};

  /// 精读经文卡小字元信息（部类 · 总字数），如「阿含部 · 12345 字」。
  String _sutraMeta = '';

  /// 底部「今日读经 / 累积读经」徽章行 Key：用于测量其宽度，
  /// 让上方的读经进度条与徽章行等宽。
  final GlobalKey _jingDuBadgesKey = GlobalKey();
  double _jingDuBarWidth = 0;

  /// 是否允许他人在主页查看我的「精读」（在读经书）。
  bool _allowReadingShare = false;
  List<Map<String, dynamic>> _customTypes = [];

  /// 实际配置的功课类型列表（功课打卡卡片与自动分享共用）。
  List<Map<String, dynamic>> _checkInTypesList = [];
  bool _loaded = false;

  /// 祈福共修：主页区块展示的当前祈福（我的进行中优先，否则社区热门）。
  BlessingItem? _blessing;

  /// 该祈福是否为我参与的（用于决定快捷动作按钮）。
  bool _blessingMine = false;
  bool _blessingLoading = false;
  bool _blessingBusy = false;
  final ScrollController _scrollController = ScrollController();
  late AnimationController _pulseController;
  late Animation<double> _pulseAnim;

  /// 十斋日提醒条动画：今天为十斋日时在主页顶部显示约 5 秒后淡出。
  late final AnimationController _zhaiCtrl;
  Timer? _zhaiHideTimer;
  String _zhaiLunarText = '';

  @override
  void initState() {
    super.initState();
    // 列表滚到最顶部（offset <= 0）才允许下拉露出 DeepSeek，
    // 避免页面还有上方内容时下拉就被 DeepSeek 页接管。
    _pullReveal = PullRevealTracker(
      canStart: () =>
          !_scrollController.hasClients || _scrollController.offset <= 0,
    );
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1500));
    _pulseAnim = Tween<double>(begin: 1.0, end: 1.05).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _pulseController.repeat(reverse: true);
    _zhaiCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    _tryShowZhaiBanner();
    ReadingTimeService.instance.ensureLoaded();
    _loadData();
    _loadBlessing();
  }

  /// 十斋日提醒：每天只提醒一次，通过 SharedPreferences 记录上次提醒日期。
  Future<void> _tryShowZhaiBanner() async {
    if (!isTodayZhaiRi()) return;
    final prefs = await SharedPreferences.getInstance();
    final lastShownDate = prefs.getString('zhai_banner_shown_date') ?? '';
    final today = _today();
    if (lastShownDate == today) return;
    _zhaiLunarText = todayLunarMonthDay();
    _zhaiCtrl.forward();
    _zhaiHideTimer = Timer(const Duration(seconds: 5), () {
      _zhaiCtrl.reverse();
    });
    await prefs.setString('zhai_banner_shown_date', today);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) routeObserver.subscribe(this, route);
  }

  /// 从阅读页等路由返回时立即刷新“当前读经”进度。
  @override
  void didPopNext() {
    _loadData();
    _loadBlessing();
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _zhaiHideTimer?.cancel();
    _zhaiCtrl.dispose();
    _pulseController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    final prefs = _warmPrefs ?? await SharedPreferences.getInstance();
    _warmPrefs = prefs;

    final lastDate = prefs.getString('study_last_date') ?? '';
    final today = _today();
    if (today != lastDate) {
      final count = prefs.getInt('study_day_count') ?? 0;
      unawaited(prefs.setInt('study_day_count', count + 1));
      unawaited(prefs.setString('study_last_date', today));
      // 第一次使用本机时先写了第 1 天；标记后让云端累计天数能在同步时
      // 覆盖它（后续 reload 会再补记今天）。标记本身不上传。
      if (lastDate.isEmpty) {
        unawaited(prefs.setBool(_kProvisionalStudyDay, true));
      }
    }

    String? title;
    String? path;
    final lockTitle = prefs.getString('locked_sutra_title');
    final lockPath = prefs.getString('locked_sutra_file_path');
    String? lockT;
    String? lockP;
    if (lockTitle != null) {
      title = lockTitle;
      path = lockPath;
      lockT = lockTitle;
      lockP = lockPath;
    } else {
      title = prefs.getString('current_sutra_title');
      path = prefs.getString('current_sutra_file_path');
    }
    // 并行加载独立数据，缩短首屏缓冲：sutras_list.json 只读一次（供收藏/已读/
    // 稍后读/多卷集合共用），编目与阅读进度各自异步加载。
    final sutraListF = _readSutraListOnce();
    final catalogF = NoteSutraCatalog.load();
    var progressF = path != null
        ? SutraDownloader.latestProgressForPath(prefs, path, title: title)
        : Future.value(SutraDownloader.progressFromDailyHistory(prefs, title));

    final decoded = await sutraListF;
    final fav = _isCurrentFavoriteFromList(title, decoded);
    final read = _isCurrentReadFromList(title, decoded);
    final readLater = _isCurrentReadLaterFromList(title, decoded);
    // 多卷集合优先用随包全量目录（与阅读页/经藏列表同一份数据），它完整覆盖
    // 全部经书；本地 sutras_list.json 只是用户子集，仅作兜底，否则会因集合缺失
    // 漏掉「卷X」卷标（如主页精读卡）。
    await catalogF;
    // 历史错配自愈：经名与路径指向两部不同的经时（卡片显示 A、点开却是 B 的
    // 正文），以经名为准归一，并把修好的值写回 prefs，保证主页精读卡显示与
    // 点开的正文一致。
    if (title != null && title.isNotEmpty) {
      final rec = reconcileSutraTitleAndPath(title, path);
      if (rec.title != title || rec.filePath != (path ?? '')) {
        title = rec.title;
        path = rec.filePath.isEmpty ? null : rec.filePath;
        if (lockT != null) {
          lockT = title;
          lockP = path;
          await prefs.setString('locked_sutra_title', title);
          if (path == null) {
            await prefs.remove('locked_sutra_file_path');
          } else {
            await prefs.setString('locked_sutra_file_path', path);
          }
        } else {
          await prefs.setString('current_sutra_title', title);
          if (path == null) {
            await prefs.remove('current_sutra_file_path');
          } else {
            await prefs.setString('current_sutra_file_path', path);
          }
        }
        progressF = path != null
            ? SutraDownloader.latestProgressForPath(prefs, path, title: title)
            : Future.value(
                SutraDownloader.progressFromDailyHistory(prefs, title));
      }
    }
    final catalogBases = NoteSutraCatalog.cachedMultiVolumeBases;
    final mvBases = catalogBases.isNotEmpty
        ? catalogBases
        : _multiVolumeBasesFromList(decoded);

    // 经文卡小字元信息（部类 · 字数）：编目就绪后按基础经名取部类，
    // 字数取「当前精读的这一部经文」（优先按完整经名精确命中该卷，
    // 命不中按卷取，仍取不到才退全书）。
    String sutraMeta = '';
    if (title != null && title.isNotEmpty) {
      var base = sutraBaseTitle(title);
      var volume = sutraVolumeOf(title);
      // 兼容带中文卷标的标题（如「地藏菩萨本愿经卷一」，
      // 从 $引用/讨论页打开时会存成这种中文卷标形式）：
      // 剥离末尾中文卷标得基础经名，并解析出卷号，保证查得到部类与字数。
      if (volume <= 0) {
        final m = chineseVolumeSuffixRe.firstMatch(base);
        if (m != null) {
          base = base.substring(0, m.start).trim();
          volume = parseChineseVolumeNumber(m.group(0)!);
        }
      }
      final link = NoteSutraCatalog.cachedTitleMap?[base];
      final parts = <String>[];
      if (link != null) {
        final dept = link.folder.replaceAll(RegExp(r'^T\d+'), '').trim();
        if (dept.isNotEmpty) parts.add(dept);
      }
      var shownChars = NoteSutraCatalog.cachedCharCountForRawTitle(title);
      if (shownChars <= 0 && volume > 0) {
        shownChars = NoteSutraCatalog.cachedVolumeCharCount(base, volume);
      }
      if (shownChars <= 0) {
        shownChars = NoteSutraCatalog.cachedCharCount(base);
      }
      if (shownChars > 0) parts.add('$shownChars 字');
      sutraMeta = parts.join(' · ');
    }

    // 精读卡进度：以阅读页实时写入的最新进度为准（规范路径键存在时，
    // 即使为 0 也代表最近一次关闭时的进度，不被更早的更高进度覆盖）；
    // 规范键缺失时兼容旧版本用本机绝对路径命名的 progress_ 键（换机/重装后
    // 云端同步回来的可能是这类键，按规范路径查会显示 0），progress_ 键全部
    // 缺失时再从每日阅读历史（随账号同步）兜底恢复，避免进度清零。
    final lastReadProgress = await progressF;

    if (!mounted) return;
    setState(() {
      _loaded = true;
      _currentTitle = title;
      _currentFilePath = path;
      _multiVolumeBases = mvBases;
      _sutraMeta = sutraMeta;
      _lockedTitle = lockT;
      _lockedFilePath = lockP;
      _progress = lastReadProgress;
      _currentFavorite = fav;
      _currentRead = read;
      _currentReadLater = readLater;
      _allowReadingShare = prefs.getBool('privacy_show_reading') ?? false;
      _todayCheckIns = _loadTodayCheckIns(prefs);
      _checkinTotalDays = _calcTotalDays(prefs);
      _historyStatsOrder = prefs.getStringList('history_stats_order') ?? [];
      _dedication = DedicationStore.effective(prefs);
      final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
      _customTypes =
          (jsonDecode(customRaw) as List<dynamic>).cast<Map<String, dynamic>>();
      _checkInTypesList = _buildConfiguredCheckInTypes(prefs);
    });
    // 把当前配置的具体功课项写入 prefs，供桌面「一键打卡」快捷方式在无 Flutter
    // 引擎时由原生直接读取并补打卡（见 QuickCheckinActivity）。
    await _writeQuickCheckinPayload(prefs);
    // 原生「一键打卡」在后台写入记录后留下的待分享标记：补发一次静默分享。
    if (prefs.getBool('shortcut_checkin_needs_share') ?? false) {
      await prefs.setBool('shortcut_checkin_needs_share', false);
      await _maybeAutoShareCheckin(prefs, silent: true);
    }
  }

  /// 回到前台时调用：桌面「一键打卡」由原生在后台直写 prefs，Dart 侧缓存可能
  /// 已过期，先 reload 再检查待分享标记，命中则刷新主页并静默分享。
  Future<void> checkShortcutCheckin() async {
    final prefs = _warmPrefs ?? await SharedPreferences.getInstance();
    _warmPrefs = prefs;
    try {
      await prefs.reload();
    } catch (_) {}
    if (!(prefs.getBool('shortcut_checkin_needs_share') ?? false)) return;
    if (!mounted) return;
    await _loadData();
  }

  /// 把主页配置的具体功课项序列化进 prefs（仅在内容变化时写盘），
  /// 供原生「一键打卡」无 UI 直接复用打卡规则与数量。
  Future<void> _writeQuickCheckinPayload(SharedPreferences prefs) async {
    try {
      final items = _loadConfiguredItems(prefs);
      final payload = <Map<String, dynamic>>[];
      for (final it in items) {
        final type = (it['type'] ?? '').toString();
        final name = (it['name'] ?? '').toString();
        if (type.isEmpty || name.isEmpty) continue;
        payload.add({
          'type': type,
          'label': (it['category'] ?? '').toString(),
          'name': name,
          'amount': _checkInAmount(type, prefs),
        });
      }
      final encoded = jsonEncode(payload);
      if ((prefs.getString('quick_checkin_items') ?? '') != encoded) {
        await prefs.setString('quick_checkin_items', encoded);
      }
    } catch (_) {}
  }

  /// 一次性读取 sutras_list.json 并解码（原子写期间的瞬时读坏视为无数据，
  /// 由各调用方按缺失处理，与旧逻辑逐次读取行为一致）。返回 null 表示文件
  /// 不存在/读失败；否则返回解码后的列表。_loadData 只调用一次，供多个状态
  /// 查询与多卷集合共用，避免重复磁盘 IO。
  Future<List<dynamic>?> _readSutraListOnce() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString()) as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  bool _isCurrentFavoriteFromList(String? title, List<dynamic>? decoded) {
    if (title == null || decoded == null) return false;
    for (final e in decoded) {
      if (e is Map && e['title'] == title) {
        return e['isFavorite'] == true;
      }
    }
    return false;
  }

  bool _isCurrentReadFromList(String? title, List<dynamic>? decoded) {
    if (title == null || decoded == null) return false;
    for (final e in decoded) {
      if (e is Map && e['title'] == title) {
        return e['isRead'] == true;
      }
    }
    return false;
  }

  bool _isCurrentReadLaterFromList(String? title, List<dynamic>? decoded) {
    if (title == null || decoded == null) return false;
    for (final e in decoded) {
      if (e is Map && e['title'] == title) {
        return e['isReadLater'] == true;
      }
    }
    return false;
  }

  /// 原子写 sutras_list.json（临时文件 + 改名替换），避免并发读取读到损坏内容。
  Future<void> _writeSutraListAtomic(List<Map<String, dynamic>> list) async {
    final docs = await getApplicationDocumentsDirectory();
    final file = File('${docs.path}${Platform.pathSeparator}sutras_list.json');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(list), flush: true);
    if (await file.exists()) {
      await file.delete();
    }
    await tmp.rename(file.path);
  }

  Future<void> _toggleFavoriteCurrent() async {
    final title = _currentTitle;
    if (title == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        _showTopToast('未找到经书列表，无法收藏', isError: true);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final list = decoded.map((e) => (e as Map<String, dynamic>)).toList();
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx < 0) {
        _showTopToast('未找到该经书，无法收藏', isError: true);
        return;
      }
      final wasFav = list[idx]['isFavorite'] == true;
      list[idx]['isFavorite'] = !wasFav;
      list[idx]['favoriteTime'] =
          wasFav ? null : DateTime.now().toIso8601String();
      await _writeSutraListAtomic(list);
      await SutraFavorites.syncStatePref(title);
      if (!mounted) return;
      setState(() => _currentFavorite = !wasFav);
      widget.onSutraStateChanged?.call();
    } catch (_) {
      if (!mounted) return;
      _showTopToast('收藏失败，请重试', isError: true);
    }
  }

  /// 精读经文卡右上角的「允许」开关：控制他人在主页查看我的精读。
  Future<void> _toggleReadingShare(bool v) async {
    setState(() => _allowReadingShare = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('privacy_show_reading', v);
    await SyncService.instance.push();
    if (mounted) {
      _showToast(v ? '已开启，其他同修可查看你的精读' : '已关闭，其他同修不可查看你的精读');
    }
  }

  /// 长按精读经文卡的经书名：弹出「收藏 / 标记完成」窗口（与经藏长按菜单同款样式）。
  Future<void> _showSutraActionsSheet() async {
    final title = _currentTitle;
    if (title == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (BuildContext context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetMenuItem(
                context,
                icon: _currentFavorite ? Icons.favorite : Icons.favorite_border,
                title: _currentFavorite ? '取消收藏' : '收藏',
                onTap: () async {
                  String? msg;
                  final wasFav = _currentFavorite;
                  await _toggleFavoriteCurrent();
                  msg = wasFav ? '已取消收藏' : '已收藏';
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _showToast(msg);
                },
              ),
              _sheetMenuItem(
                context,
                icon:
                    _currentReadLater ? Icons.bookmark : Icons.bookmark_border,
                title: _currentReadLater ? '取消稍后阅读' : '稍后阅读',
                onTap: () async {
                  String? msg;
                  final wasRL = _currentReadLater;
                  await _toggleReadLaterCurrent();
                  msg = wasRL ? '已取消稍后阅读' : '已标记稍后阅读';
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _showToast(msg);
                },
              ),
              _sheetMenuItem(
                context,
                icon: _currentRead
                    ? Icons.mark_chat_unread
                    : Icons.mark_chat_read,
                title: _currentRead ? '取消完成阅读' : '标记完成阅读',
                onTap: () async {
                  String? msg;
                  final wasRead = _currentRead;
                  await _toggleReadCurrent();
                  msg = wasRead ? '已取消完成阅读标记' : '已标记完成阅读';
                  if (!context.mounted) return;
                  Navigator.pop(context);
                  _showToast(msg);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// 经藏长按菜单同款菜单项：白底、图标 24 + 文字 16。
  Widget _sheetMenuItem(
    BuildContext ctx, {
    required IconData icon,
    required String title,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFF212121), size: 24),
            const SizedBox(width: 16),
            Text(
              title,
              style: const TextStyle(
                color: Color(0xFF212121),
                fontSize: 16,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 标记/取消标记当前精读经文为已读完成（与经藏长按菜单一致，双向切换）。
  Future<void> _toggleReadCurrent() async {
    final title = _currentTitle;
    if (title == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        _showTopToast('未找到经书列表，无法标记', isError: true);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final list = decoded.map((e) => (e as Map<String, dynamic>)).toList();
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx < 0) {
        _showTopToast('未找到该经书，无法标记', isError: true);
        return;
      }
      final wasRead = list[idx]['isRead'] == true;
      list[idx]['isRead'] = !wasRead;
      list[idx]['readTime'] = wasRead ? null : DateTime.now().toIso8601String();
      await _writeSutraListAtomic(list);
      await SutraFavorites.syncStatePref(title);
      if (!mounted) return;
      setState(() => _currentRead = !wasRead);
      widget.onSutraStateChanged?.call();
    } catch (_) {
      if (!mounted) return;
      _showTopToast('标记失败，请重试', isError: true);
    }
  }

  Future<void> _toggleReadLaterCurrent() async {
    final title = _currentTitle;
    if (title == null) return;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final file =
          File('${docs.path}${Platform.pathSeparator}sutras_list.json');
      if (!await file.exists()) {
        _showTopToast('未找到经书列表，无法标记', isError: true);
        return;
      }
      final decoded = jsonDecode(await file.readAsString()) as List<dynamic>;
      final list = decoded.map((e) => (e as Map<String, dynamic>)).toList();
      final idx = list.indexWhere((e) => e['title'] == title);
      if (idx < 0) {
        _showTopToast('未找到该经书，无法标记', isError: true);
        return;
      }
      final wasRL = list[idx]['isReadLater'] == true;
      list[idx]['isReadLater'] = !wasRL;
      list[idx]['readLaterTime'] =
          wasRL ? null : DateTime.now().toIso8601String();
      await _writeSutraListAtomic(list);
      await SutraReadLater.syncStatePref(title);
      if (!mounted) return;
      setState(() => _currentReadLater = !wasRL);
      widget.onSutraStateChanged?.call();
    } catch (_) {
      if (!mounted) return;
      _showTopToast('标记失败，请重试', isError: true);
    }
  }

  /// 与经藏长按菜单一致的底部浮动提示（收藏/标记等操作反馈）。
  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _showTopToast(String msg, {bool isError = false}) {
    if (!mounted) return;
    final overlay = Overlay.of(context, rootOverlay: true);
    final topPad = MediaQuery.of(context).padding.top;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) => Positioned(
        top: topPad + kToolbarHeight + 10,
        left: 20,
        right: 20,
        child: IgnorePointer(
          child: Material(
            color: Colors.transparent,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                decoration: BoxDecoration(
                  color: _text.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 14,
                        offset: const Offset(0, 4)),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(isError ? Icons.info_outline : Icons.check,
                        size: 16,
                        color: (!isError && AppPalette.instance.isPlain)
                            ? Colors.white
                            : _gold),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(msg,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 2), () {
      if (entry.mounted) entry.remove();
    });
  }

  List<Map<String, String>> _loadTodayCheckIns(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();
    return allRecords
        .where((r) => r['date'] == today)
        .map((r) => {
              'type': r['type'].toString(),
              'label': r['label'].toString(),
              'name': (r['name'] ?? '').toString(),
            })
        .toList();
  }

  int _calcTotalDays(SharedPreferences prefs) {
    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = jsonDecode(raw) as List<dynamic>;
    return records.map((r) => r['date'].toString()).toSet().length;
  }

  String _today() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  String _displayTitle(String title, {String? filePath}) => sutraDisplayName(
        title,
        filePath: filePath,
        multiVolumeBases: _multiVolumeBases,
      );

  Set<String> _multiVolumeBasesFromList(List<dynamic>? decoded) {
    try {
      if (decoded == null) return const {};
      return collectMultiVolumeBases(
          decoded.map((e) => Sutra.fromJson(e as Map<String, dynamic>)));
    } catch (_) {
      // 解析失败时保持当前卷标集合，避免瞬时读坏导致卷标闪没。
      return _multiVolumeBases;
    }
  }

  void _openSutra() {
    if (_currentTitle == null) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReadingPage(
                title: _currentTitle!, filePath: _currentFilePath)));
  }

  Future<void> _openSutraByPath(String title, String? filePath) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ReadingPage(title: title, filePath: filePath)));
    _loadData();
  }

  Future<void> _showRecentSutras() async {
    final prefs = await SharedPreferences.getInstance();
    // 最近阅读记录（recent_sutras，格式 `经名|||路径`，新读在前）最多取前 20 部：
    // 不限最近几天，哪怕是一个月前读过的也照常展示，保证列表始终有内容。
    final raw = prefs.getStringList('recent_sutras') ?? [];
    final sutras = raw
        .map((e) {
          final parts = e.split('|||');
          if (parts.isEmpty || parts[0].isEmpty) return null;
          return <String, dynamic>{
            'title': parts[0],
            'filePath': parts.length > 1 ? parts[1] : '',
          };
        })
        .whereType<Map<String, dynamic>>()
        .take(20)
        .toList();

    if (!mounted) return;

    // 用实时进度（progress_ 键，以规范路径键的最新值为准，缺失时才兼容
    // 绝对路径形式）替换历史快照进度，保证与精读卡/继续阅读卡一致，
    // 不随打开次数显示陈旧数值。
    final liveProgress = <String, double>{};
    for (final s in sutras) {
      final title = s['title']?.toString() ?? '';
      final fp = s['filePath']?.toString();
      if (title.isEmpty || fp == null || fp.isEmpty) continue;
      liveProgress[title] =
          await SutraDownloader.latestProgressForPath(prefs, fp, title: title);
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
                child: Row(
                  children: [
                    Text('最近阅读',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: _text)),
                    const Spacer(),
                    Text('${sutras.length} 部',
                        style: TextStyle(fontSize: 13, color: _textHint)),
                  ],
                ),
              ),
              Divider(height: 1, color: _border),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 430),
                  child: sutras.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.symmetric(vertical: 40),
                          child: Center(
                              child: Text('最近还没有阅读记录',
                                  style: TextStyle(
                                      fontSize: 13, color: _textHint))),
                        )
                      : ListView(
                          shrinkWrap: true,
                          padding: EdgeInsets.zero,
                          children: sutras.map((s) {
                            final title = s['title'] as String? ?? '';
                            final fp = s['filePath'] as String?;
                            final snap =
                                (s['progress'] as num?)?.toDouble() ?? 0.0;
                            final progress = liveProgress[title] ?? snap;
                            return InkWell(
                              onTap: () {
                                Navigator.pop(ctx);
                                if (title.isNotEmpty)
                                  _openSutraByPath(title, fp);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 14),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                              _displayTitle(title,
                                                  filePath: fp),
                                              style: TextStyle(
                                                  fontSize: 15,
                                                  fontWeight: FontWeight.w500,
                                                  color: _text)),
                                          const SizedBox(height: 12),
                                          Text(
                                              '已读 ${(progress * 100).toStringAsFixed(1)}%',
                                              style: TextStyle(
                                                  fontSize: 12,
                                                  color: _textHint)),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.chevron_right,
                                        color: _textHint, size: 20),
                                  ],
                                ),
                              ),
                            );
                          }).toList(),
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

  Future<void> _toggleLock() async {
    if (_currentTitle == null) return;
    final prefs = await SharedPreferences.getInstance();
    if (_lockedTitle != null) {
      await prefs.remove('locked_sutra_title');
      await prefs.remove('locked_sutra_file_path');
      setState(() {
        _lockedTitle = null;
        _lockedFilePath = null;
      });
    } else {
      await prefs.setString('locked_sutra_title', _currentTitle!);
      await prefs.setString('locked_sutra_file_path', _currentFilePath ?? '');
      await _recordLockedSutra(prefs, _currentTitle!, _currentFilePath ?? '');
      _loadData();
    }
  }

  /// 记录锁定过的经文（精读依据）：去重置顶、上限 50 本。
  Future<void> _recordLockedSutra(
      SharedPreferences prefs, String title, String filePath) async {
    final list = prefs.getStringList('locked_sutras') ?? [];
    list.removeWhere((e) => e.startsWith('$title|||'));
    list.insert(0, '$title|||$filePath');
    if (list.length > 50) list.removeRange(50, list.length);
    await prefs.setStringList('locked_sutras', list);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: Color(0xFF212121)),
        title: GestureDetector(
          onDoubleTap: scrollToTop,
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Row(
              children: [
                GestureDetector(
                  // 左上角头像：未登录时进入登录页面；已登录时从左侧滑出个人菜单。
                  onTap: () {
                    if (!AuthService.instance.isLoggedIn) {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const LoginPage()),
                      );
                      return;
                    }
                    widget.onOpenSideMenu?.call();
                  },
                  child: UserAvatar(
                    userId: AuthService.instance.currentUser.value?.id,
                    radius: 16,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  '功课',
                  style: TextStyle(
                    color: AppPalette.p.primary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 6),
                const Text(
                  '·',
                  style: TextStyle(
                    color: Color(0xFF9E9588),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    '燃一盏灯，看见自己，照亮别人。',
                    style: TextStyle(
                      color: Color(0xFF9E9588),
                      fontSize: 12,
                    ),
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: IconButton(
              icon: const Icon(Icons.calendar_month_outlined,
                  color: Color(0xFF71867A), size: 20),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CalendarPage())),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: _pullReveal.onPointerDown,
            onPointerMove: _pullReveal.onPointerMove,
            onPointerUp: _pullReveal.onPointerUp,
            onPointerCancel: _pullReveal.onPointerCancel,
            child: ListView(
              controller: _scrollController,
              physics: const PullRevealLockPhysics(
                  parent: AlwaysScrollableScrollPhysics()),
              padding: EdgeInsets.fromLTRB(
                  16,
                  4,
                  16,
                  // 底部额外留白：让出右下角「继续阅读」悬浮按钮的高度
                  // （按钮高 42 + 距菜单 28），否则会遮住历史统计的数据。
                  MediaQuery.of(context).padding.bottom + 78),
              children: [
                _buildCurrentSutraCard(),
                const SizedBox(height: 14),
                _buildCheckInCard(),
                const SizedBox(height: 14),
                _buildHistoryStatsCard(),
                const SizedBox(height: 14),
                _buildBlessingBlock(),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 16,
            right: 16,
            child: SafeArea(
              bottom: false,
              child: _zhaiBannerSlot(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentSutraCard() {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _measureJingDuBarWidth());
    if (!_loaded) {
      return Container(
        decoration: BoxDecoration(
          color: _cardSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child:
                  CircularProgressIndicator(strokeWidth: 2.5, color: _primary),
            ),
          ),
        ),
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: _cardSurface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 12,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
              ),
            ),
            if (_currentTitle != null)
              Positioned(
                width: 220,
                height: 180,
                right: 0,
                bottom: 0,
                child: Opacity(
                  opacity: 0.35,
                  child: Image.asset(
                    'assets/images/lianhua.png',
                    fit: BoxFit.contain,
                    alignment: Alignment.bottomRight,
                  ),
                ),
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openSutra,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                    child: Row(
                      children: [
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                              color: AppPalette.p.readingAccent
                                  .withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(8)),
                          child: Icon(Icons.menu_book_rounded,
                              size: 16, color: AppPalette.p.readingAccent),
                        ),
                        SizedBox(width: AppPalette.instance.isPlain ? 9 : 12),
                        Text('闻思佛法',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: _textSec)),
                        if (_currentTitle != null) ...[
                          const SizedBox(width: 6),
                          GestureDetector(
                            onTap: _toggleLock,
                            child: Icon(
                              _lockedTitle != null
                                  ? Icons.lock
                                  : Icons.lock_open,
                              size: 17,
                              color: const Color(0xFF71867A),
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () =>
                                _toggleReadingShare(!_allowReadingShare),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppPalette.p.readingAccent
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(11),
                              ),
                              child: Text(
                                _allowReadingShare ? '已允许' : '未允许',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: AppPalette.p.readingAccent,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_currentTitle != null) ...[
                    const SizedBox(height: 14),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _openSutra,
                      onLongPress: _showSutraActionsSheet,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 20, right: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                    _displayTitle(_currentTitle!,
                                        filePath: _currentFilePath),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w700,
                                        color: _text,
                                        height: 1.4)),
                                if (_sutraMeta.isNotEmpty) ...[
                                  const SizedBox(height: 3),
                                  Text(_sutraMeta,
                                      style: TextStyle(
                                          fontSize: 12,
                                          color: _textHint,
                                          fontWeight: FontWeight.w400)),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.only(left: 20, right: 20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    SizedBox(
                                      width: _jingDuBarWidth,
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(2),
                                        child: LinearProgressIndicator(
                                          value: _progress,
                                          minHeight: 5,
                                          backgroundColor: _border,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                  AppPalette.instance.isPlain
                                                      ? const Color(0xFF4A4A4A)
                                                      : AppPalette.p.accent),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                        '已读 ${(_progress * 100).toStringAsFixed(1)}%',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: _textHint,
                                            fontWeight: FontWeight.w500)),
                                  ],
                                ),
                                const SizedBox(height: 20),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Row(
                                      key: _jingDuBadgesKey,
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        ValueListenableBuilder<int>(
                                          valueListenable: ReadingTimeService
                                              .instance.todaySeconds,
                                          builder: (context, sec, _) =>
                                              _buildTimeBadgeItem(
                                                  Icons.timer_outlined,
                                                  '今日读经',
                                                  sec),
                                        ),
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 14, vertical: 2),
                                          child: Container(
                                            width: 1,
                                            height: 30,
                                            color: _border,
                                          ),
                                        ),
                                        ValueListenableBuilder<int>(
                                          valueListenable: ReadingTimeService
                                              .instance.totalSeconds,
                                          builder: (context, sec, _) =>
                                              _buildTimeBadgeItem(
                                                  Icons.history, '累积读经', sec),
                                        ),
                                      ],
                                    ),
                                    const Spacer(),
                                    GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: _showRecentSutras,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 2, vertical: 4),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text('最近阅读',
                                                style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: _text)),
                                            const SizedBox(width: 2),
                                            Icon(Icons.chevron_right,
                                                size: 18, color: _textSec),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ] else ...[
                    Center(
                      child: Column(
                        children: [
                          const SizedBox(height: 2),
                          AnimatedBuilder(
                            animation: _pulseAnim,
                            builder: (context, child) => Transform.scale(
                                scale: _pulseAnim.value, child: child),
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: _overlay,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(Icons.auto_stories_rounded,
                                  size: 30,
                                  color: _primaryLight.withValues(alpha: 0.8)),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text('今日尚未开启经文之旅',
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500,
                                  color: _text)),
                          const SizedBox(height: 4),
                          Text('选择一部经文，开始今日修学',
                              style: TextStyle(fontSize: 13, color: _textSec)),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            child: SizedBox(
                              width: double.infinity,
                              child: ElevatedButton.icon(
                                onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => const SutraListPage())),
                                icon: const Icon(Icons.explore, size: 17),
                                label: const Text('浏览经藏',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: _gold,
                                  foregroundColor: Colors.white,
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 11),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                  elevation: 0,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 7),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 测量精读卡底部徽章行宽度，让进度条与其等宽。
  void _measureJingDuBarWidth() {
    final ctx = _jingDuBadgesKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final w = ctx.size?.width ?? 0;
    if (w <= 0) return;
    if ((_jingDuBarWidth - w).abs() > 0.5) {
      setState(() => _jingDuBarWidth = w);
    }
  }

  /// 读经时长徽章：第一行（图标+标题）与第二行（时间）左对齐。
  Widget _buildTimeBadgeItem(IconData icon, String label, int seconds) {
    final timeStr = _formatReadTime(seconds);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: _primaryLight),
            const SizedBox(width: 1),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: _textHint,
                    fontWeight: FontWeight.w500)),
          ],
        ),
        const SizedBox(height: 2),
        Text(timeStr,
            style: TextStyle(
                fontSize: 14, color: _text, fontWeight: FontWeight.w600)),
      ],
    );
  }

  /// 读经时长徽章：暖色底 + 图标 + 文字。
  /// 素白外观下不包裹背景色块，直接展示图标与文字。
  Widget _buildTimeBadge(IconData icon, String text) {
    if (AppPalette.instance.isPlain) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _primaryLight),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 11,
                  color: _primaryLight,
                  fontWeight: FontWeight.w500)),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
          color: _overlay, borderRadius: BorderRadius.circular(11)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _primaryLight),
          const SizedBox(width: 4),
          Text(text,
              style: TextStyle(
                  fontSize: 11,
                  color: _primaryLight,
                  fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  /// 读经时长格式化：统一显示「x时x分」短格式，不足1分钟显示「0时0分」。
  String _formatReadTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '$hours时$minutes分';
  }

  Widget _buildCheckInCard() {
    final prefs = _warmPrefs;
    if (prefs == null) {
      return Container(
        decoration: BoxDecoration(
          color: _checkinCardBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child:
                  CircularProgressIndicator(strokeWidth: 2.5, color: _primary),
            ),
          ),
        ),
      );
    }

    final items = _loadConfiguredItems(prefs);
    final totalItems = items.length;
    final doneCount = items
        .where((item) => _isItemCheckedToday(item['type'], item['name']))
        .length;

    // 无配置项目时显示引导
    if (items.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: _checkinCardBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                        color: AppPalette.instance.isPlain
                            ? Colors.transparent
                            : _primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8)),
                    child: Icon(Icons.check_circle_outline,
                        size: 17, color: const Color(0xFF71867A)),
                  ),
                  SizedBox(width: AppPalette.instance.isPlain ? 5 : 10),
                  Text('功课打卡',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
              child: Text('请先设置每日功课',
                  style: TextStyle(fontSize: 14, color: _textHint)),
            ),
            Divider(
                height: 1,
                thickness: 0.5,
                indent: 20,
                endIndent: 20,
                color: _border),
            _buildDedicationBlock(),
            const SizedBox(height: 6),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: _checkinCardBg,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: AppPalette.instance.isPlain
                          ? const Color(0xFF71867A).withValues(alpha: 0.1)
                          : _primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.check_circle_outline,
                      size: 17, color: const Color(0xFF71867A)),
                ),
                SizedBox(width: AppPalette.instance.isPlain ? 5 : 10),
                Text('功课打卡',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const Spacer(),
                // 打卡天数：用户的荣誉，金色加粗文字无背景，前加奖杯图标
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.emoji_events, size: 18, color: _gold),
                    const SizedBox(width: 4),
                    Text('打卡$_checkinTotalDays天',
                        style: TextStyle(
                            fontSize: 14,
                            color: _gold,
                            fontWeight: FontWeight.w800)),
                  ],
                ),
                const SizedBox(width: 14),
                // 功课设置入口：打开合并页（每日功课设置 + 打卡目标设置）
                InkWell(
                  onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CheckInHubPage())),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.all(7),
                    decoration: BoxDecoration(
                        color: _overlay,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: _border, width: 0.5)),
                    child: Icon(Icons.tune, size: 17, color: _text),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // 进度条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: totalItems > 0 ? doneCount / totalItems : 0,
                      minHeight: 4,
                      backgroundColor: _border,
                      valueColor: AlwaysStoppedAnimation<Color>(_primary),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text('$doneCount/$totalItems',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: _primary)),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // 功课列表
          for (int i = 0; i < items.length; i++) ...[
            _buildCheckInItem(items[i]),
            if (i < items.length - 1)
              Divider(
                  height: 1,
                  thickness: 0.5,
                  indent: 20,
                  endIndent: 20,
                  color: _border),
          ],
          // 功课回向：贴在打卡卡片底部，用分割线与功课列表区分。
          Divider(
              height: 1,
              thickness: 0.5,
              indent: 20,
              endIndent: 20,
              color: _border),
          _buildDedicationBlock(),
          const SizedBox(height: 6),
        ],
      ),
    );
  }

  /// 历史统计卡片：置于功课打卡卡下方，风格与功课打卡卡保持一致。
  Widget _buildHistoryStatsCard() {
    final prefs = _warmPrefs;
    if (prefs == null) return const SizedBox.shrink();
    return CheckInHistoryStats(
      entries: _buildHistoryStats(prefs),
      bg: _cardSurface,
      radius: 16,
      bordered: false,
      onOrderChanged: _onHistoryStatsOrderChanged,
    );
  }

  /// 长按历史统计数据调整顺序后回调：更新内存顺序并持久化，下次打开保持。
  void _onHistoryStatsOrderChanged(List<String> keys) async {
    if (!mounted) return;
    setState(() => _historyStatsOrder = keys);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('history_stats_order', keys);
  }

  // ---------- 祈福共修 ----------

  /// 拉取祈福数据：优先展示我进行中的祈福，否则社区最新的一条。
  Future<void> _loadBlessing() async {
    if (mounted) setState(() => _blessingLoading = true);
    BlessingItem? pick;
    var mine = false;
    try {
      final list = await BlessingService.instance.listMine(pageSize: 20);
      if (list.isNotEmpty) {
        final active =
            list.where((e) => !(e.progress?.isDone ?? false)).toList();
        pick = active.isNotEmpty ? active.first : list.first;
        mine = true;
      }
    } catch (_) {}
    if (pick == null) {
      try {
        final list = await BlessingService.instance.listCommunity(pageSize: 20);
        if (list.isNotEmpty) {
          pick = list.first;
          mine = false;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _blessing = pick;
      _blessingMine = mine;
      _blessingLoading = false;
    });
  }

  Future<void> _openBlessingPage() async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => const BlessingPage()));
    if (mounted) _loadBlessing();
  }

  Future<void> _openBlessingDetail(String id) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => BlessingDetailPage(id: id)));
    if (mounted) _loadBlessing();
  }

  /// 主页快捷「今日祈福」。
  Future<void> _blessCurrent() async {
    final item = _blessing;
    if (item == null || _blessingBusy) return;
    setState(() => _blessingBusy = true);
    try {
      final res = await BlessingService.instance.blessToday(item.project.id);
      if (mounted) {
        _showToast(res.isDone ? '祈福圆满，随喜功德' : '今日祈福，功德已记');
      }
    } catch (e) {
      if (mounted) _showToast(e.toString());
    } finally {
      if (mounted) setState(() => _blessingBusy = false);
      _loadBlessing();
    }
  }

  /// 祈福共修区块：主页最下方，展示当前祈福与进入详情页的入口。
  Widget _buildBlessingBlock() {
    return Container(
      decoration: BoxDecoration(
        color: _cardSurface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 14, 0),
            child: Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(8)),
                  child: Icon(Icons.volunteer_activism_outlined,
                      size: 17, color: _gold),
                ),
                const SizedBox(width: 10),
                Text('祈福',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const Spacer(),
                InkWell(
                  onTap: _openBlessingPage,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('全部',
                            style: TextStyle(fontSize: 13, color: _textSec)),
                        Icon(Icons.chevron_right, size: 16, color: _textSec),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
            child: _buildBlessingBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildBlessingBody() {
    if (_blessingLoading && _blessing == null) {
      return Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
          ),
          const SizedBox(width: 10),
          Text('加载中…', style: TextStyle(fontSize: 13, color: _textHint)),
        ],
      );
    }
    final item = _blessing;
    if (item == null) {
      return Row(
        children: [
          Expanded(
            child: Text('尚无祈福，发起一个，把功课回向于此。',
                style: TextStyle(fontSize: 13, color: _textSec)),
          ),
          const SizedBox(width: 10),
          _blessingAction('去发起', onTap: _openBlessingPage),
        ],
      );
    }
    final proj = item.project;
    final prog = item.progress;
    final done = prog?.isDone == true;
    final blessedToday = prog?.doneToday() ?? false;
    final mineJoined = _blessingMine && (prog?.joined == true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(proj.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
            ),
            if (done) ...[
              const SizedBox(width: 6),
              _blessingTag('已圆满'),
            ],
          ],
        ),
        if (proj.target.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text('回向：${proj.target}',
              style: TextStyle(fontSize: 12.5, color: _textSec)),
        ],
        const SizedBox(height: 10),
        if (_blessingMine)
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: proj.totalDays <= 0
                        ? 0
                        : ((prog?.doneCount ?? 0) / proj.totalDays)
                            .clamp(0.0, 1.0),
                    minHeight: 5,
                    backgroundColor: _border,
                    valueColor: AlwaysStoppedAnimation<Color>(_gold),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('${prog?.doneCount ?? 0}/${proj.totalDays}',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: _gold)),
            ],
          )
        else
          Row(
            children: [
              Icon(Icons.groups_outlined, size: 15, color: _textSec),
              const SizedBox(width: 5),
              Text('已有 ${proj.joinerCount} 人祈福',
                  style: TextStyle(fontSize: 12.5, color: _textSec)),
            ],
          ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
                _blessingMine
                    ? '已祈福 ${prog?.doneCount ?? 0}/${proj.totalDays} 天'
                    : '与大家一同祈福',
                style: TextStyle(fontSize: 12.5, color: _textSec)),
            const Spacer(),
            if (mineJoined && !done)
              _blessingAction(
                blessedToday ? '今日已祈福' : '今日祈福',
                enabled: !blessedToday && !_blessingBusy,
                filled: !blessedToday,
                onTap: _blessCurrent,
              )
            else
              _blessingAction('查看', onTap: () => _openBlessingDetail(proj.id)),
          ],
        ),
      ],
    );
  }

  Widget _blessingAction(
    String label, {
    required VoidCallback onTap,
    bool enabled = true,
    bool filled = true,
  }) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: filled ? _gold : Colors.transparent,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _gold),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: filled ? Colors.white : _gold)),
        ),
      ),
    );
  }

  Widget _blessingTag(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: _gold)),
    );
  }

  /// 功课回向区块：贴在打卡卡片底部（与卡片同一背景，不另起色块），
  /// 上方以分割线区分；点击弹出抽屉填写/编辑回向内容。
  Widget _buildDedicationBlock() {
    final text = _dedication.trim();
    return InkWell(
      onTap: _openDedicationEditor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          children: [
            Icon(Icons.volunteer_activism_outlined, size: 18, color: _textSec),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('愿我的功课回向',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _textSec)),
                  const SizedBox(height: 2),
                  Text(text.isEmpty ? '写下回向，点击编辑' : text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: _textHint)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 18, color: _textSec),
          ],
        ),
      ),
    );
  }

  // ---------- 十斋日提醒条 ----------

  Color get _zhaiIcon => const Color(0xFFD4851E);

  Color get _zhaiBg1 => AppPalette.instance.isPlain
      ? const Color(0xFFF1F5ED)
      : const Color(0xFFFCF4E5);

  Color get _zhaiBg2 => AppPalette.instance.isPlain
      ? const Color(0xFFDFEAD3)
      : const Color(0xFFF6E7C9);

  /// 十斋日提醒条：今天为十斋日时在主页顶部展示约 5 秒后淡出收起。
  Widget _zhaiBannerSlot() {
    return AnimatedBuilder(
      animation: _zhaiCtrl,
      builder: (context, child) {
        final t = _zhaiCtrl.value;
        return AnimatedSize(
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: t > 0.02
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Opacity(
                    opacity: t.clamp(0.0, 1.0),
                    child: Transform.translate(
                      offset: Offset(0, 10 * (1 - t)),
                      child: _buildZhaiRiBanner(),
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        );
      },
    );
  }

  Widget _buildZhaiRiBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [_zhaiBg1, _zhaiBg2],
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // 圆形小徽章：莲花静坐图标。
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.85),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.self_improvement, color: _zhaiIcon, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '今天是十斋日',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: _text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '农历$_zhaiLunarText · 持斋清净，身心安定',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: _textSec,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 打开「功德回向」抽屉：顶部为输入框，下方为可选用的回向模板，
  /// 并支持设置「定时自动更换」的回向方案。文本由抽屉内部持久化。
  Future<void> _openDedicationEditor() async {
    final text = await showDedicationSheet(
      context,
      defaultText: _kDefaultDedication,
    );
    if (text == null) return;
    if (mounted) setState(() => _dedication = text);
  }

  /// 汇总各类型自使用以来的累计量，并附每日功课具体内容明细。
  List<CheckInStatEntry> _buildHistoryStats(SharedPreferences prefs) {
    final meta = <String, (String, String)>{
      'reading': ('诵经', '遍'),
      'nianfo': ('念佛', '声'),
      'buddha': ('称名', '声'),
      'mantra': ('持咒', '遍'),
      'copying': ('抄经', '篇'),
      'meditation': ('静坐', '分钟'),
    };
    for (final c in _customTypes) {
      final key = c['key']?.toString() ?? '';
      final label = (c['category'] ?? c['label'] ?? '').toString().trim();
      final unit = (c['unit'] ?? '遍').toString();
      if (key.isNotEmpty && label.isNotEmpty) meta[key] = (label, unit);
    }

    final goalsRaw = prefs.getString('checkin_goals') ?? '{}';
    final goalsJson = jsonDecode(goalsRaw) as Map<String, dynamic>;
    final goals = goalsJson
        .map((k, v) => MapEntry(k, double.tryParse(v.toString()) ?? 0));
    debugPrint('[historyStats] checkin_goals=$goalsJson');

    final raw = prefs.getString('checkin_records') ?? '[]';
    final records = jsonDecode(raw) as List<dynamic>;
    final totals = <String, double>{};
    // 明细名称优先取最近实际打卡记录中的名称，保证与最新功课打卡对得上；
    final details = <String, List<String>>{};
    for (final r in records) {
      final key = r['type'].toString();
      final amt = double.tryParse((r['amount'] ?? '1').toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
      final name = (r['name'] ?? '').toString().trim();
      if (name.isEmpty) continue;
      final list = details.putIfAbsent(key, () => []);
      if (!list.contains(name)) list.add(name);
    }
    // 再并入当前配置中出现的名称，作为未打卡项目的补充。
    final configDetails = _buildStatDetails(prefs);
    for (final e in configDetails.entries) {
      final list = details.putIfAbsent(e.key, () => []);
      for (final n in e.value) {
        if (!list.contains(n)) list.add(n);
      }
    }

    // 依据用户长按拖动后保存的类型顺序排序（history_stats_order）：
    // 已保存的类型严格按其保存位置排；尚未出现在保存列表中的类型
    // （如本次新增的自定义功课）排在已保存条目的后面、保持原默认顺序。
    final orderedKeys = meta.keys.toList()
      ..sort((a, b) {
        final ia = _historyStatsOrder.indexOf(a);
        final ib = _historyStatsOrder.indexOf(b);
        return (ia < 0 ? 9999 : ia).compareTo(ib < 0 ? 9999 : ib);
      });

    return [
      for (final k in orderedKeys)
        if ((totals[k] ?? 0) > 0)
          CheckInStatEntry(
            key: k,
            label: meta[k]!.$1,
            unit: meta[k]!.$2,
            total: totals[k] ?? 0,
            goal: goals[k] ?? 0,
            detail: details[k] ?? const [],
          ),
    ];
  }

  /// 汇总每日功课各类型配置的具体名称（诵的经、持的咒、抄的经等）。
  Map<String, List<String>> _buildStatDetails(SharedPreferences prefs) {
    final out = <String, List<String>>{};
    out['reading'] = [
      for (final e
          in _decodeNamedList(prefs.getString('setting_reading_titles')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['nianfo'] = [
      for (final e in _decodeNamedList(prefs.getString('setting_nianfo_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['mantra'] = [
      for (final e in _decodeNamedList(prefs.getString('setting_mantra_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['buddha'] = [
      for (final e in _decodeNamedList(prefs.getString('setting_buddha_items')))
        if (e.$1.trim().isNotEmpty) e.$1.trim(),
    ];
    out['copying'] = [
      for (final e in _decodeStrList(prefs.getString('setting_copying_titles')))
        if (e.trim().isNotEmpty) e.trim(),
    ];
    return out;
  }

  /// 单个功课打卡项：图标 + 类别·名称 × 数量 + 打卡状态。
  Widget _buildCheckInItem(Map<String, dynamic> item) {
    final typeKey = item['type'] as String;
    final category = item['category'] as String;
    final name = item['name'] as String;
    final count = item['count'] as String;
    final unit = item['unit'] as String;
    final checked = _isItemCheckedToday(typeKey, name);
    final plain = AppPalette.instance.isPlain;

    // 标题：诵经·地藏菩萨本愿经 × 1遍
    final titleParts = <String>[];
    titleParts.add('$category·$name');
    if (count.isNotEmpty) {
      titleParts.add(' × $count$unit');
    }

    return InkWell(
      onTap: () => _toggleCheckIn(typeKey, category, itemName: name),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
        child: Row(
          children: [
            // 类别图标
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(_categoryIcon(typeKey),
                  size: 16, color: const Color(0xFF71867A)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                titleParts.join(),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: _text,
                ),
              ),
            ),
            const SizedBox(width: 12),
            // 打卡状态小圆点：点击带水花扩散效果
            _SplashCircle(
              checked: checked,
              fill: plain ? const Color(0xFF1A1A1A) : const Color(0xFF71867A),
              uncheckedFill: AppPalette.instance.isPlain
                  ? const Color(0xFFEDEDED)
                  : _border.withValues(alpha: 0.5),
              border: AppPalette.instance.isPlain
                  ? _border
                  : _border.withValues(alpha: 0.6),
              splash: const Color(0xFF71867A),
              onTap: () => _toggleCheckIn(typeKey, category, itemName: name),
            ),
          ],
        ),
      ),
    );
  }

  /// 功课类别图标：自定义类型用三横杠，其余按类型映射。
  IconData _categoryIcon(String typeKey) {
    switch (typeKey) {
      case 'reading':
        return Icons.chrome_reader_mode_outlined;
      case 'buddha':
        return Icons.spa_outlined;
      case 'mantra':
        return Icons.notifications_none;
      case 'nianfo':
        return Icons.local_florist_outlined;
      case 'copying':
        return Icons.edit_outlined;
      case 'meditation':
        return Icons.self_improvement_outlined;
      default:
        return Icons.menu;
    }
  }

  Future<void> _toggleCheckIn(String typeKey, String label,
      {String? itemName}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();

    final idx = allRecords.indexWhere((r) =>
        r['date'] == today &&
        r['type'] == typeKey &&
        (r['name'] ?? '').toString() == (itemName ?? ''));
    if (idx >= 0) {
      allRecords.removeAt(idx);
    } else {
      allRecords.add({
        'date': today,
        'type': typeKey,
        'label': label,
        'name': itemName ?? '',
        'amount': _checkInAmount(typeKey, prefs),
      });
    }
    await prefs.setString('checkin_records', jsonEncode(allRecords));
    await _loadData();
    await _maybeAutoShareCheckin(prefs);
  }

  /// 一键完成今日全部功课：把主页配置的每个具体功课项补齐为今日已打卡
  /// （已完成的项不会重复添加），随后按设置静默分享到菩提空间。
  /// 供桌面「一键打卡」快捷方式调用；返回本次新补的项数。
  Future<int> quickCheckInAll({bool autoShare = true}) async {
    final prefs = await SharedPreferences.getInstance();
    // 兜底同步一次自定义功课类型，避免快捷方式早于首帧 _loadData 完成时漏项。
    try {
      final customRaw = prefs.getString('custom_checkin_types') ?? '[]';
      _customTypes =
          (jsonDecode(customRaw) as List<dynamic>).cast<Map<String, dynamic>>();
    } catch (_) {}

    final raw = prefs.getString('checkin_records') ?? '[]';
    final List<dynamic> allRecords = jsonDecode(raw);
    final today = _today();
    final items = _loadConfiguredItems(prefs);

    var added = 0;
    for (final item in items) {
      final type = (item['type'] ?? '').toString();
      final name = (item['name'] ?? '').toString();
      if (type.isEmpty || name.isEmpty) continue;
      final exists = allRecords.any((r) =>
          r['date'] == today &&
          r['type'] == type &&
          (r['name'] ?? '').toString() == name);
      if (exists) continue;
      allRecords.add({
        'date': today,
        'type': type,
        'label': (item['category'] ?? '').toString(),
        'name': name,
        'amount': _checkInAmount(type, prefs),
      });
      added++;
    }
    if (added > 0) {
      await prefs.setString('checkin_records', jsonEncode(allRecords));
    }
    await _loadData();
    var shared = false;
    if (autoShare) {
      shared = await _maybeAutoShareCheckin(prefs, silent: true);
    }
    if (mounted) {
      if (items.isEmpty) {
        _showTopToast('请先在功课设置中添加功课');
      } else if (shared) {
        _showTopToast('已完成今日全部功课，并分享到菩提空间');
      } else if (added == 0) {
        _showTopToast('今日功课已全部完成');
      } else {
        _showTopToast('已完成今日全部功课');
      }
    }
    return added;
  }

  /// 打卡类型列表：固定五项 + 自定义。若已配置具体功课，则只展示已配置的类型。
  List<Map<String, dynamic>> _checkInTypes() {
    return _checkInTypesList.isEmpty ? _allCheckInTypes() : _checkInTypesList;
  }

  List<Map<String, dynamic>> _allCheckInTypes() {
    return [
      {
        'key': 'reading',
        'label': '诵经',
        'icon': Icons.chrome_reader_mode_outlined
      },
      {'key': 'nianfo', 'label': '念佛', 'icon': Icons.local_florist_outlined},
      {'key': 'buddha', 'label': '称名', 'icon': Icons.spa_outlined},
      {
        'key': 'mantra',
        'label': '持咒',
        'icon': Icons.notifications_none_outlined
      },
      {'key': 'copying', 'label': '抄经', 'icon': Icons.edit_outlined},
      {
        'key': 'meditation',
        'label': '静坐',
        'icon': Icons.self_improvement_outlined
      },
      ..._customTypes.map((t) => {
            'key': t['key'],
            'label': (t['category'] ?? t['label'] ?? '').toString(),
            'icon': Icons.menu,
          }),
    ];
  }

  /// 依据功课设置筛选实际配置的类型；全部未配置时回退为固定五项，避免空卡。
  List<Map<String, dynamic>> _buildConfiguredCheckInTypes(
      SharedPreferences prefs) {
    final all = _allCheckInTypes();
    final configured = all.where((t) {
      switch (t['key']) {
        case 'meditation':
          return _hasNonEmptyItems(prefs, 'setting_meditation_minutes');
        case 'reading':
          return _hasNonEmptyNamed(prefs, 'setting_reading_titles');
        case 'nianfo':
          return _hasNonEmptyNamed(prefs, 'setting_nianfo_items');
        case 'mantra':
          return _hasNonEmptyNamed(prefs, 'setting_mantra_items');
        case 'buddha':
          return _hasNonEmptyNamed(prefs, 'setting_buddha_items');
        case 'copying':
          return _hasNonEmptyItems(prefs, 'setting_copying_titles');
        default:
          return true; // 自定义类型始终展示。
      }
    }).toList();
    return configured.isEmpty ? all : configured;
  }

  bool _hasNonEmptyItems(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.any((e) => e.toString().trim().isNotEmpty);
    } catch (_) {}
    return false;
  }

  bool _hasNonEmptyNamed(SharedPreferences prefs, String key) {
    final raw = prefs.getString(key);
    if (raw == null) return false;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        return d.any((e) {
          final n = e is Map ? (e['name'] ?? '') : e;
          return n.toString().trim().isNotEmpty;
        });
      }
    } catch (_) {}
    return false;
  }

  /// 完成当日全部功课且开启「分享每日功课」时，弹窗展示当天功课并确认后发布到菩提空间（每日仅一次）。
  /// [silent] 为 true 时不弹确认框，直接发布（供桌面「一键打卡」快捷方式使用）。
  /// 返回是否成功分享到菩提空间。
  Future<bool> _maybeAutoShareCheckin(SharedPreferences prefs,
      {bool silent = false}) async {
    try {
      if (!(prefs.getBool('privacy_share_daily_checkin') ?? false))
        return false;
      if (!AuthService.instance.isLoggedIn) return false;
      final today = _today();
      if (prefs.getString('shared_checkin_date') == today) return false;
      final types = _checkInTypes();
      if (types.isEmpty) return false;
      final todayKeys = {for (final r in _todayCheckIns) r['type'] ?? ''};
      if (!types.every((t) => todayKeys.contains(t['key']))) return false;

      final lines = _buildCheckInShareLines(prefs, types);
      if (lines.isEmpty) return false;
      final content = '今天完成功课：\n${lines.join('\n')}';

      // 静默分享：不弹确认框，直接发布（供桌面「一键打卡」快捷方式使用）。
      if (silent) {
        await CloudNotesService.instance
            .publishNote(title: '今日功课完成', content: content);
        await prefs.setString('shared_checkin_date', today);
        return true;
      }

      if (!mounted) return false;

      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: _card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('恭喜你完成今天的功课！',
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.w600, color: _text)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('今天完成的功课如下，是否分享到菩提空间？',
                  style: TextStyle(fontSize: 13, color: _textSec)),
              const SizedBox(height: 12),
              Container(
                width: double.maxFinite,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _overlay,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final l in lines)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Text(l,
                            style: TextStyle(
                                fontSize: 14, color: _text, height: 1.4)),
                      ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: _textSec)),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: _gold),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('分享到菩提空间'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return false;
      await CloudNotesService.instance
          .publishNote(title: '今日功课完成', content: content);
      await prefs.setString('shared_checkin_date', today);
      if (mounted) _showTopToast('已分享到菩提空间');
      return true;
    } catch (_) {
      // 分享失败静默处理，不打断打卡。
      return false;
    }
  }

  /// 依据当天已完成的功课，生成分享内容行（样式与功课设置一致）。
  List<String> _buildCheckInShareLines(
      SharedPreferences prefs, List<Map<String, dynamic>> types) {
    final done = <String>{for (final r in _todayCheckIns) r['type'] ?? ''};
    final lines = <String>[];
    for (final t in types) {
      final key = t['key'] as String;
      if (!done.contains(key)) continue;
      switch (key) {
        case 'meditation':
          for (final e in _decodeStrList(
              prefs.getString('setting_meditation_minutes'))) {
            if (e.trim().isNotEmpty) lines.add('静坐 ${e.trim()}分钟');
          }
        case 'reading':
          for (final e
              in _decodeNamedList(prefs.getString('setting_reading_titles'))) {
            if (e.$1.isNotEmpty) {
              lines.add('诵经 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
            }
          }
        case 'nianfo':
          for (final e
              in _decodeNamedList(prefs.getString('setting_nianfo_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('念佛 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
            }
          }
        case 'mantra':
          for (final e
              in _decodeNamedList(prefs.getString('setting_mantra_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('持咒 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
            }
          }
        case 'buddha':
          for (final e
              in _decodeNamedList(prefs.getString('setting_buddha_items'))) {
            if (e.$1.isNotEmpty) {
              lines.add('称名 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
            }
          }
        case 'copying':
          for (final e
              in _decodeStrList(prefs.getString('setting_copying_titles'))) {
            if (e.trim().isNotEmpty) lines.add('抄经 ${e.trim()}');
          }
        default:
          for (final c in _customTypes) {
            if (c['key'] == key) {
              final category = (c['category'] ?? c['label'] ?? '').toString();
              final unit = (c['unit'] ?? '遍').toString();
              final itemList = c['items'] as List<dynamic>? ?? [];
              for (final it in itemList) {
                final name = (it['name'] ?? '').toString();
                final count = (it['count'] ?? '').toString();
                if (name.isNotEmpty) {
                  lines.add(
                      '$category·$name ${count.trim().isEmpty ? '0' : count.trim()}$unit');
                }
              }
            }
          }
      }
    }
    return lines;
  }

  List<String> _decodeStrList(String? raw) {
    if (raw == null || raw.isEmpty) return [];
    try {
      final d = jsonDecode(raw);
      if (d is List) return d.map((e) => e.toString()).toList();
    } catch (_) {}
    return [];
  }

  List<(String, String)> _decodeNamedList(String? raw) {
    final out = <(String, String)>[];
    if (raw == null || raw.isEmpty) return out;
    try {
      final d = jsonDecode(raw);
      if (d is List) {
        for (final e in d) {
          if (e is Map) {
            out.add(
                ((e['name'] ?? '').toString(), (e['count'] ?? '').toString()));
          } else {
            out.add((e.toString(), ''));
          }
        }
      }
    } catch (_) {}
    return out;
  }

  double _checkInAmount(String typeKey, SharedPreferences prefs) {
    switch (typeKey) {
      case 'meditation':
        final list =
            jsonDecode(prefs.getString('setting_meditation_minutes') ?? '[]')
                as List<dynamic>;
        return list.fold<double>(
            0, (s, e) => s + (double.tryParse(e.toString()) ?? 0));
      case 'reading':
        return _sumNamedCount(prefs.getString('setting_reading_titles'));
      case 'nianfo':
        return _sumNamedCount(prefs.getString('setting_nianfo_items'));
      case 'mantra':
        return _sumNamedCount(prefs.getString('setting_mantra_items'));
      case 'buddha':
        return _sumNamedCount(prefs.getString('setting_buddha_items'));
      case 'copying':
        final list =
            jsonDecode(prefs.getString('setting_copying_titles') ?? '[]')
                as List<dynamic>;
        return list.length.toDouble();
      default:
        final customs =
            (jsonDecode(prefs.getString('custom_checkin_types') ?? '[]')
                    as List<dynamic>)
                .cast<Map<String, dynamic>>();
        for (final c in customs) {
          if (c['key'] == typeKey) {
            final itemList = c['items'] as List<dynamic>? ?? [];
            return itemList.fold<double>(
                0,
                (s, it) =>
                    s + (double.tryParse((it['count'] ?? '').toString()) ?? 0));
          }
        }
        return 0;
    }
  }

  double _sumNamedCount(String? raw) {
    if (raw == null || raw.isEmpty) return 0;
    final list = jsonDecode(raw) as List<dynamic>;
    return list.fold<double>(
        0, (s, e) => s + (double.tryParse((e['count'] ?? '').toString()) ?? 0));
  }

  /// 从功课设置中解析已配置的具体项目（经名、咒名等），用于主页功课打卡垂直列表。
  List<Map<String, dynamic>> _loadConfiguredItems(SharedPreferences prefs) {
    final items = <Map<String, dynamic>>[];
    // 诵经
    _addNamedItems(items, prefs, 'reading', '诵经', '遍');
    // 称名
    _addNamedItems(items, prefs, 'buddha', '称名', '声');
    // 持咒
    _addNamedItems(items, prefs, 'mantra', '持咒', '遍');
    // 念佛
    _addNamedItems(items, prefs, 'nianfo', '念佛', '声');
    // 抄经
    _addStrItems(items, prefs, 'copying', '抄经', '遍');
    // 静坐
    _addStrItems(items, prefs, 'meditation', '静坐', '分钟');
    // 自定义功课：每项为「类别 → 名称列表」，同类别共享单位。
    for (final c in _customTypes) {
      final key = c['key']?.toString() ?? '';
      final category = (c['category'] ?? c['label'] ?? '').toString().trim();
      final unit = c['unit']?.toString() ?? '遍';
      if (category.isEmpty) continue;
      final itemList = c['items'] as List<dynamic>? ?? [];
      for (final it in itemList) {
        final name = (it['name'] ?? '').toString().trim();
        final count = (it['count'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        items.add({
          'type': key,
          'category': category,
          'name': name,
          'count': count.isEmpty ? '' : count,
          'unit': unit,
          'key': key,
        });
      }
    }
    return items;
  }

  void _addNamedItems(List<Map<String, dynamic>> items, SharedPreferences prefs,
      String type, String category, String unit) {
    final raw = prefs.getString('setting_${_settingsKey(type)}');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final name = e is Map ? (e['name'] ?? '').toString() : '';
        final count = e is Map ? (e['count'] ?? '').toString() : '';
        if (name.trim().isEmpty) continue;
        items.add({
          'type': type,
          'category': category,
          'name': name.trim(),
          'count': count.trim().isEmpty ? '' : count.trim(),
          'unit': unit,
          'key': '$type:${name.trim()}',
        });
      }
    } catch (_) {}
  }

  void _addStrItems(List<Map<String, dynamic>> items, SharedPreferences prefs,
      String type, String category, String unit) {
    final raw = prefs.getString('setting_${_settingsKey(type)}');
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final e in list) {
        final name = e.toString().trim();
        if (name.isEmpty) continue;
        items.add({
          'type': type,
          'category': category,
          'name': name,
          'count': '',
          'unit': unit,
          'key': '$type:$name',
        });
      }
    } catch (_) {}
  }

  String _settingsKey(String type) {
    switch (type) {
      case 'reading':
        return 'reading_titles';
      case 'buddha':
        return 'buddha_items';
      case 'mantra':
        return 'mantra_items';
      case 'nianfo':
        return 'nianfo_items';
      case 'copying':
        return 'copying_titles';
      case 'meditation':
        return 'meditation_minutes';
      default:
        return type;
    }
  }

  /// 检查某个具体功课项目今天是否已打卡。
  bool _isItemCheckedToday(String typeKey, String itemName) {
    return _todayCheckIns
        .any((r) => r['type'] == typeKey && r['name'] == itemName);
  }
}

class _CheckInButton extends StatefulWidget {
  final IconData? icon;
  final String? emoji;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  const _CheckInButton(
      {this.icon,
      this.emoji,
      required this.label,
      required this.checked,
      required this.onTap});

  @override
  State<_CheckInButton> createState() => _CheckInButtonState();
}

class _CheckInButtonState extends State<_CheckInButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 150));
    _scale = Tween<double>(begin: 1.0, end: 0.92)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(_) => _ctrl.forward();
  void _onTapUp(_) {
    _ctrl.reverse();
    widget.onTap();
  }

  void _onTapCancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    final checked = widget.checked;
    // 素白外观：未点击 #F3F3F3 浅灰底 + 黑图标黑字，点击后 #555555 深灰底 +
    // 白图标白字；暖黄保持原配色（金棕选中态）。
    final plain = AppPalette.instance.isPlain;
    final Color bg;
    final Color fg;
    if (plain) {
      bg = checked ? const Color(0xFF555555) : const Color(0xFFF3F3F3);
      fg = checked ? Colors.white : const Color(0xFF1A1A1A);
    } else {
      bg = checked ? _gold : _card;
      fg = checked ? _primary : const Color(0xFF71867A);
    }
    final labelChars = widget.label.characters;
    final label =
        labelChars.length > 2 ? '${labelChars.take(2)}…' : widget.label;
    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 60,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color:
                        Colors.black.withValues(alpha: checked ? 0.10 : 0.07),
                    blurRadius: checked ? 4 : 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (widget.icon != null)
                    Icon(widget.icon, size: 22, color: fg)
                  else
                    Text(widget.emoji ?? '', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 4),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: fg,
                        fontWeight: checked ? FontWeight.w600 : FontWeight.w400,
                      )),
                ],
              ),
            ),
            // 已打卡角标：右上角小圆圈（#1A1A1A）包裹白色小对勾。
            if (checked && plain)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  width: 13,
                  height: 13,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF1A1A1A),
                    border: Border.all(color: Colors.white, width: 1),
                  ),
                  child: const Icon(Icons.check, size: 8, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 打卡状态小圆点：点击时向外扩散一圈水花，随后（去）打卡。
class _SplashCircle extends StatefulWidget {
  final bool checked;
  final Color fill;
  final Color uncheckedFill;
  final Color border;
  final Color splash;
  final VoidCallback onTap;

  const _SplashCircle({
    required this.checked,
    required this.fill,
    required this.uncheckedFill,
    required this.border,
    required this.splash,
    required this.onTap,
  });

  @override
  State<_SplashCircle> createState() => _SplashCircleState();
}

class _SplashCircleState extends State<_SplashCircle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  );
  late final CurvedAnimation _curve =
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic);
  bool _splashShown = false;

  @override
  void dispose() {
    _curve.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  void _handleTap() {
    _splashShown = true;
    _ctrl.forward(from: 0);
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.checked ? widget.fill : widget.uncheckedFill,
          border: widget.checked
              ? null
              : Border.all(color: widget.border, width: 1),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            if (widget.checked)
              const Icon(Icons.check, size: 12, color: Colors.white),
            _buildSplash(),
          ],
        ),
      ),
    );
  }

  /// 点击时的水花：内部色块渐隐扩散 + 外圈环向外扩散。
  Widget _buildSplash() {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        final t = _curve.value;
        if (!_splashShown || t >= 1) return const SizedBox.shrink();
        return Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: (1 - t) * 0.45,
              child: Transform.scale(
                scale: 1 + t * 1.5,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.splash.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ),
            Opacity(
              opacity: (1 - t) * 0.85,
              child: Transform.scale(
                scale: 1 + t * 2.2,
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: widget.splash, width: 2),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
