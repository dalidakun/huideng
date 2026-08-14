import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'checkin_history_stats.dart';
import 'cloud_notes_service.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'post_rich_content.dart';
import 'reading_badges.dart';
import 'reading_time_service.dart';
import 'reply_chain.dart';
import 'text_input_sheet.dart';
import 'user_avatar.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _primary = Color(0xFF5C4033);
const Color _primaryLight = Color(0xFF8B6B5A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

/// 昵称行操作按钮（关注按钮/三个点点圆圈）统一尺寸。
const double _rowBtnSize = 26;

/// 某位用户的菩提空间：展示对方公开发布的所有笔记（含转发），点击可查看评论/点赞等。
class UserSpacePage extends StatefulWidget {
  final String userId;
  final String userName;

  const UserSpacePage({
    super.key,
    required this.userId,
    this.userName = '同修',
  });

  @override
  State<UserSpacePage> createState() => _UserSpacePageState();
}

class _UserSpacePageState extends State<UserSpacePage> {
  final List<PlazaNote> _notes = [];
  int _page = 0;
  int _tab = 0;
  bool _hasMore = true;
  bool _loading = true;
  bool _loadingMore = false;

  /// 置顶帖/回复的 id 集合（与「我的」页/笔记详情页共用同一份本地记录）。
  final Set<String> _pinnedIds = {};
  static const String _pinnedKey = 'my_pinned_note_ids';

  /// 是否自己的内容：优先用 currentUser，会话恢复竞态窗口（currentUser 暂为 null）
  /// 时用本地缓存 uid 兜底，避免自己的帖子误显示「关注/屏蔽」菜单。
  bool _isOwn(String? ownerUserId) {
    if (ownerUserId == null || ownerUserId.isEmpty) return false;
    final me = AuthService.instance.currentUser.value;
    if (me != null && ownerUserId == me.id) return true;
    final cachedUid = AuthService.instance.cachedUserId;
    return cachedUid != null && ownerUserId == cachedUid;
  }
  String _profileTagline = '';
  int _profileJoinTime = 0;
  String _profileAccount = '';
  bool _profileVerified = false;

  /// 对方昵称：优先用资料接口返回的昵称（未拉取到时回退构造函数传参）。
  String _profileName = '';

  /// 对方头像/横幅 base64（由 getUserProfiles 返回，未设置时为空字符串）。
  String _profileAvatar = '';
  String _profileBanner = '';

  /// 展示用昵称：资料接口拉取到昵称后用真实昵称，否则用进入页面时传入的名称。
  String get _displayName =>
      _profileName.isNotEmpty ? _profileName : widget.userName;

  /// 对方「阅藏进度」原始数据（完成册数/总册数）：头部展示用。
  int _profileCanonRead = 0;
  int _profileCanonTotal = 0;

  /// 对方累计读经时长（秒）：头部展示其点亮的修学徽章用。
  int _profileReadingSeconds = 0;
  late bool _following =
      CloudNotesService.instance.followingUserIds.contains(widget.userId);

  /// 对方「精读 / 功课」数据（受对方隐私开关控制）。
  UserHomeData? _homeData;
  bool _homeLoaded = false;
  bool _homeError = false;

  /// 对方账号（优先用资料接口返回的账号，未拉取到则从已加载的笔记中取）。
  String get _account => _profileAccount.isNotEmpty
      ? _profileAccount
      : (_notes.isNotEmpty ? _notes.first.authorAccount : '');

  /// 对方是否已实名认证（优先用资料接口返回的认证状态）。
  bool get _verified =>
      _profileVerified || (_notes.isNotEmpty && _notes.first.authorVerified);

  /// 是否已屏蔽对方。
  bool get _isBlocked =>
      CloudNotesService.instance.blockedUserIds.contains(widget.userId);

  /// 关注态是否可信：refreshFollowStates 刷新失败（登录失效）时为 false，
  /// 此时不能按本地旧集合显示「关注/已关注」，必须提示登录已失效。
  bool _followStateOk = true;

  /// 是否查看的是自己的主页。
  bool get _isSelf =>
      AuthService.instance.currentUser.value?.id == widget.userId;

  /// 关注/取消关注对方（已关注的同修在首页「关注」栏目展示其新帖）。
  Future<void> _toggleFollow() async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || me.id == widget.userId) return;
    try {
      final ok = await CloudNotesService.instance.toggleFollow(widget.userId);
      if (!mounted) return;
      setState(() => _following = ok);
      _showToast(context, ok ? '已关注' : '已取消关注');
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  /// 屏蔽/取消屏蔽对方：屏蔽后对方的帖子不再出现在修学主页菩提空间的推荐/最新等栏目。
  Future<void> _showBlockSheet() async {
    final me = AuthService.instance.currentUser.value;
    if (me == null) return;
    if (me.id == widget.userId) {
      _showToast(context, '这是你自己的主页');
      return;
    }
    final blocked =
        CloudNotesService.instance.blockedUserIds.contains(widget.userId);
    final account = _account;
    final label =
        blocked ? '取消屏蔽' : (account.isNotEmpty ? '屏蔽@$account' : '屏蔽该用户');
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(_displayName,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            InkWell(
              onTap: () => Navigator.pop(ctx, 'block'),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
                child: Row(
                  children: [
                    const Icon(Icons.block_outlined, size: 18, color: _textSec),
                    const SizedBox(width: 12),
                    Text(label,
                        style: const TextStyle(fontSize: 15, color: _text)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != 'block' || !mounted) return;
    try {
      final ok =
          await CloudNotesService.instance.toggleBlockUser(widget.userId);
      if (!mounted) return;
      setState(() {});
      _showToast(context, ok ? '已屏蔽，该用户笔记不再展示' : '已取消屏蔽');
      if (!ok) _load();
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  void _showToast(BuildContext context, String text) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (ctx) {
        final topInset = MediaQuery.of(ctx).padding.top;
        return Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: EdgeInsets.only(top: topInset + kToolbarHeight + 10),
            child: Align(
              alignment: Alignment.topCenter,
              child: Material(
                color: _text,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: Text(
                    text,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (entry.mounted) entry.remove();
    });
  }

  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    _load();
  }

  /// 从本地读取置顶帖/回复 id 列表（与「我的」页共用同一份记录）。
  Future<void> _loadPinnedIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _pinnedIds
          ..clear()
          ..addAll(prefs.getStringList(_pinnedKey) ?? const []);
      });
    } catch (_) {}
  }

  /// 置顶/取消置顶（本地保存，重启后仍生效）。
  Future<void> _togglePin(PlazaNote note) async {
    final wasPinned = _pinnedIds.contains(note.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_pinnedKey) ?? [];
      if (wasPinned) {
        list.remove(note.id);
        _pinnedIds.remove(note.id);
      } else {
        list.add(note.id);
        _pinnedIds.add(note.id);
      }
      await prefs.setStringList(_pinnedKey, list);
    } catch (_) {}
    if (!mounted) return;
    setState(() {});
    _showToast(context, wasPinned ? '已取消置顶' : '已置顶');
  }

  Future<void> _load() async {
    if (_isBlocked && !_isSelf) {
      // 已屏蔽对方：帖子/回复/精读/功课等栏目统一显示「已屏蔽用户」占位，
      // 但头部仍需展示对方的 @账户 与注册时间，方便识别/取消屏蔽。
      String tagline = '';
      int joinTime = 0;
      String account = '';
      bool verified = false;
      String name = '';
      String avatar = '';
      String banner = '';
      try {
        final profiles = await CloudNotesService.instance
            .getUserProfiles([widget.userId],
                timeout: const Duration(seconds: 25));
        if (profiles.isNotEmpty) {
          tagline = profiles.first.tagline;
          joinTime = profiles.first.joinTime;
          account = profiles.first.account;
          verified = profiles.first.verified;
          name = profiles.first.name;
          avatar = profiles.first.avatar;
          banner = profiles.first.banner;
        }
      } catch (_) {}
      // getUserProfiles 未取到 @账户 时，从对方公开笔记的 authorAccount 兜底补齐。
      if (account.isEmpty) {
        try {
          final (list, _) = await CloudNotesService.instance
              .getUserNotes(widget.userId, page: 1);
          if (list.isNotEmpty) {
            account = list.first.authorAccount;
            if (verified == false) verified = list.first.authorVerified;
          }
        } catch (_) {}
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _notes.clear();
          _profileName = name;
          _profileTagline = tagline;
          _profileJoinTime = joinTime;
          _profileAccount = account;
          _profileVerified = verified;
          _profileAvatar = avatar;
          _profileBanner = banner;
          _homeData = null;
          _homeLoaded = false;
          _homeError = false;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _hasMore = true;
      _page = 0;
    });
    try {
      // 进入他人主页前先刷新关注/屏蔽列表，避免 _following 读到旧值误显「关注」。
      // 自己主页同样刷新（首屏头部也要用关注数）。
      try {
        final followOk =
            await CloudNotesService.instance.refreshFollowStates();
        if (!mounted) return;
        _followStateOk = followOk;
      } catch (_) {
        if (mounted) _followStateOk = false;
      }
      // 用刷新后的最新列表重算关注态：_following 字段在 State 创建时已用旧值初始化，
      // 不在这里重算的话，刷新结果永远不生效，已关注的用户仍会误显「关注」按钮。
      // 刷新失败（登录失效）时不能信任旧集合，保持 _followStateOk=false 并提示。
      if (_followStateOk) {
        _following =
            CloudNotesService.instance.followingUserIds.contains(widget.userId);
      }
      final me = AuthService.instance.currentUser.value;
      final bool isSelf = me != null && me.id == widget.userId;
      final prefs = isSelf ? await SharedPreferences.getInstance() : null;

      // ── 自己主页：先读本地做兜底值，然后和「全量笔记加载」并行启动
      //    权威字段请求（getUserProfiles + getMyVerification），
      //    请求完成后首屏直接用权威值渲染，不再"先显示昨天再跳正确值"。
      //    同时权威值立即写回本地 prefs，修复旧版本污染。
      String tagline = '';
      int joinTime = 0;
      String account = '';
      bool verified = false;
      String name = '';
      String avatar = '';
      String banner = '';
      int canonRead = 0;
      int canonTotal = 0;
      int readingSeconds = 0;
      UserProfile? selfCloudProfile;
      VerificationInfo? selfVerification;
      if (isSelf && prefs != null) {
        // 读本地先填充兜底
        tagline = prefs.getString('user_tagline') ?? '燃一盏灯，看见自己，照亮别人。';
        joinTime = prefs.getInt('user_created_at') ?? 0;
        account = prefs.getString('user_account_name') ?? '';
        verified = prefs.getBool('user_verified') ?? false;
        name = prefs.getString('user_nickname') ?? '';
        final bannerPath = prefs.getString('user_banner_path');
        if (bannerPath != null &&
            bannerPath.isNotEmpty &&
            File(bannerPath).existsSync()) {
          try {
            banner = base64Encode(await File(bannerPath).readAsBytes());
          } catch (_) {}
        }
        await LocalCanonProgress.refresh();
        canonRead = LocalCanonProgress.read;
        canonTotal = LocalCanonProgress.total;
        await ReadingTimeService.instance.ensureLoaded();
        readingSeconds = ReadingTimeService.instance.totalSeconds.value;
        // 同时并行拉权威字段（不阻塞本地兜底值，但首屏渲染前等待它，用权威值覆盖）
        try {
          final profF = CloudNotesService.instance.getUserProfiles([me.id]);
          final verF = CloudNotesService.instance.getMyVerification();
          final results = await Future.wait([
            profF,
            Future<VerificationInfo?>.delayed(
              Duration.zero,
              () async {
                try {
                  return await verF;
                } catch (_) {
                  return null;
                }
              },
            ),
          ]);
          final profiles = results[0] as List<UserProfile>;
          if (profiles.isNotEmpty) selfCloudProfile = profiles.first;
          selfVerification = results[1] as VerificationInfo?;
        } catch (_) {
          selfCloudProfile = null;
          selfVerification = null;
        }
        // ★ 权威字段优先：覆盖所有本地兜底值，立刻写回本地 prefs
        if (selfCloudProfile != null) {
          final UserProfile p = selfCloudProfile;
          if (p.joinTime > 0) {
            final local = prefs.getInt('user_created_at');
            if (local == null || local != p.joinTime) {
              await prefs.setInt('user_created_at', p.joinTime);
            }
            joinTime = p.joinTime;
          }
          if (p.account.isNotEmpty) {
            final local = prefs.getString('user_account_name') ?? '';
            if (local != p.account) {
              await prefs.setString('user_account_name', p.account);
            }
            account = p.account;
          }
          if (p.name.isNotEmpty) {
            final local = prefs.getString('user_nickname') ?? '';
            if (local != p.name) {
              await prefs.setString('user_nickname', p.name);
            }
            name = p.name;
          }
          // verified 先按 getUserProfiles 覆盖 true（若本地为 false）
          if (p.verified && !verified) verified = true;
        }
        // verified 以 getMyVerification 为最高权威
        if (selfVerification != null) {
          final VerificationInfo v = selfVerification;
          final localVer = prefs.getBool('user_verified') ?? false;
          if (localVer != v.verified) {
            await prefs.setBool('user_verified', v.verified);
          }
          verified = v.verified;
          if (v.realNameMasked.isNotEmpty) {
            final local = prefs.getString('user_verified_name') ?? '';
            if (local != v.realNameMasked) {
              await prefs.setString('user_verified_name', v.realNameMasked);
            }
          }
        }
      } else {
        // 他人主页：正常 getUserProfiles + 笔记兜底
        try {
          final profiles = await CloudNotesService.instance
              .getUserProfiles([widget.userId],
                  timeout: const Duration(seconds: 25));
          if (profiles.isNotEmpty) {
            tagline = profiles.first.tagline;
            joinTime = profiles.first.joinTime;
            account = profiles.first.account;
            verified = profiles.first.verified;
            canonRead = profiles.first.canonRead;
            canonTotal = profiles.first.canonTotal;
            readingSeconds = profiles.first.readingSeconds;
            name = profiles.first.name;
            avatar = profiles.first.avatar;
            banner = profiles.first.banner;
          }
        } catch (_) {}
      }

      // 自动翻页加载全部笔记（最多 50 页兜底）：
      // 修复「回复只显示昨天的」——默认第 1 页只有 20 条，
      // 若昨天回复较多占满第 1 页，更早的历史回复会被永远卡在后续页
      // 等待滚动到底触发 loadMore，但用户通常看不到更远的历史。
      const maxPages = 50;
      var p = 1;
      var hasMore = true;
      final allNotes = <PlazaNote>[];
      while (p <= maxPages && hasMore) {
        final (list, more) =
            await CloudNotesService.instance.getUserNotes(widget.userId, page: p);
        allNotes.addAll(list);
        hasMore = more;
        if (!hasMore) break;
        p++;
      }

      if (!mounted) return;
      setState(() {
        _notes
          ..clear()
          ..addAll(allNotes);
        _profileName = name;
        _profileTagline = tagline;
        _profileJoinTime = joinTime;
        _profileAccount = account;
        _profileVerified = verified;
        _profileAvatar = avatar;
        _profileBanner = banner;
        _profileCanonRead = canonRead;
        _profileCanonTotal = canonTotal;
        _profileReadingSeconds = readingSeconds;
        _page = p;
        _hasMore = hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
    await _loadHomeData();
  }

  /// 拉取对方「精读 / 功课」数据（失败时保持空态，不影响帖子/回复展示）。
  Future<void> _loadHomeData() async {
    try {
      final data =
          await CloudNotesService.instance.getUserHomeData(widget.userId);
      if (!mounted) return;
      setState(() {
        _homeData = data;
        _homeLoaded = true;
        _homeError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _homeData = null;
        _homeLoaded = true;
        _homeError = true;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final (list, hasMore) = await CloudNotesService.instance
          .getUserNotes(widget.userId, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _notes.addAll(list);
        _page += 1;
        _hasMore = hasMore;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        top: true,
        child: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverToBoxAdapter(child: _buildHeader()),
            // 帖子/回复 tab 吸顶：滚动时横幅/头像上移，tab 钉在顶部。
            SliverPersistentHeader(
              pinned: true,
              delegate: _UserTabsDelegate(
                tab: _tab,
                onChanged: (i) => setState(() => _tab = i),
              ),
            ),
          ],
          body: _buildBody(),
        ),
      ),
    );
  }

  /// 顶部横幅：有横幅 base64 时展示横幅图，否则显示默认渐变占位。
  Widget _buildBanner() {
    if (_profileBanner.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(_profileBanner),
          width: double.infinity,
          height: 150,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _defaultBanner(),
        );
      } catch (_) {}
    }
    return _defaultBanner();
  }

  Widget _defaultBanner() {
    return Container(
      width: double.infinity,
      height: 150,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFFD2C5B3), Color(0xFFC6B79E)],
        ),
      ),
    );
  }

  /// 与「我的菜单页」同款头部：横幅 + 大头像 + 昵称/认证/@账户。
  /// 自己主页没有关注按钮与编辑资料；他人主页有关注按钮（70867A）。
  Widget _buildHeader() {
    final following = _following;
    final me = AuthService.instance.currentUser.value;
    final isSelf = me != null && me.id == widget.userId;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: 226,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // 顶部横幅：他人/自己均优先展示云端（或本地）横幅，未设置时用默认渐变占位。
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                height: 150,
                child: _buildBanner(),
              ),
              // 返回按钮：半透明深色圆底 + 白色箭头，深色横幅上也清晰可见。
              Positioned(
                left: 8,
                top: 0,
                child: SafeArea(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_back_ios_new,
                          size: 18, color: Colors.white),
                    ),
                  ),
                ),
              ),
              // 三个点点 + 关注按钮：位于横幅右下角之外（横幅下边缘与昵称行之间，
              // 与横幅下边缘保持距离，不重叠在横幅图上）。
              Positioned(
                right: 16,
                top: 168,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showBlockSheet,
                      child: Container(
                        width: _rowBtnSize,
                        height: _rowBtnSize,
                        decoration: BoxDecoration(
                          color: const Color(0xFFECE9E4),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                                color: Colors.black.withValues(alpha: 0.12),
                                blurRadius: 4,
                                offset: const Offset(0, 1)),
                          ],
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.more_horiz,
                            size: 18, color: Color(0xFF8C8C8C)),
                      ),
                    ),
                    // 关注按钮：位于三个点点右侧（他人主页才显示）。
                    // 关注态刷新失败（登录失效）时，不能按旧值误显「关注/已关注」，
                    // 改成灰色的「登录失效」按钮：点按提示重新登录。
                    if (!isSelf) ...[
                      const SizedBox(width: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _followStateOk
                            ? _toggleFollow
                            : () => _showToast(context, kLoginExpiredMessage),
                        child: Container(
                          height: _rowBtnSize,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: _followStateOk
                                ? (following
                                    ? const Color(0xFFECE9E4)
                                    : const Color(0xFF70867A))
                                : const Color(0xFFC9C4BC),
                            borderRadius:
                                BorderRadius.circular(_rowBtnSize / 2),
                            boxShadow: [
                              BoxShadow(
                                  color: Colors.black.withValues(alpha: 0.12),
                                  blurRadius: 4,
                                  offset: const Offset(0, 1)),
                            ],
                          ),
                          child: Text(
                              _followStateOk
                                  ? (following ? '已关注' : '关注')
                                  : '登录失效',
                              style: TextStyle(
                                  fontSize: 12,
                                  color: _followStateOk
                                      ? (following
                                          ? const Color(0xFF5A5A5A)
                                          : Colors.white)
                                      : Colors.white,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 大头像（重叠在横幅下缘，下移贴紧昵称行）。
              Positioned(
                left: 20,
                top: 130,
                child: Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _card,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: ClipOval(
                    child: UserAvatar(
                      userId: widget.userId,
                      radius: 38,
                      imageBase64: _profileAvatar,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Transform.translate(
          offset: const Offset(0, -14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 昵称 + 认证 + 徽章：三者紧挨、依次排布（左侧）。
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Flexible(
                            child: Text(_displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w700,
                                    color: _text)),
                          ),
                          if (_verified) ...[
                            const SizedBox(width: 4),
                            const Icon(Icons.verified,
                                size: 17, color: Color(0xFF70867A)),
                          ],
                          // 已点亮的修学徽章：紧挨昵称/认证依次显示，
                          // 只显示点亮的（无点亮不展示）。
                          if (_profileReadingSeconds > 0) ...[
                            const SizedBox(width: 8),
                            ReadingBadgesRow(
                              seconds: _profileReadingSeconds,
                              size: 20,
                              showLocked: false,
                            ),
                          ],
                        ],
                      ),
                    ),
                    // 阅藏进度：位于原徽章位置（昵称行最右侧），
                    // 完成册数 ÷ 总册数（0% 也显示，与经藏页同源算法）。
                    const SizedBox(width: 8),
                    ReadingProgressChip(
                      text: canonPercentText(
                          _profileCanonRead, _profileCanonTotal),
                    ),
                  ],
                ),
                if (_account.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        // 账号名最多 10 字符（编辑资料页限制），单行展示、超长省略。
                        child: Text('@$_account',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13, color: _textHint)),
                      ),
                      // 累积读经时长：位于原阅藏百分比位置（@账号行最右侧）。
                      const SizedBox(width: 8),
                      const _ClockIcon(),
                      const SizedBox(width: 2),
                      Text(
                        '累积读经${_formatReadingTime(_profileReadingSeconds)}',
                        maxLines: 1,
                        style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF70867A),
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
                // 签名：未设置时默认展示固定法语（用户可自行修改）。
                // 初始加载完成前不展示，避免「默认法语 → 用户签名」的闪变。
                if (!_loading) ...[
                  const SizedBox(height: 6),
                  Text(
                    _displayTagline,
                    style: const TextStyle(
                        fontSize: 14, color: _textSec, height: 1.4),
                  ),
                ],
                // 注册加入时间。
                if (_profileJoinTime > 0) ...[
                  const SizedBox(height: 8),
                  Text(
                    '${_joinDateText(_profileJoinTime)}加入',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: _textHint),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_isBlocked && !_isSelf) {
      return _buildBlockedPlaceholder();
    }
    if (_tab == 2) return _buildReadingTab();
    if (_tab == 3) return _buildCheckinTab();
    if (_notes.isEmpty) {
      return RefreshIndicator(
        color: _gold,
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
              child: Column(
                children: [
                  Icon(Icons.spa_outlined,
                      size: 48, color: _textHint.withValues(alpha: 0.6)),
                  const SizedBox(height: 14),
                  const Text('还没有公开分享',
                      style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: _text)),
                  const SizedBox(height: 6),
                  Text('$_displayName 暂未公开发布笔记',
                      style: const TextStyle(fontSize: 13, color: _textSec)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return _tab == 0 ? _buildPostsTab() : _buildRepliesTab();
  }

  List<PlazaNote> get _posts =>
      _notes.where((n) => n.repostKind != 'reply').toList();

  List<PlazaNote> get _replies =>
      _notes.where((n) => n.repostKind == 'reply').toList();

  /// 帖子 Tab：自己的帖子 + 转发（引用转发），与「我的菜单页 → 帖子」同款样式。
  /// 自己主页的置顶帖子排在最前；他人主页保持服务端顺序。
  Widget _buildPostsTab() {
    final posts = List<PlazaNote>.of(_posts);
    if (_isOwn(widget.userId)) {
      posts.sort((a, b) {
        final ap = _pinnedIds.contains(a.id);
        final bp = _pinnedIds.contains(b.id);
        if (ap != bp) return ap ? -1 : 1;
        return 0;
      });
    }
    if (posts.isEmpty) {
      return const Center(
        child: Text('还没有帖子', style: TextStyle(fontSize: 14, color: _textHint)),
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: _buildScrollListener(
        ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
          itemCount: posts.length,
          itemBuilder: (context, index) => _buildNoteRow(posts[index], posts),
        ),
      ),
    );
  }

  /// 回复 Tab：按原贴分组，原贴一次 + 头像连线串起所有回复（与「我的菜单页 → 回复」一致）。
  Widget _buildRepliesTab() {
    final replies = _replies;
    if (replies.isEmpty) {
      return const Center(
        child: Text('还没有回复', style: TextStyle(fontSize: 14, color: _textHint)),
      );
    }
    final groups = _buildReplyGroups(replies);
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: _buildScrollListener(
        ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.only(top: 4, bottom: 32),
          itemCount: groups.length,
          itemBuilder: (context, index) {
            final g = groups[index];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (index > 0)
                  const Divider(
                      height: 1,
                      thickness: 0.6,
                      color: Color(0xFFD8CCBC)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: _buildReplyGroupCard(g.$1, g.$2),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 滚动到底部时自动加载下一页。
  Widget _buildScrollListener(Widget child) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
          _loadMore();
        }
        return false;
      },
      child: child,
    );
  }

  /// 精读 Tab：对方最近在读的经书（点击进入经书讨论页，未开讨论时显示「还没有讨论」）。
  Widget _buildReadingTab() {
    final data = _homeData;
    if (!_homeLoaded) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_homeError) {
      return _tabPlaceholder(
        Icons.cloud_off,
        '精读信息加载失败',
        '请检查网络后下拉重试',
        onRefresh: _loadHomeData,
      );
    }
    if (data == null || !data.readingAllowed) {
      return _tabPlaceholder(
        Icons.lock_outline,
        '对方未开启精读分享',
        '对方在「精读经文」中开启「允许」后可见',
      );
    }
    if (data.reading.isEmpty) {
      return _tabPlaceholder(
        Icons.auto_stories_outlined,
        '还没有精读记录',
        '$_displayName 暂无精读经文',
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _loadHomeData,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        itemCount: data.reading.length,
        itemBuilder: (context, i) {
          final s = data.reading[i];
          return _buildReadingRow(
            s,
            isCurrent: s.title == data.currentLockedTitle,
          );
        },
      ),
    );
  }

  Widget _buildReadingRow(UserReadingSutra s, {bool isCurrent = false}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: isCurrent ? const Color(0xFF70867A) : _border,
            width: isCurrent ? 1.4 : 0.8),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  SutraDiscussionPage(title: s.title, filePath: s.filePath),
            ),
          );
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: const Color(0xFF70867A).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(Icons.menu_book_rounded,
                          size: 18, color: Color(0xFF70867A)),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        s.title,
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: _text,
                          height: 1.4,
                        ),
                      ),
                    ),
                    if (isCurrent) ...[
                      const SizedBox(width: 6),
                      Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF70867A),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('当前锁定',
                                style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white,
                                    height: 1.2)),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('查看经书讨论',
                        style: TextStyle(fontSize: 12, color: _textHint)),
                    SizedBox(width: 2),
                    Icon(Icons.chevron_right, size: 18, color: _textHint),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 功课 Tab：对方的打卡功课设置与目标设置（只读）。
  Widget _buildCheckinTab() {
    final data = _homeData;
    if (!_homeLoaded) {
      return const Center(child: CircularProgressIndicator(color: _gold));
    }
    if (_homeError) {
      return _tabPlaceholder(
        Icons.cloud_off,
        '功课信息加载失败',
        '请检查网络后下拉重试',
        onRefresh: _loadHomeData,
      );
    }
    if (data == null || !data.checkinAllowed) {
      return _tabPlaceholder(
        Icons.lock_outline,
        '对方未开启功课分享',
        '对方在「打卡目标」中开启「允许他人查看我的功课」后可见',
      );
    }
    final tasks = _buildCheckinTaskLines(data.checkin);
    final goals = _buildCheckinGoalEntries(data.checkin);
    final stats = _buildHistoryStatEntries(data.checkin);
    if (tasks.isEmpty && goals.isEmpty && stats.isEmpty) {
      return _tabPlaceholder(
        Icons.event_note_outlined,
        '对方还没有设置功课',
        '$_displayName 暂未设置打卡功课与目标',
      );
    }
    return RefreshIndicator(
      color: _gold,
      onRefresh: _loadHomeData,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 32),
        children: [
          if (stats.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.only(top: 6, bottom: 12),
              child: CheckInHistoryStats(entries: stats),
            ),
          ],
          if (tasks.isNotEmpty) ...[
            _sectionTitle('功课设置'),
            ...tasks.map((t) => _buildTaskLine(t)),
          ],
          if (goals.isNotEmpty) ...[
            _sectionTitle('目标设置'),
            ...goals.map((g) => _buildGoalCard(g)),
          ],
        ],
      ),
    );
  }

  /// 由对方同步来的打卡 prefs 生成功课设置行文案。
  List<String> _buildCheckinTaskLines(Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final lines = <String>[];
    for (final e in _decodeStringList(checkin['setting_meditation_minutes'])) {
      if (e.trim().isNotEmpty) lines.add('静坐 ${e.trim()}分钟');
    }
    for (final e in _decodeNamedItems(checkin['setting_reading_titles'])) {
      if (e.$1.isNotEmpty) {
        lines.add('诵经 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
      }
    }
    for (final e in _decodeNamedItems(checkin['setting_mantra_items'])) {
      if (e.$1.isNotEmpty) {
        lines.add('持咒 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}遍' : ''}');
      }
    }
    for (final e in _decodeNamedItems(checkin['setting_buddha_items'])) {
      if (e.$1.isNotEmpty) {
        lines.add('称名 ${e.$1}${e.$2.isNotEmpty ? ' ${e.$2}声' : ''}');
      }
    }
    for (final e in _decodeStringList(checkin['setting_copying_titles'])) {
      if (e.trim().isNotEmpty) lines.add('抄经 ${e.trim()}');
    }
    for (final e in _decodeCustomTypes(checkin['custom_checkin_types'])) {
      if (e.label.isNotEmpty) {
        lines.add(
            '${e.label} ${e.count.trim().isEmpty ? '0' : e.count.trim()}${e.unit}');
      }
    }
    return lines;
  }

  /// 由对方同步来的打卡 prefs 生成目标卡片数据。
  List<_GoalEntry> _buildCheckinGoalEntries(Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final goals = _decodeMap(checkin['checkin_goals']);
    final totals = <String, double>{};
    for (final r in _decodeMapList(checkin['checkin_records'])) {
      final key = r['type']?.toString() ?? '';
      if (key.isEmpty) continue;
      final amt = double.tryParse((r['amount'] ?? 1).toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
    }
    final customs = _decodeCustomTypes(checkin['custom_checkin_types']);
    final typeInfo = <String, ({String label, String unit})>{
      'meditation': (label: '静坐', unit: '分钟'),
      'reading': (label: '诵经', unit: '遍'),
      'mantra': (label: '持咒', unit: '遍'),
      'buddha': (label: '称名', unit: '声'),
      'copying': (label: '抄经', unit: '篇'),
      for (final c in customs) c.key: (label: c.label, unit: c.unit),
    };
    final out = <_GoalEntry>[];
    goals.forEach((k, v) {
      final info = typeInfo[k];
      if (info == null) return;
      final goal = double.tryParse(v.toString()) ?? 0;
      out.add(_GoalEntry(
          label: info.label,
          unit: info.unit,
          goal: goal,
          total: totals[k] ?? 0));
    });
    return out;
  }

  /// 历史统计条目：各类型自使用以来累计的总量（与目标无关）。
  List<CheckInStatEntry> _buildHistoryStatEntries(
      Map<String, dynamic>? checkin) {
    if (checkin == null) return [];
    final totals = <String, double>{};
    for (final r in _decodeMapList(checkin['checkin_records'])) {
      final key = r['type']?.toString() ?? '';
      if (key.isEmpty) continue;
      final amt = double.tryParse((r['amount'] ?? 1).toString()) ?? 1;
      totals[key] = (totals[key] ?? 0) + amt;
    }
    final customs = _decodeCustomTypes(checkin['custom_checkin_types']);
    final typeInfo = <String, ({String label, String unit})>{
      'meditation': (label: '静坐', unit: '分钟'),
      'reading': (label: '诵经', unit: '遍'),
      'mantra': (label: '持咒', unit: '遍'),
      'buddha': (label: '称名', unit: '声'),
      'copying': (label: '抄经', unit: '篇'),
      for (final c in customs) c.key: (label: c.label, unit: c.unit),
    };
    final out = <CheckInStatEntry>[];
    totals.forEach((k, v) {
      final info = typeInfo[k];
      if (info == null) return;
      out.add(CheckInStatEntry(label: info.label, unit: info.unit, total: v));
    });
    return out;
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(title,
          style: const TextStyle(
              fontSize: 15, fontWeight: FontWeight.w700, color: _text)),
    );
  }

  Widget _buildTaskLine(String line) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle_outline,
              size: 16, color: Color(0xFF71867A)),
          const SizedBox(width: 8),
          Expanded(
            child:
                Text(line, style: const TextStyle(fontSize: 14, color: _text)),
          ),
        ],
      ),
    );
  }

  Widget _buildGoalCard(_GoalEntry g) {
    final progress = g.goal > 0 ? (g.total / g.goal).clamp(0.0, 1.0) : 0.0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(g.label,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600, color: _text)),
              const Spacer(),
              if (g.goal > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12)),
                  child: Text('目标 ${_fmtNum(g.goal)}${g.unit}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: _gold,
                          fontWeight: FontWeight.w600)),
                )
              else
                Text('未设置目标', style: TextStyle(fontSize: 12, color: _textHint)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: _border,
              valueColor: AlwaysStoppedAnimation<Color>(
                  g.goal > 0 ? _primary : _textHint),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text('已累计 ${_fmtNum(g.total)} ${g.unit}',
                  style: const TextStyle(fontSize: 12, color: _textSec)),
              const Spacer(),
              if (g.goal > 0)
                Text('${(progress * 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _primary)),
            ],
          ),
        ],
      ),
    );
  }

  /// 已屏蔽用户：帖子/回复/精读/功课所有栏目统一显示该占位（如需查看请取消屏蔽）。
  Widget _buildBlockedPlaceholder() {
    return RefreshIndicator(
      color: _gold,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
            child: Column(
              children: [
                const Icon(Icons.block, size: 48, color: _textHint),
                const SizedBox(height: 14),
                const Text('已屏蔽用户',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const SizedBox(height: 6),
                const Text('如需查看，请取消屏蔽。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 空态占位：隐私未开启 / 无数据 / 加载失败（可下拉重试）。
  Widget _tabPlaceholder(IconData icon, String title, String subtitle,
      {Future<void> Function()? onRefresh}) {
    return RefreshIndicator(
      color: _gold,
      onRefresh: onRefresh ?? () async {},
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60, horizontal: 32),
            child: Column(
              children: [
                Icon(icon, size: 48, color: _textHint.withValues(alpha: 0.6)),
                const SizedBox(height: 14),
                Text(title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _text)),
                const SizedBox(height: 6),
                Text(subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 13, color: _textSec)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtNum(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toStringAsFixed(1);
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或数组 → 字符串列表。
  List<String> _decodeStringList(Object? v) {
    if (v is List) return v.map((e) => e.toString()).toList();
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d.map((e) => e.toString()).toList();
      } catch (_) {}
    }
    return [];
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或数组 → Map 列表。
  List<Map<String, dynamic>> _decodeMapList(Object? v) {
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) {
          return d
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
      } catch (_) {}
    }
    return [];
  }

  /// 对方同步来的 prefs 值解析：JSON 字符串或 Map → Map。
  Map<String, dynamic> _decodeMap(Object? v) {
    if (v is Map) return Map<String, dynamic>.from(v);
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is Map) return Map<String, dynamic>.from(d);
      } catch (_) {}
    }
    return {};
  }

  /// 名称 + 次数项解析（兼容纯字符串列表 / {name,count} 列表，每个元素只解析一次）。
  List<(String, String)> _decodeNamedItems(Object? v) {
    final out = <(String, String)>[];
    final list = _decodeRawList(v);
    for (final e in list) {
      if (e is Map) {
        out.add(((e['name'] ?? '').toString(), (e['count'] ?? '').toString()));
      } else {
        final s = e.toString().trim();
        if (s.isNotEmpty) out.add((s, ''));
      }
    }
    return out;
  }

  /// 解析为原始列表（兼容 JSON 字符串 / 已解析 List），其它返回空。
  List<dynamic> _decodeRawList(Object? v) {
    if (v is List) return v;
    if (v is String) {
      try {
        final d = jsonDecode(v);
        if (d is List) return d;
      } catch (_) {}
    }
    return const [];
  }

  /// 自定义打卡类型解析：{key, label, unit, count}。
  List<_CustomTypeInfo> _decodeCustomTypes(Object? v) {
    return [
      for (final m in _decodeMapList(v))
        _CustomTypeInfo(
          key: (m['key'] ?? '').toString(),
          label: (m['label'] ?? '').toString(),
          unit: (m['unit'] ?? '遍').toString(),
          count: (m['count'] ?? '').toString(),
        ),
    ];
  }

  /// 按最顶层原贴分组：沿 repostOf 逐级向上找到根，根优先取「非回复类型的原贴」。
  /// 关键修复：父子关系查找使用全量 _notes（含帖子 + 回复）作为池，而不是只在
  /// replies 参数（只有 reply 类型）里查。对于 a→b→c 多级回复链，即使中间回复 b
  /// 被本地移除，只要原贴 a 仍在 _notes 中，就能正确把 c 挂到 a 下面，避免
  /// c 误被当作 root 然后渲染成「空占位同修 + 空内容」的原贴卡片。
  List<(PlazaNote, List<PlazaNote>)> _buildReplyGroups(
      List<PlazaNote> replies) {
    // 全量池：包含 _notes 中所有帖子 + 回复，用于 repostOf 逐级回溯
    final poolById = {for (final n in _notes) n.id: n};
    for (final n in replies) {
      poolById[n.id] = n;
    }
    final children = <String, List<PlazaNote>>{};
    final rootIds = <String>[];
    for (final n in replies) {
      var topId = n.repostOf;
      var guard = 0;
      // 在全量池内沿 repostOf 逐级向上回溯到最顶
      while (topId.isNotEmpty && poolById.containsKey(topId) && guard < 30) {
        final parent = poolById[topId]!;
        // 父节点还有 repostOf 且池中能查到，继续向上
        if (parent.repostOf.isNotEmpty && poolById.containsKey(parent.repostOf)) {
          topId = parent.repostOf;
        } else {
          break;
        }
        guard++;
      }
      // 如果顶部 id 不在池中（对应中间回复已被删除 / 原贴不属于当前用户），
      // 退而求其次：用这条回复自己作为 root，并交给渲染层的 ReplyThread
      // 通过云端异步查找缺失的父节点。
      if (topId.isEmpty || !poolById.containsKey(topId)) {
        topId = n.id;
      }
      if (!children.containsKey(topId)) {
        rootIds.add(topId);
      }
      children.putIfAbsent(topId, () => []).add(n);
    }

    List<PlazaNote> collect(String nodeId, Set<String> visited) {
      if (visited.contains(nodeId)) return const <PlazaNote>[];
      visited.add(nodeId);
      final subs = children[nodeId] ?? const <PlazaNote>[];
      final out = <PlazaNote>[];
      for (final c in subs) {
        out.add(c);
        out.addAll(collect(c.id, visited));
      }
      return out;
    }

    return [
      for (final rid in rootIds)
        (poolById[rid] ?? replies.firstWhere((r) => r.id == rid),
         collect(rid, {}))
    ];
  }

  Widget _buildNoteRow(PlazaNote note, List<PlazaNote> all) {
    final isMine = _isOwn(note.ownerUserId);
    return PostFeedRow(
      note: note,
      onReplyPosted: _load,
      onTap: () => _openNote(note),
      pinned: _pinnedIds.contains(note.id),
      onTogglePin: isMine ? () => _togglePin(note) : null,
      onEdit: isMine ? () => _editOwnNote(note) : null,
      onDelete: isMine ? () => _deleteOwnNote(note) : null,
      onMore: (n) => _showNoteMenu(n),
      showFollowButton: false,
    );
  }

  /// 回复分组卡片：根帖在上 + 头像连线 + 其下回复链。
  Widget _buildReplyGroupCard(PlazaNote root, List<PlazaNote> replies) {
    final rootWidget = _buildNoteRow(root, _notes);
    if (replies.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: rootWidget,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            // 连接线：原贴头像底部 → 下面第一个回复头像之间。
            // top:62 = 头像区顶内边距(12) + 头像高(44) + 线上端留白(6)；
            // bottom:6 = 线下端距 ReplyChain 首个头像 6px。
            Positioned(
              left: 21,
              top: 62,
              bottom: 6,
              child: Container(width: 1, color: const Color(0xFFC9C9C9)),
            ),
            rootWidget,
          ],
        ),
        ReplyChain(
          replies: replies,
          pinnedIds: _pinnedIds,
          parentAccounts: {
            root.id: root.authorAccount,
            for (final r in replies) r.id: r.authorAccount,
          },
          onComment: (n) => replyToNote(context, n, _load),
          onLike: (n) => likeTargetNote(context, n, _load),
          onRepost: (n) => forwardNote(context, n, _load),
          onMore: (n) => _showNoteMenu(n),
        ),
      ],
    );
  }

  /// 笔记三点菜单：自己的显示置顶/编辑/删除，他人显示关注/屏蔽。
  Future<void> _showNoteMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (!_isOwn(note.ownerUserId)) {
      if (me != null && note.ownerUserId.isNotEmpty) {
        await showMoreMenu(context, note.ownerUserId, note.authorName);
        // 屏蔽/关注后刷新，让被屏蔽用户的主页立即变为「已屏蔽」占位。
        if (mounted) setState(() {});
      }
      return;
    }
    final pinned = _pinnedIds.contains(note.id);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(note.authorName,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            const Divider(height: 1, color: _border),
            postMenuItem(ctx, 'pin', Icons.push_pin_outlined,
                pinned ? '取消置顶' : '置顶'),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'pin') {
      await _togglePin(note);
    } else if (choice == 'edit') {
      _editOwnNote(note);
    } else if (choice == 'delete') {
      _deleteOwnNote(note);
    }
  }

  Future<void> _editOwnNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '写下新的内容…',
        initialText: note.content,
        maxLength: 2000,
        minLines: 3,
        maxLines: 6,
        confirmText: '保存',
      ),
    );
    if (saved == null || saved.trim().isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance
          .updateSharedNote(cloudId: note.id, content: saved.trim());
      if (!mounted) return;
      _showToast(context, '已更新');
      _load();
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  Future<void> _deleteOwnNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: const Text('删除后帖子将从菩提空间移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除',
                style: TextStyle(
                    color: Color(0xFFC0392B), fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteCloudNote(note.id);
      if (!mounted) return;
      // 先乐观移除，让界面立即响应删除动作。
      // 然后调用 _load() 从云端重新拉取全量笔记——对「回复的回复」多级链，
      // 本地简单 remove 无法正确修复分组根节点（中间回复删后，原贴a会找不到），
      // 必须通过云端最新数据重建才能保证 a 正常显示、子回复归组正确。
      setState(() => _notes.removeWhere((n) => n.id == note.id));
      _showToast(context, '已删除');
      await _load();
    } catch (e) {
      if (mounted) _showToast(context, e.toString());
    }
  }

  /// 加入时间格式：x年x月x日。
  String _joinDateText(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}年${t.month}月${t.day}日';
  }

  /// 读经时长格式化：统一「x时x分」短格式（0 显示 0时0分，与修学主页精读卡同款）。
  String _formatReadingTime(int seconds) {
    final hours = seconds ~/ 3600;
    final minutes = (seconds % 3600) ~/ 60;
    return '$hours时$minutes分';
  }

  /// 展示的签名：未设置签名时，他人主页默认显示固定法语。
  String get _displayTagline {
    if (_profileTagline.isNotEmpty) return _profileTagline;
    return '安忍不动，犹如大地；静虑深密，犹如密藏。';
  }

  void _openNote(PlazaNote note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: note.id)),
    ).then((_) {
      if (mounted) _load();
    });
  }
}

