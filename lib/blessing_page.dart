import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'app_palette.dart';
import 'blessing_image_cache.dart';
import 'blessing_service.dart';
import 'blessing_templates.dart';
import 'cloud_notes_service.dart';
import 'post_time_link.dart';
import 'user_space_page.dart';

// ─────────────────────────── 通用小组件 ───────────────────────────

Widget _dragHandle(PaletteData p) {
  return Padding(
    padding: const EdgeInsets.only(top: 14, bottom: 10),
    child: Center(
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: p.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    ),
  );
}

Widget _sectionLabel(PaletteData p, String text) {
  return Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: p.textSec,
      letterSpacing: 0.5,
    ),
  );
}

Widget _hint(PaletteData p, String text) {
  return Text(
    text,
    style: TextStyle(fontSize: 12, color: p.textHint, height: 1.5),
  );
}

InputDecoration _fieldDecoration(PaletteData p, String hint) {
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide.none,
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(fontSize: 13, color: p.textHint),
    filled: true,
    fillColor: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
    border: border,
    enabledBorder: border,
    focusedBorder: border,
    disabledBorder: border,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );
}

Widget _tag(PaletteData p, String text, {Color? color}) {
  final c = color ?? p.accent;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
    decoration: BoxDecoration(
      color: c.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c),
    ),
  );
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
}

String _fmtYmd(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

DateTime? _parseYmd(String s) {
  final parts = s.split('-');
  if (parts.length != 3) return null;
  final y = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  final d = int.tryParse(parts[2]);
  if (y == null || m == null || d == null) return null;
  return DateTime(y, m, d);
}

/// 祈福是否已完成或已过期（归入「已完成」列表）。
bool _isBlessingOver(BlessingItem item) {
  if (item.progress?.isDone == true) return true;
  final proj = item.project;
  if (proj.status == 'closed') return true;
  final start = _parseYmd(proj.startDate);
  if (start == null || proj.totalDays <= 0) return false;
  final end = start.add(Duration(days: proj.totalDays));
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return !today.isBefore(end);
}

/// 后台线程压缩祈福图片：最长边 1280、JPEG 80，返回 null 表示无法解码。
Uint8List? _compressBlessingImage(Uint8List bytes) {
  try {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    var im = decoded;
    const maxSide = 1280;
    if (im.width > maxSide || im.height > maxSide) {
      im = im.width >= im.height
          ? img.copyResize(im, width: maxSide)
          : img.copyResize(im, height: maxSide);
    }
    return Uint8List.fromList(img.encodeJpg(im, quality: 80));
  } catch (_) {
    return null;
  }
}

// ─────────────────────────── 新建 / 编辑抽屉 ───────────────────────────

/// 打开祈福编辑抽屉。保存成功返回 true；取消返回 null。
Future<bool?> showBlessingEditor(BuildContext context, {BlessingProject? initial}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: AppPalette.p.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92,
      child: _BlessingEditor(initial: initial),
    ),
  );
}

class _BlessingEditor extends StatefulWidget {
  final BlessingProject? initial;

  const _BlessingEditor({this.initial});

  @override
  State<_BlessingEditor> createState() => _BlessingEditorState();
}

/// 编辑中的一张图片：已存图有 fileId/url，新选图有本地字节。
class _EditorImage {
  String? fileId;
  final String? url;
  final Uint8List? bytes;

  _EditorImage({this.fileId, this.url, this.bytes});
}

class _MethodRow {
  final BlessingMethodOption? option;
  final String name;
  final String unit;
  final TextEditingController? detail;
  bool on;
  final TextEditingController count;

  _MethodRow(this.option,
      {this.on = false,
      String? name,
      String? unit,
      String? count,
      String? detail})
      : name = name ?? option?.category ?? '',
        unit = unit ?? option?.unit ?? '',
        detail = (option != null && option.names.isNotEmpty)
            ? TextEditingController(
                text: (detail != null && detail.trim().isNotEmpty)
                    ? detail
                    : option.names.first)
            : null,
        count = TextEditingController(text: count ?? option?.defaultCount ?? '1');

  bool get isCustom => option == null;
  List<String> get names => option?.names ?? const [];
  String get detailText => detail?.text.trim() ?? '';
}

class _CustomMethodResult {
  final String name;
  final String unit;
  final String count;

  const _CustomMethodResult(this.name, this.unit, this.count);
}

class _CustomMethodDialog extends StatefulWidget {
  const _CustomMethodDialog();

  @override
  State<_CustomMethodDialog> createState() => _CustomMethodDialogState();
}

class _CustomMethodDialogState extends State<_CustomMethodDialog> {
  final _nameCtrl = TextEditingController();
  final _unitCtrl = TextEditingController(text: '遍');
  final _countCtrl = TextEditingController(text: '1');

  @override
  void dispose() {
    _nameCtrl.dispose();
    _unitCtrl.dispose();
    _countCtrl.dispose();
    super.dispose();
  }

