import 'package:flutter/material.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'note_detail_page.dart';
import 'settings_widgets.dart';
import 'text_input_sheet.dart';

import 'app_palette.dart';
/// 管理员页（仅管理员可见入口，云端也会校验权限）：
/// 添加 / 移除管理员、发布 / 删除 App 公告。
class AdminManagePage extends StatefulWidget {
  const AdminManagePage({super.key});

  @override
  State<AdminManagePage> createState() => _AdminManagePageState();
}

class _AdminManagePageState extends State<AdminManagePage> {
  List<AdminItem> _admins = [];
  List<AnnouncementItem> _announcements = [];
  bool _loading = true;

  String? get _selfUid => AuthService.instance.currentUser.value?.id;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        CloudNotesService.instance.getAdmins(),
        CloudNotesService.instance.getAnnouncements(),
      ]);
      if (!mounted) return;
      setState(() {
        _admins = results[0] as List<AdminItem>;
        _announcements = results[1] as List<AnnouncementItem>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showToast(_friendlyError(e));
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 把云端错误码翻译成用户能看懂的话。
  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('forbidden')) return '无权限操作';
    if (msg.contains('user_not_found')) return '未找到该账号，请确认对方已设置账号名称';
    if (msg.contains('already_admin')) return '该用户已是管理员';
    if (msg.contains('last_admin')) return '至少需要保留一位管理员';
    if (msg.contains('not_admin')) return '该用户不是管理员';
    return msg;
  }

  /// 添加管理员：弹出输入框（账号名称或用户 ID）→ 提交。
  Future<void> _addAdmin() async {
    final input = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const SheetTextInput(
        title: '添加管理员',
        hint: '输入对方的账号名称（或用户ID）',
        maxLength: 64,
        minLines: 1,
        maxLines: 1,
        confirmText: '添加',
      ),
    );
    final text = input?.trim() ?? '';
    if (text.isEmpty || !mounted) return;
    try {
      await CloudNotesService.instance.addAdmin(text);
      if (!mounted) return;
      _showToast('已添加管理员');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  /// 移除管理员：二次确认 → 提交。
  Future<void> _removeAdmin(AdminItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('移除管理员', style: TextStyle(fontSize: 17, color: sText)),
        content: Text(
          item.username.isNotEmpty
              ? '确定将「${item.username}」移出管理员吗？'
              : '确定移除这位管理员吗？',
          style: TextStyle(fontSize: 14, color: sTextSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: sTextSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.removeAdmin(item.uid);
      if (!mounted) return;
      _showToast('已移除管理员');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  /// 发布公告：底部弹窗填写标题与内容 → 提交云端 → 刷新。
  Future<void> _publishAnnouncement() async {
    final result = await showModalBottomSheet<(String, String)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _AnnouncementComposeSheet(),
    );
    if (result == null || !mounted) return;
    try {
      await CloudNotesService.instance.addAnnouncement(
        title: result.$1,
        content: result.$2,
      );
      if (!mounted) return;
      _showToast('公告已发布');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  /// 删除公告：二次确认 → 提交云端 → 刷新。
  Future<void> _deleteAnnouncement(AnnouncementItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: sCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('删除公告', style: TextStyle(fontSize: 17, color: sText)),
        content: Text(
          '确定删除公告「${item.title}」吗？删除后所有用户将不可见。',
          style: TextStyle(fontSize: 14, color: sTextSec),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: sTextSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await CloudNotesService.instance.deleteAnnouncement(item.id);
      if (!mounted) return;
      _showToast('已删除公告');
      await _reload();
    } catch (e) {
      if (!mounted) return;
      _showToast(_friendlyError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '管理员',
      trailing: TextButton.icon(
        onPressed: _addAdmin,
        icon: Icon(Icons.person_add_alt_1, size: 18, color: sGold),
        label: Text('添加',
            style: TextStyle(color: sGold, fontWeight: FontWeight.w600)),
      ),
      child: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: sGold));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: sGold.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            '管理员可查看和回复反馈、发布公告、管理其他管理员。第一位管理员需要在云开发控制台数据库中登记（详见说明）。',
            style: TextStyle(fontSize: 12, color: sTextSec, height: 1.6),
          ),
        ),
        const SizedBox(height: 12),
        if (_admins.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 60),
            child: Column(
              children: [
                Icon(Icons.admin_panel_settings_outlined,
                    size: 48, color: sTextHint.withValues(alpha: 0.6)),
                const SizedBox(height: 14),
                Text('暂无管理员',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: sText)),
              ],
            ),
          )
        else
          ..._admins.map(_buildAdminTile),
        const SizedBox(height: 28),
        Row(
          children: [
            Text('公告管理',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: sText)),
            const Spacer(),
            SizedBox(
              height: 36,
              child: FilledButton.icon(
                onPressed: _publishAnnouncement,
                icon: const Icon(Icons.campaign_outlined, size: 16),
                label: const Text('发布公告', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: FilledButton.styleFrom(
                  backgroundColor: sGold,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (_announcements.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 32),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sCard,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Icon(Icons.campaign_outlined,
                    size: 36, color: sTextHint),
                SizedBox(height: 8),
                Text('暂无公告',
                    style: TextStyle(fontSize: 14, color: sTextSec)),
              ],
            ),
          )
        else
          ..._announcements.map(_buildAnnouncementTile),
      ],
    );
  }

  Widget _buildAnnouncementTile(AnnouncementItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: sCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => NoteDetailPage(
                    noteId: item.id,
                    isAnnouncement: true)),
          ),
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: sText),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.content,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13, color: sTextSec, height: 1.5),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatTime(item.createdAt),
                        style: TextStyle(fontSize: 11, color: sTextHint),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => _deleteAnnouncement(item),
                  icon: const Icon(Icons.delete_outline,
                      size: 20, color: Colors.redAccent),
                  tooltip: '删除公告',
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }

  Widget _buildAdminTile(AdminItem item) {
    final isSelf = item.uid.isNotEmpty && item.uid == _selfUid;
    final name = item.username.isNotEmpty ? item.username : '未设置账号名称';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: sCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: sGold.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Text(
                item.username.isNotEmpty
                    ? item.username.characters.first
                    : '?',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: sGold),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: sText),
                        ),
                      ),
                      if (isSelf) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: sTextHint.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('我',
                              style: TextStyle(
                                  fontSize: 10, color: sTextSec)),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.uid.isNotEmpty && item.uid.length > 16
                        ? 'ID ${item.uid.substring(0, 16)}…'
                        : 'ID ${item.uid}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: sTextHint),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => _removeAdmin(item),
              icon: const Icon(Icons.person_remove_outlined,
                  size: 20, color: Colors.redAccent),
              tooltip: '移除管理员',
            ),
          ],
        ),
      ),
    );
  }
}

