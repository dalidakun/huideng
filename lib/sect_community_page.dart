import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'custom_tab_store.dart';
import 'loading_widgets.dart';
import 'login_page.dart';
import 'my_page.dart';
import 'note_detail_page.dart';
import 'sect_community_texts.dart';
import 'sect_page.dart';
import 'text_input_sheet.dart';
import 'user_avatar.dart';

Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;
Color get _divider => AppPalette.p.divider;

/// 社区系的一组本色：本页 banner/tab 指示条直接用它；宗门详情页的「进入社区」圆钮
/// 用它向白色提亮三成的浅版（原色压在水墨图上太重），色系仍同源。
/// 素白外观用绿，米黄用赭。
const Color kCommunityPlain = Color(0xFF5D7C5A);
const Color kCommunityWarm = Color(0xFFD3A069);

Color communityTone(bool isPlain) => isPlain ? kCommunityPlain : kCommunityWarm;

/// 成员头像显示几个：一个成员都没有时也放 1 个占位，
/// 1~5 就照实显示几个，到 5 封顶（再多就压不下去了）。
int communityAvatarCount(int memberCount) =>
    memberCount <= 0 ? 1 : (memberCount > 5 ? 5 : memberCount);

/// 加入状态的本地落库前缀，后缀接 [SectInfo.name]。
/// 后端还没有社区成员云函数，这一版只在本地记忆，接入时只改 [_toggleJoin]。
const String kCommunityJoinedKeyPrefix = 'sect_community_joined_';

/// 成员头像的纯逻辑（页面按「最近发言倒序的作者 id」调它）：
/// 去重保序；[joined] 为真且 [selfId] 有值时把自己排最前（刚加入的就是最新的）；
/// 最后封顶 5 个——再多就压不下了。
List<String> communityRecentMembers(
  List<String> postedAuthorsByLatest, {
  String? selfId,
  bool joined = false,
}) {
  final ids = <String>[];
  for (final id in postedAuthorsByLatest) {
    if (id.isEmpty || ids.contains(id)) continue;
    ids.add(id);
  }
  final me = joined ? selfId : null;
  if (me != null && me.isNotEmpty) {
    ids.remove(me);
    ids.insert(0, me);
  }
  return ids.take(5).toList(growable: false);
}

/// 栏目社区页：banner + 栏目名 + 社区介绍 + 成员行 + 「热门/最新/规则」+ 帖子流。
///
/// 帖子用 [PlazaNote.community] 字段归属（云函数按它精确过滤），
/// 正文里不带任何 `#话题` 前缀——发出来的就是一条普通帖子，
/// 只在菩提空间等列表里正文前挂一枚可点的社区小标签。
/// 这样社区页有帖子、广场照常显示，又不会把 20 个「xx社区」顶进话题榜。
class SectCommunityPage extends StatefulWidget {
  final SectInfo sect;

  const SectCommunityPage({super.key, required this.sect});

  @override
  State<SectCommunityPage> createState() => _SectCommunityPageState();
}

class _SectCommunityPageState extends State<SectCommunityPage> {
  /// 0 热门（云端热度序）/ 1 最新（按发帖时间倒序）/ 2 规则
  int _tab = 0;

  List<PlazaNote> _notes = [];
  bool _loading = true;
  bool _failed = false;

  bool _introOpen = false;
  bool _joined = false;

  /// 已收藏 = 本社区躺在菩提空间的「自定义列表」里。
  /// 数据在 [CustomTabStore]（跟菩提空间面板同一份），改了那边立刻同步。
  bool _starred = false;

  /// 本社区发过帖的人 = 已加入的成员，按最近发言倒序去重。
  /// 后端还没有成员云函数，「发帖即加入」是目前唯一真实的成员信号。
  List<String> get _postedMemberIds {
    final sorted = [..._notes]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final ids = <String>[];
    for (final n in sorted) {
      if (n.ownerUserId.isEmpty || ids.contains(n.ownerUserId)) continue;
      ids.add(n.ownerUserId);
    }
    return ids;
  }

  /// 当前登录用户 id；没登录为 null。
  String? get _myUserId =>
      AuthService.instance.currentUser.value?.id ??
      AuthService.instance.cachedUserId;

  /// 全体成员 = 发过帖的人 ∪（本机已加入时的自己）。
  /// 用集合算，自己既发过帖又点过加入也不会被数两遍。
  Set<String> get _memberIdSet {
    final ids = {..._postedMemberIds};
    if (_joined) {
      final me = _myUserId;
      if (me != null && me.isNotEmpty) ids.add(me);
    }
    return ids;
  }