  void _done() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _toast(context, '请填写方式名称');
      return;
    }
    Navigator.pop(
      context,
      _CustomMethodResult(
        name,
        _unitCtrl.text.trim(),
        _countCtrl.text.trim().isEmpty ? '1' : _countCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return AlertDialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('自定义祈福方式',
          style: TextStyle(
              fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameCtrl,
              autofocus: true,
              style: TextStyle(fontSize: 14, color: p.text),
              decoration: _fieldDecoration(p, '名称，如：拜忏'),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _unitCtrl,
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: _fieldDecoration(p, '单位，如：遍'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _countCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    style: TextStyle(fontSize: 14, color: p.text),
                    decoration: _fieldDecoration(p, '数量'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('取消', style: TextStyle(color: p.textSec)),
        ),
        FilledButton(
          onPressed: _done,
          style: FilledButton.styleFrom(backgroundColor: p.primary),
          child: const Text('添加'),
        ),
      ],
    );
  }
}

class _BlessingEditorState extends State<_BlessingEditor> {
  late final TextEditingController _titleCtrl;
  late final TextEditingController _targetCtrl;
  late final TextEditingController _dedicationCtrl;
  late final TextEditingController _daysCtrl;
  late final List<_MethodRow> _methods;
  final List<_MethodRow> _dropped = [];
  final List<_EditorImage> _images = [];
  bool _pickingImages = false;
  String? _imageError;
  static const int _maxImages = 3;
  late String _startDate;
  late int _groupIndex;
  String _templateKey = '';
  bool _saving = false;
  bool _secTemplate = true;
  bool _secDays = false;
  bool _secMethods = false;

  @override
  void initState() {
    super.initState();
    final it = widget.initial;
    _titleCtrl = TextEditingController(text: it?.title ?? '');
    _targetCtrl = TextEditingController(text: it?.target ?? '');
    _dedicationCtrl = TextEditingController(text: it?.dedication ?? '');
    _daysCtrl = TextEditingController(text: '${it?.totalDays ?? 7}');
    _startDate = (it != null && it.startDate.isNotEmpty)
        ? it.startDate
        : BlessingService.today();
    _templateKey = it?.templateKey ?? '';
    _groupIndex = 0;
    _methods = [];
    final existing = it?.methods ?? const <BlessingMethod>[];
    for (final o in kBlessingMethodOptions) {
      BlessingMethod? hit;
      for (final m in existing) {
        final nm = m.name.isNotEmpty ? m.name : m.category;
        if (m.category == o.category || nm == o.category) {
          hit = m;
          break;
        }
      }
      final detail = (hit != null &&
              hit.name.isNotEmpty &&
              hit.name != o.category)
          ? hit.name
          : null;
      _methods.add(_MethodRow(o,
          on: hit != null,
          count: hit?.count ?? o.defaultCount,
          detail: detail));
    }
    for (final m in existing) {
      final nm = m.name.isNotEmpty ? m.name : m.category;
      final isDefault = kBlessingMethodOptions
          .any((o) => o.category == m.category || o.category == nm);
      if (isDefault || nm.isEmpty) continue;
      _methods.add(_MethodRow(null,
          on: true, name: nm, unit: m.unit, count: m.count));
    }
    for (final im in it?.imageList ?? const <BlessingImage>[]) {
      _images.add(_EditorImage(
        fileId: im.id,
        url: im.hasUrl ? im.url : null,
      ));
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _targetCtrl.dispose();
    _dedicationCtrl.dispose();
    _daysCtrl.dispose();
    for (final m in _methods) {
      m.count.dispose();
      m.detail?.dispose();
    }
    for (final m in _dropped) {
      m.count.dispose();
      m.detail?.dispose();
    }
    super.dispose();
  }

  void _applyTemplate(BlessingTemplate t) {
    setState(() {
      _targetCtrl.text = t.target;
      _dedicationCtrl.text = t.dedication;
      _templateKey = t.title;
    });
  }

  Future<void> _pickStartDate() async {
    final now = DateTime.now();
    final first = DateTime(now.year - 1, 1, 1);
    final last = DateTime(now.year + 2, 12, 31);
    var initial = _parseYmd(_startDate) ?? now;
    if (initial.isBefore(first)) initial = first;
    if (initial.isAfter(last)) initial = last;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: first,
      lastDate: last,
      helpText: '选择起始日期',
      cancelText: '取消',
      confirmText: '确定',
      fieldLabelText: '起始日期',
    );
    if (picked == null || !mounted) return;
    setState(() => _startDate = _fmtYmd(picked));
  }

  List<BlessingMethod> _collectMethods() {
    final out = <BlessingMethod>[];
    for (final m in _methods) {
      if (!m.on) continue;
      final category = m.isCustom ? '' : m.name.trim();
      final detail = m.isCustom ? m.name.trim() : m.detailText;
      if (category.isEmpty && detail.isEmpty) continue;
      out.add(BlessingMethod(
        category: category,
        name: detail,
        count: m.count.text.trim(),
        unit: m.unit,
      ));
    }
    return out;
  }

  Future<void> _addCustomMethod() async {
    final r = await showDialog<_CustomMethodResult>(
      context: context,
      builder: (_) => const _CustomMethodDialog(),
    );
    if (r == null || !mounted) return;
    setState(() {
      _methods.add(_MethodRow(null,
          on: true, name: r.name, unit: r.unit, count: r.count));
      _secMethods = true;
    });
  }

  void _removeMethod(_MethodRow m) {
    setState(() {
      _methods.remove(m);
      _dropped.add(m);
    });
  }

  int? _androidSdkInt() {
    final version = Platform.operatingSystemVersion;
    final api = RegExp(r'API\s*(\d+)').firstMatch(version)?.group(1);
    if (api != null) return int.tryParse(api);
    final major = int.tryParse(
        RegExp(r'Android\s+(\d+)').firstMatch(version)?.group(1) ?? '');
    if (major == null) return null;
    const byVersion = {
      4: 19,
      5: 21,
      6: 23,
      7: 24,
      8: 26,
      9: 28,
      10: 29,
      11: 30,
      12: 31,
      13: 33,
      14: 34,
      15: 35,
      16: 36,
    };
    return byVersion[major];
  }

  Future<List<XFile>> _invokeImagePicker(ImagePicker picker, int remain) async {
    if (remain == 1) {
      final one = await picker.pickImage(
        source: ImageSource.gallery,
        requestFullMetadata: false,
      );
      return one == null ? const <XFile>[] : <XFile>[one];
    }
    return picker.pickMultiImage(
      limit: remain,
      maxWidth: 2560,
      maxHeight: 2560,
      imageQuality: 90,
      requestFullMetadata: false,
    );
  }

  Future<void> _pickImages() async {
    if (_pickingImages || _saving) return;
    final remain = _maxImages - _images.length;
    if (remain <= 0) {
      _showImageError('最多添加 $_maxImages 张图片');
      return;
    }
    setState(() {
      _pickingImages = true;
      _imageError = null;
    });
    await BlessingImageCache.hidePickerCache();
    try {
      final picker = ImagePicker();
      final platform = ImagePickerPlatform.instance;
      final isAndroid = platform is ImagePickerAndroid;
      // 优先使用系统相册选择器：它直接打开相册并能在选择器中限制最多 3 张，
      // 不会像旧的文件选择器那样进入文件夹。Android 11+ 支持相册选择器。
      final sdk = isAndroid ? _androidSdkInt() : null;
      final usePhotoPicker = isAndroid && (sdk ?? 0) >= 30;
      if (isAndroid) platform.useAndroidPhotoPicker = usePhotoPicker;
      final started = DateTime.now();
      List<XFile> picked;
      try {
        picked = await _invokeImagePicker(picker, remain);
      } catch (e) {
        debugPrint('Blessing image picker (photo picker) failed: $e');
        // 部分机型没有系统相册选择器，回退到普通相册。
        if (isAndroid) {
          platform.useAndroidPhotoPicker = false;
          picked = await _invokeImagePicker(picker, remain);
        } else {
          rethrow;
        }
      }
      if (picked.isEmpty &&
          usePhotoPicker &&
          DateTime.now().difference(started) <
              const Duration(milliseconds: 900)) {
        // 系统选择器声明存在但实际没弹出，改用普通相册。
        if (isAndroid) platform.useAndroidPhotoPicker = false;
        picked = await _invokeImagePicker(picker, remain);
      }
      if (!mounted) return;
      if (picked.isEmpty) return;
      if (picked.length > remain) {
        _showImageError('最多还能添加 $remain 张，请重新选择');
        return;
      }
      var added = 0;
      for (final f in picked) {
        if (added >= remain) break;
        final raw = await f.readAsBytes();
        if (raw.isEmpty) continue;
        final out = await compute(_compressBlessingImage, raw);
        if (out == null) continue;
        if (out.length > 2 * 1024 * 1024) {
          if (mounted) _showImageError('图片过大，请换一张');
          continue;
        }
        if (!mounted) return;
        setState(() {
          _images.add(_EditorImage(bytes: out));
          added++;
        });
      }
      if (added == 0 && mounted) _showImageError('未能添加图片，请重试');
    } catch (e, st) {
      debugPrint('Blessing image picker failed: $e\n$st');
      if (!mounted) return;
      setState(() => _imageError = '选择图片失败，请重试');
      _toast(context, '选择图片失败：$e');
    } finally {
      if (mounted) setState(() => _pickingImages = false);
    }
  }

  void _showImageError(String message) {
    if (!mounted) return;
    setState(() => _imageError = message);
  }

  void _removeImage(int index) {
    if (_saving || _pickingImages) return;
    setState(() => _images.removeAt(index));
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      _toast(context, '请填写祈福事由');
      return;
    }
    final days = (int.tryParse(_daysCtrl.text.trim()) ?? 7).clamp(1, 365);
    setState(() => _saving = true);
    try {
      final methods = _collectMethods();
      final imageIds = <String>[];
      for (final im in _images) {
        var fid = im.fileId;
        if (fid == null || fid.isEmpty) {
          if (im.bytes == null) continue;
          fid = await BlessingService.instance.uploadImage(im.bytes!);
          if (fid.isEmpty) throw Exception('图片上传失败');
          im.fileId = fid;
        }
        imageIds.add(fid);
      }
      final it = widget.initial;
      if (it == null) {
        await BlessingService.instance.create(
          title: title,
          target: _targetCtrl.text.trim(),
          templateKey: _templateKey,
          dedication: _dedicationCtrl.text.trim(),
          totalDays: days,
          startDate: _startDate,
          methods: methods,
          images: imageIds,
          isPrivate: false,
        );
      } else {
        await BlessingService.instance.update(
          it.id,
          title: title,
          target: _targetCtrl.text.trim(),
          templateKey: _templateKey,
          dedication: _dedicationCtrl.text.trim(),
          totalDays: days,
          startDate: _startDate,
          methods: methods,
          images: imageIds,
          isPrivate: false,
        );
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final viewInsets = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets),
      child: Column(
        children: [
          _dragHandle(p),
          _editorHeader(p),
          Expanded(
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                  20, 14, 20, 24 + MediaQuery.of(context).padding.bottom),
              children: [
                _fold(
                  p,
                  title: '模板选择',
                  summary: _templateKey.isEmpty ? '选择分组与模板' : _templateKey,
                  open: _secTemplate,
                  onToggle: () => setState(() => _secTemplate = !_secTemplate),
                  child: _templateContent(p),
                ),
                _fold(
                  p,
                  title: '祈福天数',
                  summary: '${_daysCtrl.text.trim()} 天 · 起于 $_startDate',
                  open: _secDays,
                  onToggle: () => setState(() => _secDays = !_secDays),
                  child: _daysContent(p),
                ),
                _fold(
                  p,
                  title: '祈福方式',
                  summary: _methodsSummary(),
                  open: _secMethods,
                  onToggle: () => setState(() => _secMethods = !_secMethods),
                  child: _methodsContent(p),
                ),
                const SizedBox(height: 18),
                _sectionLabel(p, '祈福事由'),
                const SizedBox(height: 8),
                TextField(
                  controller: _titleCtrl,
                  minLines: 6,
                  maxLines: 14,
                  maxLength: 5000,
                  buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                  keyboardType: TextInputType.multiline,
                  textAlignVertical: TextAlignVertical.top,
                  cursorColor: p.primary,
                  style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    hintText: '写下这次祈福的事由，可详细描述所缘的人或事……',
                    hintStyle: TextStyle(fontSize: 13, color: p.textHint),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    _sectionLabel(p, '图片'),
                    const SizedBox(width: 8),
                    Text('${_images.length}/$_maxImages',
                        style: TextStyle(fontSize: 11, color: p.textHint)),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    for (var i = 0; i < _images.length; i++) _imageThumb(p, i),
                    if (_images.length < _maxImages) _addImageTile(p),
                  ],
                ),
                const SizedBox(height: 6),
                if (_imageError != null) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.error_outline, size: 13, color: p.primary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(_imageError!,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: p.primary,
                                height: 1.4)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                ],
                _hint(p, '最多 3 张，公开祈福的图片对社区可见'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _editorHeader(PaletteData p) {
    final editing = widget.initial != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 12, 2),
      child: Row(
        children: [
          Icon(Icons.volunteer_activism_outlined, size: 20, color: p.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              editing ? '编辑祈福' : '发起祈福',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: p.text,
                letterSpacing: 0.5,
              ),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.pop(context),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              foregroundColor: p.textSec,
            ),
            child: const Text('取消', style: TextStyle(fontSize: 13)),
          ),
          const SizedBox(width: 4),
          FilledButton(
            onPressed: _saving ? null : _submit,
            style: FilledButton.styleFrom(
              backgroundColor: p.primary,
              foregroundColor: Colors.white,
              disabledBackgroundColor: p.border,
              elevation: 0,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            child: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : const Text('保存', style: TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  Widget _imageThumb(PaletteData p, int index) {
    final im = _images[index];
    Widget content;
    if (im.bytes != null) {
      content = Image.memory(im.bytes!,
          fit: BoxFit.cover, gaplessPlayback: true);
    } else if (im.url != null && im.url!.isNotEmpty) {
      content = Image.network(
        im.url!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => Container(
          color: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
          child: Icon(Icons.broken_image_outlined, size: 20, color: p.textHint),
        ),
      );
    } else {
      content = Container(
        color: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
        child: Icon(Icons.image_outlined, size: 20, color: p.textHint),
      );
    }
    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(width: 76, height: 76, child: content),
        ),
        Positioned(
          top: 3,
          right: 3,
          child: InkWell(
            onTap: () => _removeImage(index),
            borderRadius: BorderRadius.circular(10),
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  Widget _addImageTile(PaletteData p) {
    final busy = _pickingImages || _saving;
    return InkWell(
      onTap: busy ? null : _pickImages,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          color: AppPalette.instance.isPlain ? const Color(0xFFF5F5F5) : p.tintBg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: _pickingImages
            ? Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: p.primary),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add_photo_alternate_outlined,
                      size: 22, color: p.textSec),
                  const SizedBox(height: 4),
                  Text('添加图片',
                      style: TextStyle(fontSize: 10, color: p.textHint)),
                ],
              ),
      ),
    );
  }

  Widget _fold(
    PaletteData p, {
    required String title,
    required String summary,
    required bool open,
    required VoidCallback onToggle,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: onToggle,
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                Text(title,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: p.text)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 12, color: p.textHint),
                  ),
                ),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: open ? 0.5 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Icon(Icons.expand_more, size: 20, color: p.textSec),
                ),
              ],
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: child,
          ),
      ],
    );
  }

  String _methodsSummary() {
    final n = _methods.where((m) => m.on && m.name.trim().isNotEmpty).length;
    return n == 0 ? '未选择' : '已选 $n 项';
  }

  Widget _daysContent(PaletteData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final d in const [7, 21, 49, 100])
              _pill(p, '$d天', _daysCtrl.text.trim() == '$d',
                  () => setState(() => _daysCtrl.text = '$d')),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _daysCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(() {}),
                style: TextStyle(fontSize: 14, color: p.text),
                decoration: _fieldDecoration(p, '自定义天数').copyWith(
                  suffixText: '天',
                  suffixStyle: TextStyle(fontSize: 13, color: p.textSec),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: InkWell(
                onTap: _pickStartDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
                  decoration: BoxDecoration(
                    color: AppPalette.instance.isPlain
                        ? const Color(0xFFF5F5F5)
                        : p.tintBg,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.event_outlined, size: 16, color: p.accent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_startDate,
                            style: TextStyle(fontSize: 13, color: p.text)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _methodsContent(PaletteData p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hint(p, '勾选每日要做的功课，填写具体内容；也可自定义添加。'),
        const SizedBox(height: 6),
        _buildMethodRows(p),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _addCustomMethod,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppPalette.instance.isPlain
                  ? const Color(0xFFF3F3F3)
                  : p.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 16, color: p.primary),
                const SizedBox(width: 4),
                Text('自定义方式',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.primary)),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pill(
      PaletteData p, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? p.primary.withValues(alpha: 0.12)
              : (AppPalette.instance.isPlain
                  ? const Color(0xFFF3F3F3)
                  : p.tintBg),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? p.primary : p.text,
          ),
        ),
      ),
    );
  }

  Widget _templateContent(PaletteData p) {
    final group = kBlessingGroups[_groupIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 分组用「文字 + 下划线」样式，行距加大，避免下划线被挤在中间。
        Wrap(
          spacing: 18,
          runSpacing: 12,
          children: [
            for (int i = 0; i < kBlessingGroups.length; i++)
              _groupTab(p, kBlessingGroups[i].name, _groupIndex == i,
                  () => setState(() => _groupIndex = i)),
          ],
        ),
        const SizedBox(height: 18),
        // 模板用「无边框的浅色块」。
        Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            for (final t in group.templates)
              _templateChip(p, t, _templateKey == t.title),
          ],
        ),
        const SizedBox(height: 16),
        Text('回向对象',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textHint)),
        const SizedBox(height: 6),
        TextField(
          controller: _targetCtrl,
          style: TextStyle(fontSize: 14, color: p.text),
          decoration: _fieldDecoration(p, '如：我的父母 / 灾区同胞 / 法界众生'),
        ),
        const SizedBox(height: 16),
        Text('回向文',
            style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: p.textHint)),
        const SizedBox(height: 6),
        TextField(
          controller: _dedicationCtrl,
          minLines: 3,
          maxLines: 8,
          style: TextStyle(fontSize: 14, color: p.text, height: 1.6),
          decoration: _fieldDecoration(p, '愿以此功课功德，回向……'),
        ),
      ],
    );
  }

  Widget _groupTab(PaletteData p, String name, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: IntrinsicWidth(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? p.primary : p.textSec,
              ),
            ),
            const SizedBox(height: 6),
            // 选中时横杠铺满分组文字宽度，更醒目。
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              height: 2,
              decoration: BoxDecoration(
                color: selected ? p.primary : Colors.transparent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _templateChip(PaletteData p, BlessingTemplate t, bool selected) {
    final bg = selected
        ? p.primary.withValues(alpha: 0.12)
        : (AppPalette.instance.isPlain ? const Color(0xFFF3F3F3) : p.tintBg);
    return GestureDetector(
      onTap: () => _applyTemplate(t),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              Icon(Icons.check, size: 14, color: p.primary),
              const SizedBox(width: 4),
            ],
            Text(
              t.title,
              style: TextStyle(
                fontSize: 13,
                color: selected ? p.primary : p.text,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMethodRows(PaletteData p) {
    return Column(
      children: [
        for (final m in _methods)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Transform.scale(
                    scale: 0.82,
                    child: Checkbox(
                      value: m.on,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      side: const BorderSide(width: 1.4),
                      onChanged: (v) {
                        setState(() {
                          m.on = v ?? false;
                          final d = m.detail;
                          if (m.on &&
                              d != null &&
                              d.text.trim().isEmpty &&
                              m.names.isNotEmpty) {
                            d.text = m.names.first;
                          }
                        });
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                if (m.isCustom)
                  Expanded(
                    child: Text(m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, color: p.text)),
                  )
                else
                  Text(m.name,
                      style: TextStyle(fontSize: 13.5, color: p.text)),
                const SizedBox(width: 6),
                if (!m.isCustom && m.names.isNotEmpty)
                  Expanded(child: _methodDetailField(p, m))
                else
                  const Spacer(),
                if (m.isCustom)
                  GestureDetector(
                    onTap: () => _removeMethod(m),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.close, size: 14, color: p.textHint),
                    ),
                  ),
                const SizedBox(width: 2),
                Text('×',
                    style: TextStyle(fontSize: 12, color: p.textHint)),
                const SizedBox(width: 4),
                SizedBox(
                  width: 52,
                  child: TextField(
                    controller: m.count,
                    enabled: m.on,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, color: p.text),
                    decoration: _fieldDecoration(p, '数量').copyWith(
                      isDense: true,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(m.unit,
                    style: TextStyle(fontSize: 12, color: p.textSec)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _methodDetailField(PaletteData p, _MethodRow m) {
    return TextField(
      controller: m.detail,
      enabled: m.on,
      style: TextStyle(fontSize: 12.5, color: p.text),
      decoration: _fieldDecoration(p, '具体内容').copyWith(
        isDense: true,
        contentPadding: const EdgeInsets.fromLTRB(8, 9, 0, 9),
        suffixIcon: m.on
            ? PopupMenuButton<String>(
                padding: EdgeInsets.zero,
                tooltip: '选择常见内容',
                icon: Icon(Icons.arrow_drop_down,
                    size: 18, color: p.textHint),
                onSelected: (v) => setState(() {
                  m.detail?.text = v;
                }),
                itemBuilder: (_) => [
                  for (final n in m.names)
                    PopupMenuItem<String>(
                      value: n,
                      child: Text(n,
                          style: TextStyle(fontSize: 13, color: p.text)),
                    ),
                ],
              )
            : null,
        suffixIconConstraints:
            const BoxConstraints(minWidth: 26, minHeight: 26),
      ),
    );
  }
}

// ─────────────────────────── 列表页 ───────────────────────────

class BlessingPage extends StatefulWidget {
  const BlessingPage({super.key});

  @override
  State<BlessingPage> createState() => _BlessingPageState();
}

class _BlessingPageState extends State<BlessingPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this);

  bool _loadingMine = true;
  bool _loadingComm = true;
  String? _mineErr;
  String? _commErr;
  List<BlessingItem> _mine = [];
  List<BlessingItem> _comm = [];
  final Set<String> _busy = {};

  List<BlessingItem> get _created =>
      _mine.where((it) => it.project.isOwner && !_isBlessingOver(it)).toList();

  List<BlessingItem> get _joined =>
      _mine.where((it) => !_isBlessingOver(it)).toList();

  List<BlessingItem> get _more {
    final mineIds = _mine.map((it) => it.project.id).toSet();
    return _comm
        .where((it) =>
            !mineIds.contains(it.project.id) && !_isBlessingOver(it))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _loadMine();
    _loadComm();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadMine() async {
    setState(() {
      _loadingMine = true;
      _mineErr = null;
    });
    try {
      final list = await BlessingService.instance.listMine();
      if (!mounted) return;
      setState(() {
        _mine = list;
        _loadingMine = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mineErr = e.toString();
        _loadingMine = false;
      });
    }
  }

  Future<void> _loadComm() async {
    setState(() {
      _loadingComm = true;
      _commErr = null;
    });
    try {
      final list = await BlessingService.instance.listCommunity();
      if (!mounted) return;
      setState(() {
        _comm = list;
        _loadingComm = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _commErr = e.toString();
        _loadingComm = false;
      });
    }
  }

  Future<void> _create() async {
    final saved = await showBlessingEditor(context);
    if (saved == true) {
      _loadMine();
      _loadComm();
    }
  }

  Future<void> _openDetail(String id) async {
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => BlessingDetailPage(id: id)));
    if (mounted) {
      _loadMine();
      _loadComm();
    }
  }

  Future<void> _bless(String id) async {
    if (_busy.contains(id)) return;
    _busy.add(id);
    try {
      final res = await BlessingService.instance.blessToday(id);
      if (!mounted) return;
      _toast(context, res.isDone ? '祈福圆满，随喜功德' : '今日祈福，功德已记');
      _loadMine();
      _loadComm();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _toggleJoin(BlessingItem item) async {
    final id = item.project.id;
    if (_busy.contains(id)) return;
    _busy.add(id);
    final joined = item.progress?.joined == true;
    try {
      if (joined) {
        await BlessingService.instance.leave(id);
      } else {
        await BlessingService.instance.join(id);
      }
      if (!mounted) return;
      _loadMine();
      _loadComm();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      _busy.remove(id);
    }
  }

  Future<void> _openFinished() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const _BlessingArchivePage()),
    );
    if (mounted) {
      _loadMine();
      _loadComm();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('祈福',
            style: TextStyle(
                color: p.text, fontSize: 16, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: IconButton(
              tooltip: '已完成祈福',
              onPressed: _openFinished,
              icon: Icon(Icons.check_circle_outline,
                  size: 22, color: p.primary),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          indicatorColor: p.primary,
          labelColor: p.primary,
          unselectedLabelColor: p.textSec,
          dividerColor: p.border.withValues(alpha: 0.5),
          dividerHeight: 0.8,
          labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          unselectedLabelStyle:
              const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          tabs: const [
            Tab(text: '我发起'),
            Tab(text: '我参与'),
            Tab(text: '更多'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildList(
            loading: _loadingMine,
            error: _mineErr,
            items: _created,
            emptyTitle: '还没有发起的祈福',
            emptyDesc: '发起一个祈福，把每日功课回向于此',
            onRetry: _loadMine,
            builder: (it) => _mineCard(p, it),
          ),
          _buildList(
            loading: _loadingMine,
            error: _mineErr,
            items: _joined,
            emptyTitle: '还没有参与的祈福',
            emptyDesc: '参与一个祈福，与大家一同回向',
            onRetry: _loadMine,
            builder: (it) => _mineCard(p, it),
          ),
          _buildList(
            loading: _loadingComm,
            error: _commErr,
            items: _more,
            emptyTitle: '暂无更多祈福',
            emptyDesc: '发起一个公开祈福，与大家一同祈愿',
            onRetry: _loadComm,
            builder: (it) => _commCard(p, it),
          ),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          width: 42,
          height: 42,
          child: FloatingActionButton(
            onPressed: _create,
            backgroundColor: p.primary,
            foregroundColor: Colors.white,
            elevation: 8,
            highlightElevation: 12,
            heroTag: 'blessing_fab',
            shape: const CircleBorder(),
            child: const Icon(Icons.add, size: 21),
          ),
        ),
      ),
    );
  }

  Widget _buildList({
    required bool loading,
    required String? error,
    required List<BlessingItem> items,
    required String emptyTitle,
    required String emptyDesc,
    required Future<void> Function() onRetry,
    required Widget Function(BlessingItem) builder,
  }) {
    final p = AppPalette.p;
    if (loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
        ),
      );
    }
    if (error != null) {
      return _centerNote(p, error, '重试', onRetry);
    }
    if (items.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRetry,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(height: MediaQuery.of(context).size.height * 0.22),
            _emptyBlock(p, emptyTitle, emptyDesc),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRetry,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 90),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (_, i) => builder(items[i]),
      ),
    );
  }

  Widget _centerNote(PaletteData p, String msg, String action, Future<void> Function() onTap) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(msg, style: TextStyle(fontSize: 13, color: p.textSec)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: () => onTap(), child: Text(action)),
        ],
      ),
    );
  }

  Widget _emptyBlock(PaletteData p, String title, String desc) {
    return Column(
      children: [
        Icon(Icons.volunteer_activism_outlined, size: 42, color: p.border),
        const SizedBox(height: 12),
        Text(title, style: TextStyle(fontSize: 15, color: p.textSec)),
        const SizedBox(height: 6),
        Text(desc, style: TextStyle(fontSize: 13, color: p.textHint)),
      ],
    );
  }

  Widget _cardShell(PaletteData p, {required Widget child, VoidCallback? onTap}) {
    return Material(
      color: p.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }

  Widget _progressBar(PaletteData p, int done, int total) {
    final value = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 5,
              backgroundColor: p.border,
              valueColor: AlwaysStoppedAnimation<Color>(p.primary),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text('$done/$total',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600, color: p.primary)),
      ],
    );
  }

  Widget _mineCard(PaletteData p, BlessingItem it) {
    final proj = it.project;
    final prog = it.progress ?? const BlessingProgress();
    final done = prog.isDone;
    final blessedToday = prog.doneToday();
    return _cardShell(
      p,
      onTap: () => _openDetail(proj.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(proj.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text)),
              ),
              if (done) ...[
                const SizedBox(width: 6),
                _tag(p, '已圆满'),
              ],
            ],
          ),
          if (proj.target.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('回向：${proj.target}',
                style: TextStyle(fontSize: 12.5, color: p.textSec)),
          ],
          const SizedBox(height: 12),
          _progressBar(p, prog.doneCount, proj.totalDays),
          const SizedBox(height: 12),
          Row(
            children: [
              Text('已祈福 ${prog.doneCount} 天 / 共 ${proj.totalDays} 天',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const Spacer(),
              if (!done)
                _actionButton(
                  p,
                  blessedToday ? '今日已祈福' : '今日祈福',
                  enabled: !blessedToday && !_busy.contains(proj.id),
                  onTap: () => _bless(proj.id),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _commCard(PaletteData p, BlessingItem it) {
    final proj = it.project;
    final joined = it.progress?.joined == true;
    final done = it.progress?.isDone == true;
    return _cardShell(
      p,
      onTap: () => _openDetail(proj.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(proj.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: p.text)),
              ),
              if (done) _tag(p, '已圆满'),
            ],
          ),
          if (proj.target.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('回向：${proj.target}',
                style: TextStyle(fontSize: 12.5, color: p.textSec)),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              Icon(Icons.groups_outlined, size: 15, color: p.textSec),
              const SizedBox(width: 5),
              Text('已有 ${proj.joinerCount} 人祈福',
                  style: TextStyle(fontSize: 12.5, color: p.textSec)),
              const Spacer(),
              _actionButton(
                p,
                joined ? '已参与' : '参与祈福',
                outline: !joined,
                enabled: !_busy.contains(proj.id),
                onTap: () => _toggleJoin(it),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actionButton(
    PaletteData p,
    String label, {
    bool enabled = true,
    bool outline = false,
    required VoidCallback onTap,
  }) {
    final bg = outline ? Colors.transparent : p.primary;
    final fg = outline ? p.primary : Colors.white;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: GestureDetector(
        onTap: enabled ? onTap : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(15),
            border: Border.all(color: p.primary),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w600, color: fg)),
        ),
      ),
    );
  }
}

