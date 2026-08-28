import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'loading_widgets.dart';
import 'my_page.dart';
import 'note_edit_page.dart';

import 'app_palette.dart';
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;

/// 草稿页：本地保存但未分享到菩提空间的笔记列表。
/// 入口：新建笔记页右上角「草稿」按钮；可编辑草稿、发布笔记。
class DraftsPage extends StatefulWidget {
  const DraftsPage({super.key});

  @override
  State<DraftsPage> createState() => _DraftsPageState();
}

class _DraftsPageState extends State<DraftsPage> {
  List<Map<String, dynamic>> _notes = [];
  bool _loading = true;
  String _account = '';
  bool _verified = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final notes = (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((n) => n['shared'] != true)
          .toList()
        ..sort((a, b) => (b['updatedAt']?.toString() ?? '')
            .compareTo(a['updatedAt']?.toString() ?? ''));
      if (!mounted) return;
      setState(() {
        _notes = notes;
        _account = prefs.getString('user_account_name') ?? '';
        _verified = prefs.getBool('user_verified') ?? false;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notes = [];
        _loading = false;
      });
    }
  }

  void _openEdit(Map<String, dynamic> note) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => NoteEditPage(note: note)),
    ).then((_) {
      if (mounted) _load();
    });
  }

  /// 删除草稿：从本地存储移除，无法恢复。
  Future<void> _deleteDraft(Map<String, dynamic> note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除草稿',
            style: TextStyle(
                fontSize: 17, fontWeight: FontWeight.w600, color: _text)),
        content: Text('删除后草稿将无法恢复。确定删除吗？',
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
    final id = note['id']?.toString();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('notes') ?? '[]';
      final list = (jsonDecode(raw) as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((n) => n['id']?.toString() != id)
          .toList();
      await prefs.setString('notes', jsonEncode(list));
    } catch (_) {}
    if (!mounted) return;
    setState(() =>
        _notes.removeWhere((n) => n['id']?.toString() == id));
    showPostToast(context, '已删除');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        title: Text('草稿',
            style: TextStyle(
                color: _text, fontSize: 18, fontWeight: FontWeight.w600)),
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) return _pageLoading();
    if (_notes.isEmpty) {
      return _pageEmpty('还没有草稿', Icons.edit_note);
    }
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: 4),
        ),
        SliverPadding(
          // 横向内边距放在列表层：分割线随内容缩进 16px、不贴手机边缘（与帖子列表一致）。
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                // 末尾收尾分割线，保证最后一条草稿下方也有分割线。
                if (index == _notes.length) {
                  return Divider(
                      height: 1, thickness: 0.5, color: AppPalette.p.divider);
                }
                final note = _notes[index];
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 草稿顶部分割线（首条不画，避免顶部多一条线）。
                    if (index > 0)
                      Divider(
                          height: 1,
                          thickness: 0.5,
                          color: AppPalette.p.divider),
                    _DraftRow(
                      note: note,
                      account: _account,
                      verified: _verified,
                      onTap: () => _openEdit(note),
                      onDelete: () => _deleteDraft(note),
                    ),
                  ],
                );
              },
              childCount: _notes.length + 1,
            ),
          ),
        ),
      ],
    );
  }

  Widget _pageLoading() {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: 4),
        ),
        const SliverFillRemaining(
          child: Center(
            child: AppLoadingIndicator(message: '正在加载内容...'),
          ),
        ),
      ],
    );
  }

  Widget _pageEmpty(String text, IconData icon) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SizedBox(height: 4),
        ),
        SliverFillRemaining(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 48, color: _textHint),
                const SizedBox(height: 12),
                Text(text,
                    style: TextStyle(fontSize: 14, color: _textHint)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 草稿行：本地保存但未分享到菩提空间的笔记，样式与帖子一致，但没有统计指标行（未发表）。
class _DraftRow extends StatelessWidget {
  final Map<String, dynamic> note;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final String account;
  final bool verified;
  const _DraftRow({
    required this.note,
    required this.onTap,
    this.onDelete,
    this.account = '',
    this.verified = false,
  });

  @override
  Widget build(BuildContext context) {
    final note = this.note;
    final content = note['content']?.toString() ?? '';
    final ts = DateTime.tryParse(note['updatedAt']?.toString() ?? '');
    final nickname =
        AuthService.instance.currentUser.value?.displayName ?? '同修';
    return PostBlock(
      // 三重兜底取 uid：会话恢复竞态时 currentUser 可能为 null。
      ownerUserId: AuthService.instance.currentUser.value?.id ??
          AuthService.instance.cachedUserId ??
          'local',
      nickname: nickname,
      account: account,
      authorVerified: verified,
      timeMs: ts?.millisecondsSinceEpoch ?? 0,
      content: content,
      onTap: onTap,
      // 草稿三点菜单：编辑 / 删除（未发布无置顶）。
      noteId: note['id']?.toString(),
      onEdit: onTap,
      onDelete: onDelete,
    );
  }
}