  /// 展示用的成员数。
  int get _memberCount => _memberIdSet.length;

  /// 头像用的「最新成员」：本机自己排最前（刚加入的那个人就是最新的），
  /// 其余按最近发言倒序，最多取 5 个。
  List<String> get _recentMemberIds => communityRecentMembers(
        _postedMemberIds,
        selfId: _myUserId,
        joined: _joined,
      );

  /// 社区 key = `{栏目名}社区`，如「天台宗社区」。
  /// 既是发布时写进帖子的 [PlazaNote.community]，也是正文里挂的那枚小标签。
  String get _community => '${widget.sect.name}社区';

  bool get _isPlain => AppPalette.instance.isPlain;

  Color get _tone => communityTone(_isPlain);

  @override
  void initState() {
    super.initState();
    _load();
    _restoreJoinState();
    _restoreStarState();
    // 星标可能在别处被改（菩提空间的列表里把社区移走），改完立刻同步点亮态。
    CustomTabStore.revision.addListener(_restoreStarState);
  }

  @override
  void dispose() {
    CustomTabStore.revision.removeListener(_restoreStarState);
    super.dispose();
  }

  // ───────────────────────── 数据 ─────────────────────────

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _failed = false;
      });
    }
    try {
      final (list, _) = await CloudNotesService.instance
          .getCommunityNotes(_community, pageSize: 100);
      // 双保险：只留本社区的帖子，菩提空间的普通帖绝不串进来。
      // 云函数还没重新部署时服务端的 community 过滤不生效，这里也能兜住。
      final own =
          list.where((n) => n.community == _community).toList(growable: false);
      // 作者头像/账号兜底补齐失败时退回原列表，不让整页变错误态。
      List<PlazaNote> notes;
      try {
        notes = await CloudNotesService.instance.enrichFeedAuthors(own);
      } catch (_) {
        notes = own;
      }
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _restoreJoinState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(kCommunityJoinedKeyPrefix + widget.sect.name) ??
          false;
      if (!mounted || v == _joined) return;
      setState(() => _joined = v);
    } catch (_) {}
  }

  Future<void> _toggleJoin() async {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    final next = !_joined;
    setState(() => _joined = next);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(kCommunityJoinedKeyPrefix + widget.sect.name, next);
    } catch (_) {}
    // 不另弹提示：按钮文案（加入 → 已加入）与左边成员数已经当场变了，
    // 再盖一条 SnackBar 反而把帖子流遮住。
  }

  Future<void> _restoreStarState() async {
    try {
      final on = await CustomTabStore.isStarred(_community);
      if (!mounted || on == _starred) return;
      setState(() => _starred = on);
    } catch (_) {}
  }

  /// 星标：把本社区收进菩提空间的自定义列表，再点一次移出。
  /// 改的是列表本身（不是收藏表），所以从列表点进去就是本社区。
  Future<void> _toggleStar() async {
    final next = !_starred;
    setState(() => _starred = next);
    try {
      await CustomTabStore.setStarred(_community, next);
      if (!mounted) return;
      final tab = (await CustomTabStore.read())['name'];
      _toast(next ? '已添加到「$tab」' : '已从「$tab」移除');
    } catch (e) {
      if (!mounted) return;
      setState(() => _starred = !next);
      _toast('操作失败：$e');
    }
  }

  /// 分享本社区：交给系统分享面板，微信等装了的 App 都能选。
  /// 文案沿用 App 里帖子分享的格式，识别度一致。
  Future<void> _shareCommunity() async {
    final sect = widget.sect;
    final intro = (kCommunityIntros[sect.name] ?? '').trim();
    final first = intro.split(RegExp(r'[。\n]')).first.trim();
    final lead = first.isEmpty ? '' : '$first。';
    final head = lead.isEmpty
        ? '我发现了一个「${sect.name}」社区'
        : '我发现了一个「${sect.name}」社区：$lead';
    final text = '$head\n'
        '———来自【燃灯】App\n'
        '燃一盏灯，看见自己，照亮别人\n'
        '点击进入八千大藏经世界\n'
        '下载链接：';
    try {
      await SharePlus.instance.share(ShareParams(text: text));
    } catch (e) {
      if (!mounted) return;
      _toast('分享失败：$e');
    }
  }

  /// 吐提示统一走这里：`context` 只在同步方法里引用，
  /// 免得 `await` 之后再直接用它触发 use_build_context_synchronously。
  void _toast(String text) {
    if (!mounted) return;
    showPostToast(context, text);
  }

  // ───────────────────────── 交互 ─────────────────────────

  void _promptLogin() {
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  void _openNote(PlazaNote n) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteDetailPage(noteId: n.id)),
    ).then((_) {
      if (mounted) _load(silent: true);
    });
  }

  void _openCompose() {
    if (!AuthService.instance.isLoggedIn) {
      _promptLogin();
      return;
    }
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '发布帖子',
        // 不给提示语：这里是纯正文框，没有任何 # 话题前缀可提示。
        hint: '',
        maxLength: 500,
        minLines: 3,
        maxLines: 10,
        confirmText: '发表',
      ),
    ).then((content) {
      if (content != null && content.isNotEmpty) _publish(content);
    });
  }

  Future<void> _publish(String content) async {
    try {
      await CloudNotesService.instance.publishNote(
        title: '',
        content: content,
        community: _community,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已发布')));
      setState(() => _tab = 0);
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('发布失败：$e')));
    }
  }

  /// 这条帖子是不是本机这个人发的：决定三点菜单走「编辑/删除」还是「关注/屏蔽」。
  bool _isMine(PlazaNote note) {
    final me = AuthService.instance.currentUser.value;
    final cached = AuthService.instance.cachedUserId;
    return (me != null && note.ownerUserId == me.id) ||
        (cached != null && note.ownerUserId == cached);
  }

  /// 行内三点菜单，与菩提空间同款：他人走 [showMoreMenu]（关注/屏蔽），
  /// 自己走「编辑 / 删除」。回复行（[ReplyThread]）由它兜底。
  Future<void> _showRowMenu(PlazaNote note) async {
    final me = AuthService.instance.currentUser.value;
    if (me == null || note.ownerUserId != me.id) {
      if (me != null && note.ownerUserId.isNotEmpty) {
        await showMoreMenu(context, note.ownerUserId, note.authorName);
        // 屏蔽/关注后刷新，让被屏蔽用户的帖子立刻从社区消失。
        if (mounted) _load(silent: true);
      }
      return;
    }
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
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
            ),
            Divider(height: 1, color: _border),
            postMenuItem(ctx, 'edit', Icons.edit_outlined, '编辑'),
            postMenuItem(ctx, 'delete', Icons.delete_outline, '删除'),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice == 'edit') {
      await _editNote(note);
    } else if (choice == 'delete') {
      await _deleteNote(note);
    }
  }

  /// 编辑自己在社区发的帖子。
  Future<void> _editNote(PlazaNote note) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SheetTextInput(
        title: '编辑帖子',
        hint: '',
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
      showPostToast(context, '已更新');
      await _load(silent: true);
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  /// 删除自己在社区发的帖子。
  Future<void> _deleteNote(PlazaNote note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除帖子',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后帖子将从社区移除，且无法恢复。确定删除吗？',
            style: TextStyle(fontSize: 14, color: _textSec)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
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
      showPostToast(context, '已删除');
      await _load(silent: true);
    } catch (e) {
      if (mounted) showPostToast(context, e.toString());
    }
  }

  // ───────────────────────── 页面 ─────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        top: true,
        child: RefreshIndicator(
          color: _gold,
          onRefresh: () => _load(silent: true),
          child: NestedScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            headerSliverBuilder: (context, innerScrolled) => [
              SliverToBoxAdapter(child: _buildHeader()),
              SliverPersistentHeader(
                pinned: true,
                delegate: _FixedHeaderDelegate(child: _buildTabBar()),
              ),
            ],
            body: _tab == 2 ? _buildRules() : _buildFeed(),
          ),
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: 42,
          height: 42,
          child: FloatingActionButton(
            heroTag: 'sect_community_fab',
            onPressed: _openCompose,
            // 与「我的」页发帖浮钮同款配色，只换 heroTag。
            backgroundColor:
                _isPlain ? const Color(0xFF1A1A1A) : const Color(0xFF71867A),
            elevation: 8,
            highlightElevation: 12,
            shape: const CircleBorder(),
            child: Image.asset(
              'assets/images/write.png',
              width: 21,
              height: 21,
            ),
          ),
        ),
      ),
    );
  }

  /// 头部：banner + 栏目名 + 社区介绍（可展开）+ 成员行 + 分割线。
  Widget _buildHeader() {
    final intro = kCommunityIntros[widget.sect.name] ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBanner(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            '${widget.sect.name}社区',
            style: TextStyle(
              fontSize: 23,
              fontWeight: FontWeight.w700,
              color: _text,
              letterSpacing: 1,
            ),
          ),
        ),
        if (intro.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 9, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _introOpen = !_introOpen),
                  child: Text(
                    intro,
                    style: TextStyle(
                      fontSize: 13,
                      color: _textSec,
                      height: 1.75,
                      letterSpacing: 0.3,
                    ),
                    maxLines: _introOpen ? null : 2,
                    overflow: _introOpen ? null : TextOverflow.ellipsis,
                  ),
                ),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _introOpen = !_introOpen),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _introOpen ? '收起' : '展开全文',
                      style: TextStyle(
                        fontSize: 12,
                        color: _textHint,
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 4),
        _buildMembersRow(),
        Divider(height: 1, color: _border),
      ],
    );
  }

  /// 顶部横幅：本色渐变 + 山水底纹 + 栏目图标 + 返回键。
  Widget _buildBanner() {
    final scale = widget.sect.icon.iconScale;
    return SizedBox(
      height: 150,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _tone.withValues(alpha: 0.20),
                  _tone.withValues(alpha: 0.04),
                ],
              ),
            ),
          ),
          Positioned(
            right: -14,
            bottom: -10,
            child: Opacity(
              opacity: 0.16,
              child: Image.asset(
                'assets/menpai/mih.png',
                width: 168,
                fit: BoxFit.contain,
              ),
            ),
          ),
          Center(
            child: Opacity(
              opacity: 0.55,
              child: SizedBox(
                width: 78 * scale,
                height: 78 * scale,
                child: _buildSectIcon(),
              ),
            ),
          ),
          Positioned(
            left: 8,
            top: 8,
            child: _buildBackButton(),
          ),
        ],
      ),
    );
  }

  Widget _buildBackButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => Navigator.maybePop(context),
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _card.withValues(alpha: 0.88),
            shape: BoxShape.circle,
            border: Border.all(color: _border),
          ),
          child: Icon(Icons.chevron_left, size: 26, color: _text),
        ),
      ),
    );
  }

  /// 栏目图标：与宗门菜单页同一套切图规则（法门走 assets/famen/、
  /// 宗门走 assets/menpai/、律宗没有切图改手绘）。
  Widget _buildSectIcon() {
    final gate = widget.sect.icon.gateCode;
    if (gate.isNotEmpty) {
      final suffix = _isPlain ? '' : '2';
      return Image.asset(
        'assets/famen/$gate$suffix.png',
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
      );
    }
    final code = widget.sect.icon.assetCode;
    if (code.isEmpty) {
      return CustomPaint(
        painter: GatePainter(
          color: _isPlain ? const Color(0xFF000000) : kCommunityWarm,
        ),
      );
    }
    final suffix = _isPlain ? '1' : '2';
    return Image.asset(
      'assets/menpai/$code$suffix.png',
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
    );
  }

  /// 成员行：最新成员的真实头像（叠着排开）+ 成员数 + 星标 / 分享 / 加入。
  /// 人数与头像都由 [_memberIdSet] 派生，本机加入/退出立刻反映到两边。
  Widget _buildMembersRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          _buildAvatarStack(),
          const SizedBox(width: 10),
          // 成员数吃掉右侧按钮之外的全部宽度；万一挤不下就整段等比缩小，
          // 绝不截断也不让这一行溢出（头像 5 个 + 已加入时最紧）。
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _memberCount > 999 ? '999+ 成员' : '$_memberCount 成员',
                style:
                    TextStyle(fontSize: 13, color: _textSec, letterSpacing: 0.3),
              ),
            ),
          ),
          _buildStarButton(),
          const SizedBox(width: 6),
          _buildShareButton(),
          const SizedBox(width: 6),
          _buildJoinButton(),
        ],
      ),
    );
  }

  /// 三个操作按钮统一高度：星标、分享是正圆，加入是胶囊，三者一样高才排得齐。
  static const double _actionBtnH = 32;

  /// 两个小圆钮（星标 / 分享）的共用外壳：正圆细描边，和右边的「加入」
  /// 同一套配色语言——没选中走白底灰字当配角，点亮后换成本栏本色。
  Widget _roundActionButton({
    Key? key,
    required bool active,
    required VoidCallback onTap,
    required Widget child,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          key: key,
          width: _actionBtnH,
          height: _actionBtnH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? _tone.withValues(alpha: 0.14) : _card,
            border: Border.all(
              color: active ? _tone.withValues(alpha: 0.65) : _border,
            ),
          ),
          child: child,
        ),
      ),
    );
  }

  /// 星标：点亮 = 已收进菩提空间的自定义列表。
  Widget _buildStarButton() {
    return _roundActionButton(
      key: const ValueKey('sect_community_star'),
      active: _starred,
      onTap: _toggleStar,
      child: Icon(
        _starred ? Icons.star_rounded : Icons.star_outline_rounded,
        size: 17,
        color: _starred ? _tone : _textSec,
      ),
    );
  }

  /// 分享：固定白底灰字，交给系统分享面板。
  Widget _buildShareButton() {
    return _roundActionButton(
      key: const ValueKey('sect_community_share'),
      active: false,
      onTap: _shareCommunity,
      child: Icon(Icons.ios_share_rounded, size: 17, color: _textSec),
    );
  }

  /// 头像：单个 36，每步只走 26（压掉 10px），最多 5 个。
  /// 有成员就用成员的真实头像；一个都没有时放 1 个 App 图标占位。
  static const double _avatarSize = 36;
  static const double _avatarStep = 26;

  /// 描边环宽：叠在一起时靠它分清前后两层。
  static const double _avatarRing = 2;

  Widget _buildAvatarStack() {
    final ids = _recentMemberIds;
    final count = communityAvatarCount(ids.length);
    return SizedBox(
      width: _avatarSize + _avatarStep * (count - 1),
      height: _avatarSize,
      child: Stack(
        children: [
          for (var i = 0; i < count; i++)
            Positioned(
              left: i * _avatarStep,
              top: 0,
              child: i < ids.length
                  ? _memberAvatar(ids[i])
                  : _placeholderAvatar(),
            ),
        ],
      ),
    );
  }

  /// 真实成员头像：[UserAvatar] 自带正圆裁切，外面再套一圈页面底色描边，
  /// 几个头像叠在一起才分得清是好几层。
  Widget _memberAvatar(String userId) {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _bg, width: _avatarRing),
      ),
      child: ClipOval(
        child: UserAvatar(
          userId: userId,
          radius: (_avatarSize - _avatarRing * 2) / 2,
        ),
      ),
    );
  }

  /// 占位头像（一个成员都没有时用）：正圆（[ClipOval] 裁，不靠 Container
  /// 的 clip 兜底），描边环用页面底色。
  Widget _placeholderAvatar() {
    return Container(
      width: _avatarSize,
      height: _avatarSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: _bg, width: _avatarRing),
      ),
      child: ClipOval(
        child: Image.asset('assets/images/app_icon.png', fit: BoxFit.cover),
      ),
    );
  }

  /// 加入按钮：和左边两枚圆钮同高（[_actionBtnH]），只占右边一小块。
  Widget _buildJoinButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: _toggleJoin,
        child: Container(
          key: const ValueKey('sect_community_join'),
          height: _actionBtnH,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _joined ? _card : _tone.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: _joined ? _border : _tone.withValues(alpha: 0.50),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_joined) ...[
                const Icon(Icons.check, size: 12, color: Color(0xFF5F7A62)),
                const SizedBox(width: 2),
              ],
              Text(
                _joined ? '已加入' : '加入',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  color: _joined ? _textSec : _tone,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「热门 / 最新 / 规则」：手写下划线 tab，钉在吸顶位置。
  Widget _buildTabBar() {
    return ColoredBox(
      color: _bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final (i, label) in const [
              (0, '热门'),
              (1, '最新'),
              (2, '规则'),
            ])
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (_tab == i) return;
                    setState(() => _tab = i);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: 15,
                            height: 1.2,
                            fontWeight: _tab == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: _tab == i ? _text : _textSec,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Container(
                          width: 34,
                          height: 3,
                          decoration: BoxDecoration(
                            color: _tab == i ? _tone : Colors.transparent,
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
    );
  }

  Widget _buildFeed() {
    if (_loading) {
      return const AppLoadingIndicator(message: '正在加载...');
    }
    if (_failed) {
      return AppLoadError(title: '帖子加载失败', onRetry: _load);
    }
    final notes = _visibleNotes();
    if (notes.isEmpty) return _buildEmptyFeed();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
      itemCount: notes.length,
      separatorBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Divider(height: 1, color: _divider),
      ),
      itemBuilder: (_, i) {
        final n = notes[i];
        // 与菩提空间同一套：自己的帖子给编辑/删除（三点菜单才出现），
        // 他人的走关注/屏蔽；关注按钮按「广场以浏览为主」收掉。
        final mine = _isMine(n);
        return PostFeedRow(
          note: n,
          showFollowButton: false,
          // 自己就在这个社区里，正文前再挂一枚「xx社区」是废话。
          showCommunityTag: false,
          onTap: () => _openNote(n),
          onEdit: mine ? () => _editNote(n) : null,
          onDelete: mine ? () => _deleteNote(n) : null,
          onMore: _showRowMenu,
        );
      },
    );
  }

  /// 热门：云端返回的热度衰减分倒序原样展示；
  /// 最新：同一份数据按发帖时间倒序，不额外打一次云端。
  List<PlazaNote> _visibleNotes() {
    if (_tab != 1) return _notes;
    return [..._notes]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  /// 空态：外层已经包了 [RefreshIndicator]，这里只给一张可滚的空列表，
  /// 下拉刷新仍能从这里透出去。
  Widget _buildEmptyFeed() {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 70),
        Icon(
          Icons.forum_outlined,
          size: 48,
          color: _textHint.withValues(alpha: 0.6),
        ),
        const SizedBox(height: 14),
        Center(
          child: Text(
            '还没有帖子',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _text,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            '来发第一条，聊聊你的 $_community 体会',
            style: TextStyle(fontSize: 13, color: _textSec),
          ),
        ),
        const SizedBox(height: 96),
      ],
    );
  }

  /// 「规则」tab：20 个栏目共用同一份社区规则，静态文档。
  Widget _buildRules() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 96),
      children: [
        Text(
          '社区规则',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: _text,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          kCommunityRuleIntro,
          style: TextStyle(
            fontSize: 13,
            color: _textSec,
            height: 1.75,
            letterSpacing: 0.3,
          ),
        ),
        const SizedBox(height: 16),
        for (var i = 0; i < kCommunityRules.length; i++) ...[
          _buildRuleItem(i, kCommunityRules[i]),
          if (i < kCommunityRules.length - 1)
            // 分割线与标题文字左缘对齐（序号圆 20 + 间距 8）。
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Divider(height: 22, color: _divider),
            ),
        ],
      ],
    );
  }

  /// 一条规则：不包卡片，直接序号 + 标题 + 正文，条目之间用分割线隔开。
  Widget _buildRuleItem(int index, CommunityRule rule) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _tone.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _isPlain ? kCommunityPlain : kCommunityWarm,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                rule.title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _text,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 7),
        Padding(
          // 正文与标题的首字同一条竖线（序号圆 20 + 间距 8）。
          padding: const EdgeInsets.only(left: 28),
          child: Text(
            rule.body,
            style: TextStyle(
              fontSize: 12.5,
              color: _textSec,
              height: 1.7,
              letterSpacing: 0.3,
            ),
          ),
        ),
      ],
    );
  }
}