class _BlessingArchivePage extends StatefulWidget {
  const _BlessingArchivePage();

  @override
  State<_BlessingArchivePage> createState() => _BlessingArchivePageState();
}

class _BlessingArchivePageState extends State<_BlessingArchivePage> {
  bool _loading = true;
  String? _error;
  List<BlessingItem> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await BlessingService.instance.listMine();
      if (!mounted) return;
      final items = list.where(_isBlessingOver).toList()
        ..sort((a, b) => b.project.startDate.compareTo(a.project.startDate));
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('已完成祈福',
            style: TextStyle(
                color: p.text, fontSize: 16, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: _buildBody(p),
    );
  }

  Widget _buildBody(PaletteData p) {
    if (_loading) {
      return Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, style: TextStyle(fontSize: 13, color: p.textSec)),
            const SizedBox(height: 10),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 42, color: p.border),
            const SizedBox(height: 12),
            Text('暂无已完成祈福',
                style: TextStyle(fontSize: 15, color: p.textSec)),
            const SizedBox(height: 6),
            Text('圆满或过期的祈福会收录在这里',
                style: TextStyle(fontSize: 13, color: p.textHint)),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      itemCount: _items.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (_, i) => _card(p, _items[i]),
    );
  }

  Widget _card(PaletteData p, BlessingItem it) {
    final proj = it.project;
    final prog = it.progress;
    final done = prog?.isDone == true;
    return Material(
      color: p.card,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () async {
          await Navigator.push(context,
              MaterialPageRoute(builder: (_) => BlessingDetailPage(id: proj.id)));
          if (mounted) _load();
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(proj.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: p.text)),
                  ),
                  const SizedBox(width: 6),
                  _tag(p, done ? '已圆满' : '已过期',
                      color: done ? p.accent : p.textHint),
                ],
              ),
              if (proj.target.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('回向：${proj.target}',
                    style: TextStyle(fontSize: 12.5, color: p.textSec)),
              ],
              const SizedBox(height: 10),
              Text(
                '${proj.startDate} 起 · ${proj.totalDays} 天'
                '${prog != null ? ' · 已祈福 ${prog.doneCount} 天' : ''}',
                style: TextStyle(fontSize: 12.5, color: p.textSec),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────── 详情页 ───────────────────────────

Widget _blessingImageGrid(
    BuildContext context, PaletteData p, List<BlessingImage> images) {
  final imgs = images.where((e) => e.id.isNotEmpty || e.hasUrl).toList();
  if (imgs.isEmpty) return const SizedBox.shrink();
  if (imgs.length == 1) {
    return _blessingImageTile(context, p, imgs, 0,
        width: double.infinity, height: 210);
  }
  final h = imgs.length == 2 ? 140.0 : 104.0;
  return Row(
    children: [
      for (var i = 0; i < imgs.length; i++) ...[
        if (i > 0) const SizedBox(width: 8),
        Expanded(child: _blessingImageTile(context, p, imgs, i, height: h)),
      ],
    ],
  );
}

Widget _blessingImageTile(
  BuildContext context,
  PaletteData p,
  List<BlessingImage> images,
  int index, {
  double? width,
  required double height,
}) {
  final im = images[index];
  return GestureDetector(
    onTap: () => _showBlessingImageViewer(context, images, index),
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: width,
        height: height,
        color: p.tintBg,
        child: _BlessingCachedImage(fileId: im.id, url: im.url),
      ),
    ),
  );
}