/// 用户主页的「帖子/回复/精读/功课」吸顶 tab。
class _UserTabsDelegate extends SliverPersistentHeaderDelegate {
  final int tab;
  final ValueChanged<int> onChanged;
  static const double _height = 48;
  const _UserTabsDelegate({required this.tab, required this.onChanged});

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return ColoredBox(
      color: _bg,
      child: SizedBox(
        height: _height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              for (final (i, label) in const [
                (0, '帖子'),
                (1, '回复'),
                (2, '精读'),
                (3, '功课'),
              ])
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => onChanged(i),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Column(
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight:
                                  tab == i ? FontWeight.w600 : FontWeight.w400,
                              color: tab == i ? _text : _textSec,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            width: 36,
                            height: 3,
                            decoration: BoxDecoration(
                              color: tab == i ? _gold : Colors.transparent,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _UserTabsDelegate oldDelegate) =>
      oldDelegate.tab != tab;
}

/// 他人主页目标卡片数据。
class _GoalEntry {
  final String label;
  final String unit;
  final double goal;
  final double total;
  const _GoalEntry({
    required this.label,
    required this.unit,
    required this.goal,
    required this.total,
  });
}

/// 他人主页自定义打卡类型信息。
class _CustomTypeInfo {
  final String key;
  final String label;
  final String unit;
  final String count;
  const _CustomTypeInfo({
    required this.key,
    required this.label,
    required this.unit,
    required this.count,
  });
}

/// 纯色填充小钟图标：使用 assets 下的 ic_clock.png 图片。
class _ClockIcon extends StatelessWidget {
  const _ClockIcon();

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/ic_clock.png',
      width: 12,
      height: 12,
      fit: BoxFit.contain,
    );
  }
}
