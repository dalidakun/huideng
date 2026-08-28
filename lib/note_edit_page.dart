import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'drafts_page.dart';
import 'login_page.dart';
import 'note_detail_page.dart';
import 'note_sutra_links.dart';

import 'app_palette.dart';
Color get _primary => AppPalette.p.primary;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _gold => AppPalette.p.accent;
class NoteEditPage extends StatefulWidget {
  final Map<String, dynamic>? note;

  /// 固定话题：从话题页新建时传入（不带 #）。发布后固定在正文开头，不可删除，
  /// 用户只能在其下方输入内容。
  final String? fixedTopic;

  /// 新建笔记时预填的正文（如「$经书名」），仅在无编辑笔记时生效。
  final String? presetContent;
  const NoteEditPage({super.key, this.note, this.fixedTopic, this.presetContent});

  @override
  State<NoteEditPage> createState() => _NoteEditPageState();
}

class _NoteEditPageState extends State<NoteEditPage> {
  late TextEditingController _contentController;
  bool _hasChanges = false;
  String? _savedId;
  late bool _shared;
  String? _cloudId;
  bool _savingCloud = false;

  // 编辑页保存成功后置 true：侧滑返回时直接弹回个人主页（跳过草稿页等中间页）。
  bool _goHomeOnPop = false;

  // 触发面板状态：@ 提及用户 / $ 引用经文 / # 话题
  List<NoteSutraLink> _sutraResults = [];
  List<UserProfile> _userResults = [];
  List<String> _topicResults = [];
  String _triggerChar = '';
  bool _panelVisible = false;
  bool _justInserted = false;
  int _triggerIndex = -1;
  Timer? _debounce;

  static final RegExp _mentionRe =
      RegExp(r'\[@([^\]]+)\]\(user:([^)]+)\)');
  static final RegExp _plainMentionRe =
      RegExp(r'@([\u4e00-\u9fa5a-zA-Z0-9_]{1,20})');
  final Map<String, String> _mentionUids = {};

  /// 从广场笔记中提取的系统话题缓存（首次搜索时拉取一次）。
  List<String> _fetchedTopics = const [];
  bool _fetchedTopicsLoaded = false;

  @override
  void initState() {
    super.initState();
    _contentController =
        TextEditingController(text: _initialContent());
    _shared = widget.note?['shared'] == true;
    _cloudId = widget.note?['cloudId'] as String?;
    _contentController.addListener(_onContentChanged);
  }

  /// 编辑框初始内容：去掉固定话题前缀，用户只能编辑话题下方的文字。
  String _initialContent() {
    var raw = widget.note?['content'] ?? '';
    final preset = widget.presetContent;
    if (widget.note == null && preset != null && preset.isNotEmpty) {
      raw = preset;
    }
    for (final m in _mentionRe.allMatches(raw.toString())) {
      _mentionUids[m.group(1)!] = m.group(2)!;
    }
    raw = raw.toString().replaceAllMapped(_mentionRe, (m) => '@${m.group(1)}');
    final topic = widget.fixedTopic;
    if (topic != null && topic.isNotEmpty) {
      final prefix = '#$topic';
      final t = raw.toString().trim();
      if (t.startsWith(prefix)) {
        raw = t.substring(prefix.length);
      } else {
        raw = t.replaceFirst(RegExp('^#*$topic\\s*'), '');
      }
    }
    return raw.toString();
  }

  /// 保存的完整正文：固定话题置于最前。
  String _fullContent() {
    var body = _contentController.text.trim();
    if (_mentionUids.isNotEmpty) {
      body = body.replaceAllMapped(_plainMentionRe, (m) {
        final uid = _mentionUids[m.group(1)!];
        return uid == null ? m.group(0)! : '[@${m.group(1)}](user:$uid)';
      });
    }
    final topic = widget.fixedTopic;
    if (topic != null && topic.isNotEmpty) {
      final prefix = '#$topic';
      final t = body;
      if (t.startsWith(prefix)) return t;
      return body.isEmpty ? prefix : '$prefix $body';
    }
    return body;
  }