/// 以 fileID 为缓存键的图片，临时链接变化时仍能命中本地缓存。
class _BlessingCachedImage extends StatefulWidget {
  final String fileId;
  final String url;
  final BoxFit fit;

  const _BlessingCachedImage({
    required this.fileId,
    required this.url,
    this.fit = BoxFit.cover,
  });

  @override
  State<_BlessingCachedImage> createState() => _BlessingCachedImageState();
}

class _BlessingCachedImageState extends State<_BlessingCachedImage> {
  late Future<File?> _future;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(covariant _BlessingCachedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fileId != widget.fileId || oldWidget.url != widget.url) {
      _start();
    }
  }

  void _start() {
    _future = BlessingImageCache.instance.get(widget.fileId, widget.url);
  }

  Widget _network(PaletteData p) {
    if (widget.url.isEmpty) {
      return Center(
        child: Icon(Icons.broken_image_outlined, size: 24, color: p.textHint),
      );
    }
    return Image.network(
      widget.url,
      fit: widget.fit,
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.primary),
          ),
        );
      },
      errorBuilder: (_, __, ___) => Center(
        child:
            Icon(Icons.broken_image_outlined, size: 24, color: p.textHint),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    return FutureBuilder<File?>(
      future: _future,
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.done) {
          final file = snap.data;
          if (file != null) {
            return Image.file(
              file,
              fit: widget.fit,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _network(p),
            );
          }
          return _network(p);
        }
        return Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: p.primary),
          ),
        );
      },
    );
  }
}

