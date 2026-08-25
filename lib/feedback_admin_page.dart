import 'package:flutter/material.dart';

import 'cloud_notes_service.dart';
import 'settings_widgets.dart';

import 'app_palette.dart';
/// 反馈管理页（仅管理员可见入口，云端也会校验权限）。
class FeedbackAdminPage extends StatefulWidget {
  const FeedbackAdminPage({super.key});

  @override
  State<FeedbackAdminPage> createState() => _FeedbackAdminPageState();
}

class _FeedbackAdminPageState extends State<FeedbackAdminPage> {
  final List<FeedbackItem> _items = [];
  int _unread = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  int _page = 0;
  String _status = 'new';

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      final res = await CloudNotesService.instance
          .getFeedbacks(page: 1, status: _status);
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(res.items);
        _unread = res.unread;
        _hasMore = res.hasMore;
        _page = 1;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      _showToast(e.toString());
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final res = await CloudNotesService.instance
          .getFeedbacks(page: _page + 1, status: _status);
      if (!mounted) return;
      setState(() {
        _items.addAll(res.items);
        _hasMore = res.hasMore;
        _page += 1;
        _unread = res.unread;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _showToast(e.toString());
    }
  }

  void _switchStatus(String status) {
    if (_status == status) return;
    setState(() => _status = status);
    _reload();
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _openDetail(FeedbackItem item) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: sCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FeedbackDetailSheet(item: item),
    );
    if (changed == true && mounted) {
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '反馈管理',
      child: Column(
        children: [
          _buildTabBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Expanded(child: _buildTab('new', '待处理')),
          Expanded(child: _buildTab('handled', '已处理')),
        ],
      ),
    );
  }

  Widget _buildTab(String status, String label) {
    final selected = _status == status;
    return GestureDetector(
      onTap: () => _switchStatus(status),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 2),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? sText : sTextSec,
              ),
            ),
            const SizedBox(height: 3),
            Container(
              width: 60,
              height: 3,
              decoration: BoxDecoration(
                color: selected ? sGold : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: sGold));
    }
    if (_items.isEmpty) {
      return RefreshIndicator(
        onRefresh: _reload,
        color: sGold,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 120),
              child: Column(
                children: [
                  Icon(Icons.forum_outlined,
                      size: 48, color: sTextHint.withValues(alpha: 0.6)),
                  const SizedBox(height: 14),
                  Text(
                    _status == 'handled' ? '暂无已处理反馈' : '暂无待处理反馈',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: sText)),
                  const SizedBox(height: 6),
                  Text('用户提交的反馈会显示在这里',
                      style: TextStyle(fontSize: 13, color: sTextSec)),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      color: sGold,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels >
              notification.metrics.maxScrollExtent - 300) {
            _loadMore();
          }
          return false;
        },
        child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: _items.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(left: 6, right: 6, bottom: 10),
              child: Row(
                children: [
                  Text('共 ',
                      style: TextStyle(fontSize: 13, color: sTextSec)),
                  Text('${_items.length} 条',
                      style: TextStyle(
                          fontSize: 13,
                          color: sTextSec,
                          fontWeight: FontWeight.w600)),
                  if (_status == 'new' && _unread > 0) ...[
                    Text('  ·  ',
                        style: TextStyle(fontSize: 13, color: sTextSec)),
                    Text('$_unread 条待处理',
                        style: TextStyle(
                            fontSize: 13,
                            color: sGold,
                            fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            );
          }
          final itemIndex = index - 1;
          if (itemIndex >= _items.length) {
            if (_loadingMore) {
              return Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                    child: CircularProgressIndicator(color: sGold, strokeWidth: 2)),
              );
            }
            if (_hasMore) {
              return const SizedBox(height: 24);
            }
            return Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('没有更多了',
                    style: TextStyle(fontSize: 12, color: sTextHint)),
              ),
            );
          }
          return _buildFeedbackTile(_items[itemIndex]);
        },
        ),
      ),
    );
  }

  Widget _buildFeedbackTile(FeedbackItem item) {
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
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openDetail(item),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: item.isHandled
                            ? sTextHint.withValues(alpha: 0.2)
                            : sGold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        item.isHandled ? '已处理' : '待处理',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color:
                              item.isHandled ? sTextSec : sGold,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _formatTime(item.createdAt),
                      style:
                          TextStyle(fontSize: 11, color: sTextHint),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  item.content,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14, color: sText, height: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  item.username.isNotEmpty
                      ? '@${item.username}'
                      : (item.userId.isNotEmpty
                          ? '用户 ${item.userId.substring(0, item.userId.length > 8 ? 8 : item.userId.length)}'
                          : '匿名用户'),
                  style: TextStyle(fontSize: 11, color: sTextHint),
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
}

/// 反馈详情底部弹窗，支持标记已处理 / 待处理。
class _FeedbackDetailSheet extends StatelessWidget {
  final FeedbackItem item;

  const _FeedbackDetailSheet({required this.item});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: item.isHandled
                          ? sTextHint.withValues(alpha: 0.2)
                          : sGold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      item.isHandled ? '已处理' : '待处理',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: item.isHandled ? sTextSec : sGold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _detailTime(item.createdAt),
                    style: TextStyle(fontSize: 12, color: sTextHint),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                item.username.isNotEmpty
                    ? '@${item.username}'
                    : (item.userId.isNotEmpty
                        ? '用户 ${item.userId}'
                        : '匿名用户'),
                style: TextStyle(fontSize: 12, color: sTextSec),
              ),
              if (item.contact.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text('联系方式：${item.contact}',
                    style:
                        TextStyle(fontSize: 12, color: sTextSec)),
              ],
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: sBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  item.content,
                  style: TextStyle(
                      fontSize: 14, color: sText, height: 1.6),
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
                      child: const Text('关闭'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _toggle(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: sGold,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(item.isHandled ? '标为待处理' : '标记已处理'),
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

  Future<void> _toggle(BuildContext context) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CloudNotesService.instance
          .markFeedbackHandled(item.id, handled: !item.isHandled);
      navigator.pop(true);
      messenger.showSnackBar(
        SnackBar(
          content: Text(item.isHandled ? '已标为待处理' : '已标记处理'),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(e.toString()), duration: const Duration(seconds: 2)),
      );
    }
  }

  String _detailTime(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