/// 发布公告底部弹窗：标题 + 内容，确认后以 (标题, 内容) 返回。
class _AnnouncementComposeSheet extends StatefulWidget {
  const _AnnouncementComposeSheet();

  @override
  State<_AnnouncementComposeSheet> createState() =>
      _AnnouncementComposeSheetState();
}

class _AnnouncementComposeSheetState extends State<_AnnouncementComposeSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _confirm() {
    final title = _titleController.text.trim();
    final content = _contentController.text.trim();
    if (title.isEmpty || content.isEmpty) return;
    Navigator.pop(context, (title, content));
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('发布公告',
                  style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: sText)),
              const SizedBox(height: 14),
              TextField(
                controller: _titleController,
                autofocus: true,
                maxLength: 60,
                style: TextStyle(fontSize: 15, color: sText),
                decoration: InputDecoration(
                  hintText: '公告标题',
                  hintStyle: TextStyle(color: sTextHint),
                  filled: true,
                  fillColor: sBg,
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _contentController,
                maxLength: 2000,
                minLines: 3,
                maxLines: 6,
                style: TextStyle(fontSize: 14, color: sText),
                decoration: InputDecoration(
                  hintText: '公告内容…',
                  hintStyle: TextStyle(color: sTextHint),
                  filled: true,
                  fillColor: sBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: sTextSec,
                        side: BorderSide(color: AppPalette.p.border),
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _confirm,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: sGold,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: const Text('发布'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