void _showBlessingImageViewer(
    BuildContext context, List<BlessingImage> images, int index) {
  showDialog<void>(
    context: context,
    barrierColor: Colors.black,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.zero,
      child: _BlessingImageViewer(images: images, initialIndex: index),
    ),
  );
}

class _BlessingImageViewer extends StatefulWidget {
  final List<BlessingImage> images;
  final int initialIndex;

  const _BlessingImageViewer(
      {required this.images, required this.initialIndex});

  @override
  State<_BlessingImageViewer> createState() => _BlessingImageViewerState();
}

/// 单张图片：未放大时把左右滑动交给 PageView，放大后可平移。
class _BlessingZoomPage extends StatefulWidget {
  final Widget child;

  const _BlessingZoomPage({required this.child});

  @override
  State<_BlessingZoomPage> createState() => _BlessingZoomPageState();
}

class _BlessingZoomPageState extends State<_BlessingZoomPage> {
  final TransformationController _ctrl = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onChanged);
  }

  void _onChanged() {
    final z = _ctrl.value.getMaxScaleOnAxis() > 1.01;
    if (z != _zoomed && mounted) setState(() => _zoomed = z);
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onChanged);
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: () {
        _ctrl.value = _zoomed
            ? Matrix4.identity()
            : (Matrix4.identity()..scaleByDouble(2.0, 2.0, 2.0, 1.0));
      },
      child: InteractiveViewer(
        transformationController: _ctrl,
        panEnabled: _zoomed,
        minScale: 1,
        maxScale: 4,
        child: widget.child,
      ),
    );
  }
}