/// 固定高度的吸顶头部：只用来钉住 tab 栏，每次都随父级重建。
class _FixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  static const double _height = 46;
  final Widget child;

  const _FixedHeaderDelegate({required this.child});

  @override
  double get minExtent => _height;

  @override
  double get maxExtent => _height;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox(height: _height, child: child);
  }

  @override
  bool shouldRebuild(covariant _FixedHeaderDelegate oldDelegate) => true;
}

/// 由社区标记（`{栏目名}社区`）反查栏目；对不上（历史帖/手改数据）返回 null。
SectInfo? sectByCommunity(String community) {
  for (final s in kSectList) {
    if ('${s.name}社区' == community) return s;
  }
  for (final g in kGateList) {
    if ('${g.name}社区' == community) return g;
  }
  return null;
}

/// 帖子前面那枚「xx社区」小标签：带颜色的底色块包小字、**不**加线框，
/// 点一下直接进该社区。菩提空间等广场列表统一用它。
class CommunityTag extends StatelessWidget {
  final String community;

  const CommunityTag({super.key, required this.community});

  @override
  Widget build(BuildContext context) {
    if (community.isEmpty) return const SizedBox.shrink();
    final tone = communityTone(AppPalette.instance.isPlain);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        final sect = sectByCommunity(community);
        if (sect == null) return;
        Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => SectCommunityPage(sect: sect)),
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          community,
          style: TextStyle(
            fontSize: 11,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: tone,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
