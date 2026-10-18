import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_palette.dart';
import 'sutra_edit_drafts.dart';

/// 空白字符（与 `\s` 等价）：统一复用同一次编译的正则，避免在长经文上
/// 逐字符 / 逐段反复构造 RegExp 对象。
final RegExp _whitespaceRunRe = RegExp(r'\s+');

/// 已解析过的编辑副本路径：每次调用都会走一次 platform channel 取文档目录
/// 并创建目录，自动保存每 500ms 触发一次，必须缓存。
final Map<String, String> _editedPathCache = {};

Future<String> editedSutraFilePath(String keyPath) async {
  final cached = _editedPathCache[keyPath];
  if (cached != null) return cached;
  final dir = await getApplicationDocumentsDirectory();
  final folder = Directory('${dir.path}/edited_sutras');
  await folder.create(recursive: true);
  final sanitized = keyPath.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '_');
  final path = '${folder.path}/$sanitized.txt';
  _editedPathCache[keyPath] = path;
  return path;
}

class SutraEditPage extends StatefulWidget {
  final String title;
  final String content;
  final String keyPath;
  final double scrollProgress;
  final String? topParagraphText;

  /// 顶部标题输入框的默认值（当前展示的经名）；为空时回退 [title]。
  final String? initialTitle;

  const SutraEditPage({
    super.key,
    required this.title,
    required this.content,
    required this.keyPath,
    this.scrollProgress = 0.0,
    this.topParagraphText,
    this.initialTitle,
  });

  @override
  State<SutraEditPage> createState() => _SutraEditPageState();
}