class _BlessingImageViewerState extends State<_BlessingImageViewer> {
  late final PageController _page =
      PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.images.length;
    return SizedBox.expand(
      child: Stack(
        children: [
          Positioned.fill(
            child: PageView.builder(
              controller: _page,
              itemCount: n,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (_, i) {
                final im = widget.images[i];
                return _BlessingZoomPage(
                  child: SizedBox.expand(
                    child: _BlessingCachedImage(
                      fileId: im.id,
                      url: im.url,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white, size: 28),
                ),
              ),
            ),
          ),
          if (n > 1)
            SafeArea(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text('${_index + 1}/$n',
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class BlessingDetailPage extends StatefulWidget {
  final String id;

  const BlessingDetailPage({super.key, required this.id});

  @override
  State<BlessingDetailPage> createState() => _BlessingDetailPageState();
}

class _BlessingDetailPageState extends State<BlessingDetailPage> {
  bool _loading = true;
  String? _error;
  BlessingDetail? _detail;
  UserProfile? _author;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await BlessingService.instance.getById(widget.id);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
      final ownerId = d.project.ownerUserId;
      if (ownerId.isNotEmpty) unawaited(_loadAuthor(ownerId));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadAuthor(String userId) async {
    try {
      final users =
          await CloudNotesService.instance.getUserProfiles([userId]);
      if (!mounted) return;
      final hit = users.where((u) => u.id == userId);
      setState(() => _author = hit.isEmpty ? null : hit.first);
    } catch (_) {}
  }

  Future<void> _bless() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final res = await BlessingService.instance.blessToday(widget.id);
      if (!mounted) return;
      final d = _detail;
      if (d != null) {
        final today = BlessingService.today();
        final cur = d.progress;
        final dates = <String>{...?cur?.doneDates, today}.toList()..sort();
        setState(() {
          _detail = BlessingDetail(
            d.project,
            BlessingProgress(
              joined: true,
              doneCount: res.doneCount,
              status: res.status,
              joinedAt: cur?.joinedAt ?? 0,
              lastDate: today,
              doneDates: dates,
            ),
            d.joinerCount,
          );
        });
      }
      _toast(context, res.isDone ? '祈福圆满，随喜功德' : '今日祈福，功德已记');
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await BlessingService.instance.join(widget.id);
      await _load();
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await BlessingService.instance.leave(widget.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmLeave() async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        title: Text('退出祈福？',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        content: Text('退出后将不再记录你的祈福进度。',
            style: TextStyle(fontSize: 13, color: p.textSec, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('退出', style: TextStyle(color: p.primary)),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await _leave();
  }

  Future<void> _edit() async {
    final d = _detail;
    if (d == null) return;
    final saved = await showBlessingEditor(context, initial: d.project);
    if (saved == true) _load();
  }

  Future<void> _delete() async {
    final p = AppPalette.p;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.card,
        title: Text('删除该祈福？',
            style: TextStyle(
                fontSize: 16, fontWeight: FontWeight.w700, color: p.text)),
        content: Text('删除后，此祈福及其参与记录将一并移除。',
            style: TextStyle(fontSize: 13, color: p.textSec, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: p.textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: p.primary)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await BlessingService.instance.delete(widget.id);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) _toast(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    final d = _detail;
    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        elevation: 0,
        title: Text('祈福详情',
            style: TextStyle(
                color: p.text, fontSize: 16, fontWeight: FontWeight.w600)),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: p.text),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          if (d?.progress?.joined == true)
            IconButton(
              tooltip: '退出祈福',
              onPressed: _busy ? null : _confirmLeave,
              icon: Icon(Icons.logout, size: 20, color: p.textSec),
            ),
          if (d?.project.isOwner == true)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_horiz, color: p.text),
              onSelected: (v) {
                if (v == 'edit') _edit();
                if (v == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('编辑')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
        ],
      ),
      body: _loading
          ? Center(
              child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 2.4, color: p.accent),
              ),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: TextStyle(fontSize: 13, color: p.textSec)),
                      const SizedBox(height: 10),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : _body(p, d!),
    );
  }

  Widget _body(PaletteData p, BlessingDetail d) {
    final proj = d.project;
    final prog = d.progress;
    final joined = prog?.joined == true;
    final done = prog?.isDone == true;
    final blessedToday = prog?.doneToday() ?? false;
    final doneCount = prog?.doneCount ?? 0;
    final images = proj.imageList.where((e) => e.id.isNotEmpty || e.hasUrl).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 30),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(proj.title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.8,
                      height: 1.5,
                      color: p.text.withValues(alpha: 0.82))),
              if (images.isNotEmpty) ...[
                const SizedBox(height: 20),
                _blessingImageGrid(context, p, images),
              ],
              const SizedBox(height: 18),
              if (_author != null) _authorRow(p, _author!),
              if (proj.target.isNotEmpty)
                _kv(p, Icons.person_outline, '回向', proj.target),
              _kv(p, Icons.groups_outlined, '祈福', '已有 ${d.joinerCount} 人祈福'),
              _kv(p, Icons.event_outlined, '周期',
                  '${proj.totalDays} 天 · 起于 ${proj.startDate}'),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
          decoration: BoxDecoration(
            color: p.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _barSection(
                p,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _detailSectionTitle(p, '我的祈福'),
                        const Spacer(),
                        if (done) _tag(p, '已圆满'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    if (!joined) ...[
                      _hint(p, '参与后即可每日祈福，与大家一同回向。'),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerRight,
                        child: _compactJoinButton(p),
                      ),
                    ] else ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: proj.totalDays <= 0
                              ? 0
                              : (doneCount / proj.totalDays).clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: p.border,
                          valueColor: AlwaysStoppedAnimation<Color>(p.primary),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                                '已祈福 $doneCount 天 / 共 ${proj.totalDays} 天',
                                style: TextStyle(
                                    fontSize: 12, color: p.textSec)),
                          ),
                          if (!done) ...[
                            const SizedBox(width: 8),
                            _compactBlessButton(p, blessedToday),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (proj.methods.isNotEmpty)
                _barSection(
                  p,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detailSectionTitle(p, '祈福方式'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final m in proj.methods)
                            if (m.label.isNotEmpty) _tag(p, m.label),
                        ],
                      ),
                    ],
                  ),
                ),
              if (proj.dedication.trim().isNotEmpty)
                _barSection(
                  p,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detailSectionTitle(p, '回向文'),
                      const SizedBox(height: 8),
                      Text(proj.dedication,
                          style: TextStyle(
                              fontSize: 13.5, color: p.text, height: 1.7)),
                    ],
                  ),
                ),
              _barSection(
                p,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _detailSectionTitle(p, '完成记录'),
                    const SizedBox(height: 8),
                    if (!joined)
                      _hint(p, '参与后显示每日祈福记录。')
                    else ...[
                      if (prog!.doneDates.isEmpty)
                        _hint(p, '尚无打卡记录。')
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final date in ([...prog.doneDates]..sort()))
                              _tag(
                                  p,
                                  date.length >= 10
                                      ? date.substring(5)
                                      : date),
                          ],
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _barSection(PaletteData p, Widget child) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: child,
    );
  }

  Widget _detailSectionTitle(PaletteData p, String text) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 15,
          decoration: BoxDecoration(
            color: p.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: p.textSec,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }

  Widget _authorRow(PaletteData p, UserProfile author) {
    final ownerId = _detail?.project.ownerUserId ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(Icons.person_pin_outlined,
                size: 15, color: p.textSec),
          ),
          const SizedBox(width: 8),
          Text('发起人：',
              style: TextStyle(fontSize: 13, color: p.textSec)),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(author.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: p.text)),
                ),
                if (author.verified) ...[
                  const SizedBox(width: 3),
                  const Icon(Icons.verified,
                      size: 14, color: Color(0xFF70867A)),
                ],
                if (author.account.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Flexible(
                    child: AccountLink(
                      account: author.account,
                      onTap: ownerId.isEmpty
                          ? null
                          : () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => UserSpacePage(
                                      userId: ownerId,
                                      userName: author.name),
                                ),
                              ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactJoinButton(PaletteData p) {
    return FilledButton(
      onPressed: _busy ? null : _join,
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: const Text('参与祈福', style: TextStyle(fontSize: 13)),
    );
  }

  Widget _compactBlessButton(PaletteData p, bool blessedToday) {
    return FilledButton.icon(
      onPressed: (blessedToday || _busy) ? null : _bless,
      style: FilledButton.styleFrom(
        backgroundColor: p.primary,
        disabledBackgroundColor: p.border,
        disabledForegroundColor: p.textHint,
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
      ),
      icon: Icon(blessedToday ? Icons.check : Icons.spa_outlined, size: 14),
      label: Text(blessedToday ? '今日已祈福' : '今日祈福',
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
    );
  }

  Widget _kv(PaletteData p, IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1.5),
            child: Icon(icon, size: 15, color: p.textSec),
          ),
          const SizedBox(width: 8),
          Text('$label：',
              style: TextStyle(fontSize: 13, color: p.textSec)),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 13, color: p.text)),
          ),
        ],
      ),
    );
  }
}