  void _onContentChanged() {
    // 刚由程序插入标记产生的一次变化，不触发搜索，避免选中后立刻又弹出面板。
    if (_justInserted) {
      _justInserted = false;
      if (!_hasChanges) setState(() => _hasChanges = true);
      return;
    }
    if (!_hasChanges) setState(() => _hasChanges = true);

    final text = _contentController.text;
    final sel = _contentController.selection;
    String trigger = '';
    int triggerIndex = -1;
    String query = '';
    if (sel.isValid && sel.isCollapsed) {
      final cursor = sel.start;
      // 找光标前最近的 @ / $ / #
      var best = -1;
      var bestChar = '';
      for (final ch in const ['@', r'$', '#']) {
        final idx = cursor > 0 ? text.lastIndexOf(ch, cursor - 1) : -1;
        if (idx > best) {
          best = idx;
          bestChar = ch;
        }
      }
      if (best >= 0) {
        final insideExisting = best > 0 && text[best - 1] == '[';
        final seg = text.substring(best, cursor);
        final valid = !insideExisting &&
            !seg.substring(1).contains(RegExp(r'[\s\[\]\(\)@$#]'));
        if (valid) {
          trigger = bestChar;
          triggerIndex = best;
          query = seg.substring(1);
        }
      }
    }

    if (trigger.isEmpty) {
      if (_panelVisible || _triggerIndex >= 0) {
        setState(() {
          _sutraResults = [];
          _userResults = [];
          _topicResults = [];
          _panelVisible = false;
          _triggerChar = '';
          _triggerIndex = -1;
        });
      }
      return;
    }

    if (!_panelVisible || _triggerIndex != triggerIndex) {
      setState(() {
        _panelVisible = true;
        _triggerChar = trigger;
        _triggerIndex = triggerIndex;
        _sutraResults = [];
        _userResults = [];
        _topicResults = [];
      });
    }
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () async {
      if (!mounted) return;
      final curText = _contentController.text;
      final curSel = _contentController.selection;
      final stillActive = _panelVisible &&
          _triggerChar == trigger &&
          _triggerIndex == triggerIndex &&
          curSel.isValid &&
          curSel.isCollapsed &&
          curText.lastIndexOf(trigger, curSel.start - 1) == triggerIndex;
      if (!stillActive) return;
      if (trigger == r'$') {
        final results = await NoteSutraCatalog.search(query);
        if (mounted) setState(() => _sutraResults = results);
      } else if (trigger == '@') {
        final results = await _searchUsers(query);
        if (mounted) setState(() => _userResults = results);
      } else if (trigger == '#') {
        final results = await _loadTopics(query);
        if (mounted) setState(() => _topicResults = results);
      }
    });
  }

  /// 搜索可提及用户：全局账号搜索 + 已关注用户 + 粉丝。
  Future<List<UserProfile>> _searchUsers(String query) async {
    final byId = <String, UserProfile>{};
    // 1) 全局账号搜索（与 $ 经文、# 话题同款逻辑）。
    if (query.trim().isNotEmpty) {
      try {
        final results = await CloudNotesService.instance.searchUsers(query);
        for (final u in results) {
          if (u.id.isNotEmpty) byId[u.id] = u;
        }
      } catch (_) {}
    }
    // 2) 已关注用户 + 粉丝作为补充。
    final ids = <String>{
      ...CloudNotesService.instance.followingUserIds,
    };
    try {
      final followers = await CloudNotesService.instance.getFollowerUserIds();
      ids.addAll(followers);
    } catch (_) {}
    final me = AuthService.instance.currentUser.value;
    ids.removeWhere((id) => me != null && id == me.id);
    if (ids.isNotEmpty) {
      try {
        final profiles =
            await CloudNotesService.instance.getUserProfiles(ids.toList());
        for (final p in profiles) {
          byId[p.id] ??= p;
        }
      } catch (_) {}
    }
    byId.removeWhere((id, p) => me != null && id == me.id);
    final q = query.trim().toLowerCase();
    final prefix = <UserProfile>[];
    final contains = <UserProfile>[];
    for (final p in byId.values) {
      final account = p.account.toLowerCase();
      final name = p.name.toLowerCase();
      final match = account.contains(q) || name.contains(q);
      if (!match) continue;
      if (account.startsWith(q) || name.startsWith(q)) {
        prefix.add(p);
      } else {
        contains.add(p);
      }
    }
    prefix.sort((a, b) => a.account.compareTo(b.account));
    contains.sort((a, b) => a.account.compareTo(b.account));
    return [...prefix, ...contains].take(30).toList();
  }

  /// 搜索话题：本地已创建话题 + 从广场笔记中提取的系统话题，按关键字过滤。
  /// 与 `$` 经文搜索同款逻辑：优先前缀匹配，其次包含匹配，最多返回 30 个。
  /// 被管理员删除的话题、以及含数字的话题（如 #20240808、#第3天）不参与联想。
  Future<List<String>> _loadTopics(String query) async {
    await CloudNotesService.instance.refreshBannedTopics();
    final bans = CloudNotesService.instance.bannedTopicNames;
    final noiseRe = RegExp(r'\d');
    final prefs = await SharedPreferences.getInstance();
    final topics = <String>{
      ...(prefs.getStringList('note_topics') ?? const <String>[]),
    };
    if (!_fetchedTopicsLoaded) {
      try {
        final (list, _) = await CloudNotesService.instance
            .getPlazaNotes(page: 1, pageSize: 100);
        final re = RegExp(r'#([^\s#，。！？,;:!?（）()]+)');
        final fetched = <String>{};
        for (final n in list) {
          for (final m in re.allMatches(n.content)) {
            final t = m.group(1)!.trim();
            if (t.isNotEmpty && !bans.contains(t) && !noiseRe.hasMatch(t)) {
              fetched.add(t);
            }
          }
        }
        _fetchedTopics = fetched.toList();
      } catch (_) {
        _fetchedTopics = const [];
      }
      _fetchedTopicsLoaded = true;
    }
    topics.addAll(_fetchedTopics);
    final q = query.trim().toLowerCase();
    final prefix = <String>[];
    final contains = <String>[];
    for (final t in topics) {
      if (bans.contains(t) || noiseRe.hasMatch(t)) continue;
      final lower = t.toLowerCase();
      if (q.isEmpty || lower.startsWith(q)) {
        prefix.add(t);
      } else if (lower.contains(q)) {
        contains.add(t);
      }
    }
    prefix.sort();
    contains.sort();
    return [...prefix, ...contains].take(30).toList();
  }

  /// 保存一个新话题到本地话题列表。
  Future<void> _addTopic(String topic) async {
    final t = topic.trim().replaceAll('#', '');
    if (t.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final topics = prefs.getStringList('note_topics') ?? <String>[];
    if (!topics.contains(t)) {
      topics.add(t);
      await prefs.setStringList('note_topics', topics);
    }
  }

  void _insertTrigger(String replacement) {
    final text = _contentController.text;
    final sel = _contentController.selection;
    final cursor = sel.isValid ? sel.start : text.length;
    final at = _triggerIndex >= 0 ? _triggerIndex : cursor;
    if (at < 0 || at >= cursor) return;
    _justInserted = true;
    _contentController.value = TextEditingValue(
      text: text.replaceRange(at, cursor, replacement),
      selection: TextSelection.collapsed(offset: at + replacement.length),
    );
    setState(() {
      _sutraResults = [];
      _userResults = [];
      _topicResults = [];
      _panelVisible = false;
      _triggerChar = '';
      _triggerIndex = -1;
    });
  }

  void _insertUser(UserProfile p) {
    final account = p.account.isNotEmpty ? p.account : p.name;
    _mentionUids[account] = p.id;
    _insertTrigger('@$account');
  }

  void _insertSutra(NoteSutraLink link) {
    _insertTrigger(r'$' + link.title);
  }

  void _insertTopic(String topic) {
    _addTopic(topic);
    _insertTrigger('#$topic');
  }

  void _hidePanel() {
    _debounce?.cancel();
    setState(() {
      _sutraResults = [];
      _userResults = [];
      _topicResults = [];
      _panelVisible = false;
      _triggerChar = '';
      _triggerIndex = -1;
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _save({bool fromDraftButton = false}) async {
    final content = _fullContent();
    if (content.isEmpty) return;

    if (_shared && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }

    setState(() => _savingCloud = true);
    String? newCloudId = _cloudId;
    bool cloudOk = true;

    if (_shared) {
      try {
        if (_cloudId == null || _cloudId!.isEmpty) {
          newCloudId = await CloudNotesService.instance.publishNote(
            title: '',
            content: content,
          );
        } else {
          await CloudNotesService.instance.updateSharedNote(
            cloudId: _cloudId!,
            title: '',
            content: content,
            isPublic: true,
          );
        }
        _cloudId = newCloudId;
      } catch (e) {
        cloudOk = false;
        if (mounted) _showToast('分享失败：${e.toString()}');
      }
    } else if (_cloudId != null && _cloudId!.isNotEmpty) {
      try {
        await CloudNotesService.instance.unpublishNote(_cloudId!);
      } catch (_) {}
    }

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('notes') ?? '[]';
    final List<dynamic> notes = jsonDecode(raw);
    final now = DateTime.now().toIso8601String();

    final sharedNow =
        _shared && (cloudOk || (_cloudId != null && _cloudId!.isNotEmpty));
    final targetId = _savedId ?? widget.note?['id'] ?? now;
    final newNote = <String, dynamic>{
      'id': targetId,
      'title': '',
      'content': content,
      'updatedAt': now,
      'shared': sharedNow,
      'cloudId': sharedNow ? (_cloudId ?? newCloudId) : null,
    };
    final index = notes.indexWhere((n) => n['id'] == targetId);
    if (index >= 0) {
      notes[index] = newNote;
    } else {
      notes.add(newNote);
    }

    await prefs.setString('notes', jsonEncode(notes));
    if (mounted) {
      setState(() {
        _savedId = targetId;
        _hasChanges = false;
        _savingCloud = false;
      });
      final isEditPage = widget.note != null;
      if (sharedNow) {
        _showSavedToastWithView('已发表', newNote);
        if (isEditPage) {
          // 编辑页：发表后停留本页，侧滑返回时直接回个人主页。
          if (!fromDraftButton) _goHomeOnPop = true;
        } else {
          // 新建页：发表成功后返回上一页（修学主页等）。
          Navigator.pop(context);
        }
      } else {
        // 未分享：保存到本地草稿，停留在当前编辑页，不返回。
        _showToast('已保存到草稿');
        if (isEditPage && !fromDraftButton) _goHomeOnPop = true;
      }
    }
  }

  void _onShareChanged(bool value) {
    if (value && !AuthService.instance.isLoggedIn) {
      _showToast('分享到菩提空间需要先登录');
      Navigator.push(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
      return;
    }
    setState(() {
      _shared = value;
      if (!_hasChanges) _hasChanges = true;
    });
  }

  /// 触发面板：@ 提及用户 / $ 引用经文 / # 话题。
  Widget _buildTriggerPanel() {
    final trigger = _triggerChar;
    final (String icon, String title, String empty) = switch (trigger) {
      '@' => ('people', '提及用户', '输入账号或昵称搜索，可提及已关注的同修'),
      r'$' => ('menu_book', '选择经书', '输入经书名称开始搜索，例如：地藏'),
      '#' => ('tag', '创建或选择话题', '输入话题名称，或从下方选择已有话题'),
      _ => ('menu_book', '选择', ''),
    };
    final items = trigger == '@'
        ? _userResults
        : (trigger == '#' ? _topicResults : _sutraResults);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppPalette.p.border),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 4),
            child: Row(
              children: [
                Icon(
                    trigger == '@'
                        ? Icons.person_outline
                        : (trigger == '#'
                            ? Icons.tag
                            : Icons.menu_book_outlined),
                    size: 15,
                    color: _textHint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                          fontSize: 13,
                          color: _textSec,
                          fontWeight: FontWeight.w600)),
                ),
                GestureDetector(
                  onTap: _hidePanel,
                  child: Icon(Icons.close, size: 16, color: _textHint),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppPalette.p.border),
          if (trigger == '#' && items.isEmpty)
            // 无已有话题时直接提供「创建话题」入口。
            InkWell(
              onTap: _createNewTopic,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    Icon(Icons.add, size: 17, color: _gold),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text('创建新话题',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: _text)),
                    ),
                  ],
                ),
              ),
            )
          else if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text(empty,
                    style: TextStyle(fontSize: 13, color: _textHint)),
              ),
            )
          else
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.only(bottom: 6),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  if (trigger == '@') {
                    final p = (items as List)[index] as UserProfile;
                    final account = p.account.isNotEmpty ? p.account : p.name;
                    return InkWell(
                      onTap: () => _insertUser(p),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        child: Row(
                          children: [
                            Icon(Icons.person_outline,
                                size: 17, color: _textSec),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('@$account · ${p.name}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14, color: _text)),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  if (trigger == '#') {
                    final t = (items as List)[index] as String;
                    return InkWell(
                      onTap: () => _insertTopic(t),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 9),
                        child: Row(
                          children: [
                            Icon(Icons.tag, size: 17, color: _gold),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text('#$t',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                      color: _text)),
                            ),
                          ],
                        ),
                      ),
                    );
                  }
                  final s = (items as List)[index] as NoteSutraLink;
                  return InkWell(
                    onTap: () => _insertSutra(s),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 9),
                      child: Row(
                        children: [
                          Icon(Icons.menu_book_rounded, size: 17, color: _gold),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(s.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: _text)),
                                if (s.folder.isNotEmpty) ...[
                                  const SizedBox(height: 1),
                                  Text(s.folder,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 11, color: _textHint)),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 创建新话题：输入话题名并插入。
  Future<void> _createNewTopic() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final c = TextEditingController();
        return AlertDialog(
          backgroundColor: _card,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('创建话题',
              style: TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
          content: TextField(
            controller: c,
            autofocus: true,
            maxLength: 20,
            style: TextStyle(fontSize: 15, color: _text),
            decoration: InputDecoration(
              hintText: '输入话题名称',
              hintStyle: TextStyle(color: _textHint),
              border: UnderlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('取消', style: TextStyle(color: _textSec)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('创建',
                  style: TextStyle(
                      color: Color(0xFF70867A), fontWeight: FontWeight.w600)),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty) return;
    _insertTopic(name);
  }

  Widget _buildShareRow() {
    final iconBg = _shared
        ? _gold.withValues(alpha: 0.15)
        : _textHint.withValues(alpha: 0.12);
    final iconColor = _shared ? _gold : _textHint;
    final titleColor = _shared ? _text : _textSec;
    return Container(
      color: _card,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                  color: iconBg, borderRadius: BorderRadius.circular(8)),
              child: Icon(Icons.people_outline, size: 16, color: iconColor),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('分享到菩提空间',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: titleColor)),
                  const SizedBox(height: 1),
                  Text(_shared ? '已分享，保存后同步到菩提空间' : '开启后同修可在菩提空间看到',
                      style: TextStyle(fontSize: 10, color: _textSec)),
                ],
              ),
            ),
            if (_savingCloud)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
              )
            else
              SwitchTheme(
                data: SwitchThemeData(
                  thumbColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? AppPalette.p.card
                          : AppPalette.p.muted),
                  trackColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                          ? _gold
                          : AppPalette.p.borderSoft),
                  trackOutlineColor: WidgetStateProperty.resolveWith(
                      (_) => Colors.transparent),
                ),
                child: Switch(
                  value: _shared,
                  onChanged: _savingCloud ? null : _onShareChanged,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _showToast(String text) {
    if (!mounted) return;
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
                color: _primary,
                borderRadius: BorderRadius.circular(20),
                elevation: 0,
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

  /// 保存成功后的底部提示：「已发表/已保存草稿，点击查看」。
  /// 最长显示 10 秒自动消失；点击「点击查看」立即关闭并进入帖子/草稿，点 X 仅关闭。
  void _showSavedToastWithView(String prefix, Map<String, dynamic> note) {
    if (!mounted) return;
    final overlay = Overlay.of(context);
    late OverlayEntry entry;
    Timer? autoHide;
    void dismiss() {
      autoHide?.cancel();
      if (entry.mounted) entry.remove();
    }

    entry = OverlayEntry(
      builder: (ctx) {
        final bottomInset = MediaQuery.of(ctx).padding.bottom;
        return Positioned(
          left: 16,
          right: 16,
          bottom: bottomInset + 84,
          child: Material(
            color: _primary,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                dismiss();
                final cloudId = note['cloudId'] as String?;
                if (cloudId != null && cloudId.isNotEmpty) {
                  // 已分享到菩提空间：进入帖子详情页。
                  Navigator.of(ctx).push(
                    MaterialPageRoute(
                        builder: (_) => NoteDetailPage(noteId: cloudId)),
                  );
                } else {
                  // 仅本地草稿：进入编辑页查看。
                  Navigator.of(ctx).push(
                    MaterialPageRoute(builder: (_) => NoteEditPage(note: note)),
                  );
                }
              },
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: '$prefix，',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          children: const [
                            TextSpan(
                              text: '点击查看',
                              style: TextStyle(
                                color: Color(0xFF70867A),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: dismiss,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(Icons.close,
                            size: 16, color: Colors.white70),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    // 10 秒后自动消失，避免一直挂着、用户忘记关闭。
    autoHide = Timer(const Duration(seconds: 10), dismiss);
  }

  Future<bool> _onWillPop() async {
    if (!_hasChanges) return true;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('放弃修改？',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
        content: Text('您有未保存的更改', style: TextStyle(color: _textSec)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消', style: TextStyle(color: _textSec))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃',
                  style: TextStyle(
                      color: Colors.red, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final isNew = (widget.note == null || widget.fixedTopic != null) &&
        _savedId == null;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final shouldPop = await _onWillPop();
        if (!shouldPop || !context.mounted) return;
        if (_goHomeOnPop) {
          // 编辑页已保存：直接弹回个人主页，跳过草稿页等中间页。
          Navigator.of(context).popUntil((route) => route.isFirst);
        } else {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(
          backgroundColor: _bg,
          elevation: 0,
          title: Text(isNew ? '新建笔记' : '编辑笔记',
              style: TextStyle(
                  color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
          actions: [
            GestureDetector(
              onTap: () async {
                // 编辑页有未保存的更改时先保存，避免草稿新增/删减的内容丢失。
                if (widget.note != null && _hasChanges) {
                  await _save(fromDraftButton: true);
                }
                if (!context.mounted) return;
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DraftsPage()),
                );
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Text('草稿',
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: _primary)),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: GestureDetector(
                onTap: _save,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Text('保存',
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _primary)),
                ),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 固定话题：直接显示在白色编辑框顶部，不可编辑、无边框。
                    if (widget.fixedTopic != null &&
                        widget.fixedTopic!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                        child: Text('#${widget.fixedTopic}',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: AppPalette.p.accentDeep)),
                      ),
                    Expanded(
                      child: Stack(
                        children: [
                          TextField(
                            controller: _contentController,
                            maxLines: null,
                            expands: true,
                            textAlignVertical: TextAlignVertical.top,
                            style: TextStyle(
                                fontSize: 16, color: _text, height: 1.6),
                            decoration: InputDecoration(
                              hintText: '开始记录...\n'
                                  '输入 @ 可提及用户\n'
                                  '输入 \$ 可引用经文\n'
                                  '输入 # 可创建或选择话题',
                              hintStyle: TextStyle(color: _textHint),
                              isDense: true,
                              contentPadding: const EdgeInsets.fromLTRB(
                                  16, 14, 16, 18),
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          ),
                          if (_panelVisible)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: _buildTriggerPanel(),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            _buildShareRow(),
          ],
        ),
      ),
    );
  }
}