class _SutraEditPageState extends State<SutraEditPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _positioned = false;

  /// 顶部经名（标题）输入框：管理员可订正显示名。
  late final TextEditingController _titleController;
  late final String _initialTitle;

  /// 进入编辑页时的原文（与之比较判断是否有未保存改动）。
  late final String _initialText;

  /// 最近一次成功写进本地编辑副本（`edited_sutras/*.txt`）的正文。
  String? _writtenText;

  /// 最近一次同步到云端草稿的正文 / 经名。草稿是整篇经文的 json，
  /// 每次自动保存都重新编码 + 走一遍 SharedPreferences 会让打字周期性卡顿，
  /// 因此按 [_draftSyncIntervalMs] 节流，点保存 / 退出时立即同步。
  String? _draftText;
  String? _draftTitle;
  int _lastDraftSyncAt = 0;

  /// 自动保存时云端草稿的最小同步间隔。
  static const int _draftSyncIntervalMs = 15000;

  /// 写盘串行链：防抖自动保存 / 点保存 / 销毁兜底可能重叠，避免并发写同一文件。
  Future<void>? _writeChain;

  /// 防抖自动保存定时器：停笔片刻即落盘，避免「改完直接返回/杀进程」丢字。
  Timer? _autoSaveTimer;

  /// 入页动画结束后的弹键盘兜底定时器（动画状态监听失效时保证仍能聚焦）。
  Timer? _focusTimer;

  /// 撤销历史：每个元素是一次操作前的正文 + 经名快照（不含当前状态）。
  final List<_EditSnapshot> _undoStack = [];

  /// 撤销历史累计字符数：每份快照都是整篇经文，不限流会长期占住几十 MB。
  int _undoChars = 0;

  /// 撤销历史上限（按累计字符计，约 8MB UTF-16），超出时丢最早的快照。
  static const int _maxUndoChars = 4 * 1024 * 1024;

  /// 连续输入的合并：一段输入停顿后，把该输入段开始前的状态压入历史，
  /// 这样一次「撤销」能整段退回，而不是逐字回退。正文与经名共用此机制。
  Timer? _typingIdleTimer;
  String _contentBeforeBurst = '';
  String _titleBeforeBurst = '';

  /// 正在用历史快照回填正文/经名，避免把回填本身记成一次新操作。
  bool _restoringHistory = false;

  @override
  void initState() {
    super.initState();
    _initialText = widget.content;
    _writtenText = widget.content;
    _contentBeforeBurst = widget.content;
    _controller = TextEditingController(text: widget.content);
    _controller.addListener(_onTextChanged);
    _focusNode = FocusNode();
    _initialTitle = (widget.initialTitle ?? widget.title).trim();
    _titleBeforeBurst = _initialTitle;
    // 进页时按「磁盘草稿就是当前这份内容/经名」处理：没改动就不必在
    // 退出时再编码一遍整篇经文（阅读页每次加载都会把正文镜像进草稿）。
    _draftText = widget.content;
    _draftTitle = _initialTitle;
    _titleController = TextEditingController(text: _initialTitle);
    _titleController.addListener(_onTitleChanged);
    final targetText = widget.topParagraphText;
    int? targetOffset;
    final trimmedTop = targetText?.trim() ?? '';
    if (trimmedTop.isNotEmpty) {
      // 只归一化一次：原文里 top 段与整篇正文都要去空白，重复 replaceAll
      // 会让进页第一帧多扫两遍全文。
      final topStripped = trimmedTop.replaceAll(_whitespaceRunRe, '');
      if (topStripped.length >= 5) {
        final key = topStripped.substring(0, 15.clamp(0, topStripped.length));
        if (key.length >= 5) {
          final raw = _controller.text.replaceAll(_whitespaceRunRe, '');
          final idx = raw.indexOf(key);
          if (idx >= 0) {
            targetOffset = _offsetInOriginal(idx);
          }
        }
      }
    }
    final progress = widget.scrollProgress.clamp(0.0, 1.0);
    if (targetOffset != null || progress > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final pos = targetOffset ??
            (_controller.text.length * progress).round().clamp(0, _controller.text.length);
        _controller.selection = TextSelection.collapsed(offset: pos);
        // 等入页动画结束再弹键盘：这一帧要排布整篇经文的输入框，再叠加
        // 键盘升起动画会明显掉帧（表现为进编辑页/侧滑时卡一下）。
        _focusAfterTransition();
      });
    }
  }

  /// 入页动画结束后才请求键盘焦点；动画迟迟不结束时用兜底定时器保证聚焦。
  void _focusAfterTransition() {
    if (!mounted || _positioned) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _requestFocusNow();
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status != AnimationStatus.completed) return;
      anim.removeStatusListener(onStatus);
      _focusTimer?.cancel();
      _focusTimer = null;
      _requestFocusNow();
    }

    anim.addStatusListener(onStatus);
    _focusTimer = Timer(const Duration(milliseconds: 600), () {
      anim.removeStatusListener(onStatus);
      _focusTimer = null;
      _requestFocusNow();
    });
  }

  void _requestFocusNow() {
    if (!mounted || _positioned) return;
    _positioned = true;
    _focusNode.requestFocus();
    _controller.selection = _controller.selection;
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _typingIdleTimer?.cancel();
    _focusTimer?.cancel();
    // 兜底：还有没落盘的改动（防抖未到点就被销毁）时补写一次，
    // 保证退出编辑页后正文一定在本地编辑副本里，云端草稿也一并同步。
    if (_controller.text != _writtenText ||
        _titleController.text.trim() != _draftTitle) {
      unawaited(_writeToDisk());
    }
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _titleController.removeListener(_onTitleChanged);
    _titleController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 文本变化：记录撤销历史，并重置防抖定时器，停笔片刻后自动落盘。
  void _onTextChanged() {
    _trackUndoHistory();
    if (_controller.text == _writtenText) return;
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      // 自动保存只保证本地副本及时落盘；云端草稿按间隔节流，
      // 避免每停笔一次就编码整篇经文。
      unawaited(_writeToDisk(syncDraft: false));
    });
  }

  /// 经名变化：同样纳入撤销历史（只记录，不额外落盘，随正文一起保存）。
  void _onTitleChanged() {
    _trackUndoHistory();
  }

  /// 记录撤销历史：键入时按「输入段」合并，停顿片刻后落一个快照。
  /// 只动了光标/选区（正文与经名都没变）时不排定时器，减少无谓的 Timer 抖动。
  void _trackUndoHistory() {
    if (_restoringHistory) return;
    if (_controller.text == _contentBeforeBurst &&
        _titleController.text == _titleBeforeBurst) {
      return;
    }
    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      _commitTypingBurst();
    });
  }

  /// 把当前「输入段」的起始状态压入历史（正文与经名都无变化则不记）。
  void _commitTypingBurst() {
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    final content = _controller.text;
    final title = _titleController.text;
    if (_contentBeforeBurst != content || _titleBeforeBurst != title) {
      _pushUndo(_EditSnapshot(content: _contentBeforeBurst, title: _titleBeforeBurst));
      _contentBeforeBurst = content;
      _titleBeforeBurst = title;
    }
  }

  void _pushUndo(_EditSnapshot snapshot) {
    final last = _undoStack.isEmpty ? null : _undoStack.last;
    if (last != null &&
        last.content == snapshot.content &&
        last.title == snapshot.title) {
      return;
    }
    _undoStack.add(snapshot);
    _undoChars += snapshot.content.length;
    // 每份快照都是整篇经文，按条数 + 累计字符双重限流，避免撤销历史
    // 长期占住几十 MB、GC 频繁触发反过来拖慢编辑。
    while (_undoStack.length > 100 ||
        (_undoStack.length > 1 && _undoChars > _maxUndoChars)) {
      _undoChars -= _undoStack.removeAt(0).content.length;
    }
  }

  /// 撤销上一步操作：工具栏插入立即成为一个撤销点；正文/经名的普通输入
  /// 按输入段合并。撤销可回退正文与经名中最近发生的那次修改。
  void _undo() {
    // 先把尚未落点的输入段定格，保证「输入到一半就点撤销」也能正确退回。
    _commitTypingBurst();
    if (_undoStack.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可撤销的操作')),
      );
      return;
    }
    final previous = _undoStack.removeLast();
    _undoChars -= previous.content.length;
    _restoringHistory = true;
    if (_controller.text != previous.content) {
      _controller.text = previous.content;
      _controller.selection = TextSelection.collapsed(
          offset: previous.content.length.clamp(0, previous.content.length));
    }
    if (_titleController.text != previous.title) {
      _titleController.text = previous.title;
    }
    _restoringHistory = false;
    _contentBeforeBurst = previous.content;
    _titleBeforeBurst = previous.title;
    _focusNode.requestFocus();
  }

  /// 把当前正文写入本地编辑副本，并按需同步一份到可上云的草稿（重装不丢）。
  ///
  /// 同步返回的只有「正文文件写完」这件事；云端草稿（整篇 json 编码 +
  /// SharedPreferences 平台通道）按 [_draftSyncIntervalMs] 节流、
  /// [syncDraft] 为 true（点保存 / 退出）时立即同步，不阻塞保存与返回动画。
  Future<void> _writeToDisk({bool syncDraft = true}) {
    // 在调度这一刻取快照，避免排队期间 State 被销毁后读已释放的 controller。
    final text = _controller.text;
    final title = _titleController.text.trim();
    final next = (_writeChain ?? Future<void>.value())
        .then((_) => _doWrite(text, title, syncDraft));
    _writeChain = next.then((_) {}, onError: (_) {});
    return next;
  }

  Future<void> _doWrite(String text, String title, bool syncDraft) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final needFile = text != _writtenText;
    final needDraft = text != _draftText || title != _draftTitle;
    final wantDraft = needDraft &&
        (syncDraft || now - _lastDraftSyncAt >= _draftSyncIntervalMs);
    if (!needFile && !wantDraft) return;
    if (needFile) {
      try {
        final path = await editedSutraFilePath(widget.keyPath);
        // 不用 flush:true：每次落盘都强制 fsync，长经文会把「保存」拖慢
        // 上百毫秒，表现为点保存后没反应。
        await File(path).writeAsString(text);
        _writtenText = text;
      } catch (_) {
        // 写盘失败（存储权限/空间等）：保留脏标记，下次变化或退出时重试。
        return;
      }
    }
    if (wantDraft) {
      _draftText = text;
      _draftTitle = title;
      _lastDraftSyncAt = now;
      // 云端草稿只是本机副本，失败也不影响本地已保存的正文。
      SutraEditDraft.save(
        title: widget.title,
        filePath: widget.keyPath,
        content: text,
        displayTitle: title,
      ).ignore();
    }
  }

  /// 返回给阅读页的结果：正文相对进入时有改动才让阅读页重新加载；
  /// 标题有改动则一并带回（正文没变时也会返回，供阅读页同步经名覆盖）。
  Map<String, dynamic>? _resultPayload() {
    final title = _titleController.text.trim();
    final titleChanged = title != _initialTitle;
    final contentChanged = _controller.text != _initialText;
    if (!contentChanged && !titleChanged) return null;
    String? cursorParagraphText;
    if (contentChanged && _controller.text.isNotEmpty) {
      final cursor =
          _controller.selection.end.clamp(0, _controller.text.length);
      final lastNewline = _controller.text.lastIndexOf('\n', cursor - 1);
      final nextNewline = _controller.text.indexOf('\n', cursor);
      final start = lastNewline + 1;
      final end =
          nextNewline < 0 ? _controller.text.length : nextNewline;
      final para = _controller.text.substring(start, end).trim();
      if (para.isNotEmpty) cursorParagraphText = para;
    }
    return {
      if (contentChanged) 'changed': true,
      'title': title,
      'titleChanged': titleChanged,
      'progress': _controller.text.isEmpty
          ? 0.0
          : (_controller.selection.end / _controller.text.length)
              .clamp(0.0, 1.0),
      'cursorParagraphText': cursorParagraphText,
    };
  }

  /// 点「保存」：立即落盘 + 提示，然后返回阅读页。
  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // 只等正文文件写完（草稿备份在后台），保存按钮不再被 json 编解码 /
    // SharedPreferences / fsync 拖住。
    await _writeToDisk();

    if (mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('已保存到本地（已同步备份）')),
      );
    }
    if (mounted) {
      navigator.pop(_resultPayload());
    }
  }

  /// 把「去掉空白后的下标」映射回原文下标。
  ///
  /// 一次 `allMatches` 扫描完成（只分配少量 Match），取代原先逐字符构造
  /// RegExp 的写法——长经文（几十万字）会在进页第一帧分配几十万次正则对象，
  /// 是进编辑页明显掉帧的主因之一。
  int _offsetInOriginal(int rawIdx) {
    final original = _controller.text;
    var rawCount = 0;
    var segStart = 0;
    for (final m in _whitespaceRunRe.allMatches(original)) {
      final segLen = m.start - segStart;
      if (rawCount + segLen > rawIdx) return segStart + (rawIdx - rawCount);
      rawCount += segLen;
      segStart = m.end;
    }
    final segLen = original.length - segStart;
    if (rawCount + segLen > rawIdx) return segStart + (rawIdx - rawCount);
    return original.length;
  }

  void _insertText(String text, {int cursorOffset = 0}) {
    // 插入前先把待定输入段定格，并把当前状态作为一个独立撤销点。
    _commitTypingBurst();
    _pushUndo(_EditSnapshot(
      content: _controller.text,
      title: _titleController.text,
    ));
    final sel = _controller.selection;
    final start = sel.start.clamp(0, _controller.text.length);
    final end = sel.end.clamp(0, _controller.text.length);
    _controller.text = '${_controller.text.substring(0, start)}$text${_controller.text.substring(end)}';
    _controller.selection = TextSelection.collapsed(offset: start + (cursorOffset == 0 ? text.length : cursorOffset));
    _typingIdleTimer?.cancel();
    _typingIdleTimer = null;
    _contentBeforeBurst = _controller.text;
    _titleBeforeBurst = _titleController.text;
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // 返回键 / 手势返回：正文或经名有改动且尚未点「保存」时，
        // 先弹窗确认「是否保存编辑」，而不是直接返回。
        final hasChanges = _controller.text != _initialText ||
            _titleController.text.trim() != _initialTitle;
        if (!hasChanges) {
          if (_controller.text != _writtenText ||
              _titleController.text.trim() != _draftTitle) {
            // 补写放到后台：返回动画期间不该等磁盘 I/O，State 销毁前
            // _writeToDisk 已把正文/经名取成快照，写盘不受影响。
            unawaited(_writeToDisk());
          }
          if (!context.mounted) return;
          Navigator.of(context).pop(_resultPayload());
          return;
        }
        final save = await _confirmSave();
        if (!context.mounted) return;
        if (save) {
          await _save();
        } else {
          // 取消：直接返回，不触发保存流程。
          Navigator.of(context).pop(null);
        }
      },
      child: _buildScaffold(p),
    );
  }

  /// 返回前确认：是否保存当前编辑。
  Future<bool> _confirmSave() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('是否保存编辑？'),
        content: const Text('当前编辑尚未保存，是否保存后再返回？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Widget _buildScaffold(PaletteData p) {
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: IconThemeData(color: p.text),
        // 经名直接在标题位置编辑，不再单独占一行输入框。
        title: TextField(
          controller: _titleController,
          textInputAction: TextInputAction.done,
          maxLines: 1,
          style: TextStyle(
            color: p.text,
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            isDense: true,
            border: InputBorder.none,
            hintText: widget.title,
            hintStyle: TextStyle(
              color: p.textHint,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(
              '保存',
              style: TextStyle(color: p.primary, fontSize: 14, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            _buildToolbar(p),
            Expanded(
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  keyboardType: TextInputType.multiline,
                  style: const TextStyle(
                    color: Color(0xFF212121),
                    fontSize: 16,
                    height: 1.8,
                    letterSpacing: 0.5,
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.all(16),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(PaletteData p) {
    final items = [
      _ToolbarItem(symbol: '。。。', label: '隐藏翻译', tooltip: '隐藏操作栏'),
      _ToolbarItem(symbol: '///', label: '不分段', tooltip: '与下段连排'),
      _ToolbarItem(symbol: 'bbb', label: '加粗', tooltip: '加粗显示'),
      _ToolbarItem(symbol: '@@@@', label: '备注', tooltip: '插入备注（绿色小字）', cursorOffset: 2),
      _ToolbarItem(label: '撤销', tooltip: '撤销上一步操作', onTap: _undo),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: p.tintBg,
        border: Border(
          bottom: BorderSide(color: p.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    _buildToolButton(p, items[i]),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '光标处插入',
            style: TextStyle(fontSize: 11, color: p.textHint),
          ),
        ],
      ),
    );
  }

  Widget _buildToolButton(PaletteData p, _ToolbarItem item) {
    return Tooltip(
      message: item.tooltip,
      child: GestureDetector(
        onTap: item.onTap ??
            (() => _insertText(item.symbol!, cursorOffset: item.cursorOffset)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: p.border, width: 0.5),
          ),
          child: Text(
            item.label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: p.primary,
            ),
          ),
        ),
      ),
    );
  }
}

/// 一次编辑操作前的状态快照：同时保存正文与经名，撤销时一并回退。
class _EditSnapshot {
  final String content;
  final String title;
  const _EditSnapshot({required this.content, required this.title});
}

class _ToolbarItem {
  final String? symbol;
  final String label;
  final String tooltip;
  final int cursorOffset;
  final VoidCallback? onTap;
  const _ToolbarItem({
    this.symbol,
    required this.label,
    required this.tooltip,
    this.cursorOffset = 0,
    this.onTap,
  });
}
