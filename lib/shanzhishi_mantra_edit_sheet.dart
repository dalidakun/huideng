import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'shanzhishi_mantra_store.dart';

/// 添加密咒面板：一个输入框 + 取消/添加，保存成功返回密咒名。
/// 与【添加善知识】同款底部上拉面板外观（圆角 20、顶部拖杆），但内容只有名字。
class ShanZhiShiMantraEditSheet extends StatefulWidget {
  const ShanZhiShiMantraEditSheet({super.key});

  /// 弹出添加面板；保存成功返回密咒名，取消返回 null。
  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: AppPalette.p.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: const ShanZhiShiMantraEditSheet(),
      ),
    );
  }

  @override
  State<ShanZhiShiMantraEditSheet> createState() =>
      _ShanZhiShiMantraEditSheetState();
}

class _ShanZhiShiMantraEditSheetState
    extends State<ShanZhiShiMantraEditSheet> {
  final TextEditingController _nameCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    final ok = await ShanZhiShiMantraStore.instance.add(name);
    if (!mounted) return;
    if (!ok) {
      setState(() => _saving = false);
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    final p = AppPalette.p;
    // 重名（与内置或已存密咒同名）时贴在输入框下方的错误提示。
    final name = _nameCtrl.text.trim();
    final store = ShanZhiShiMantraStore.instance;
    final duplicated = name.isNotEmpty &&
        store.mantras.any((m) => m.trim() == name);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 顶部长条拖杆。
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: p.textHint,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '添加密咒',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: p.text,
                    letterSpacing: 1,
                  ),
                ),
              ),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: Icon(Icons.close, size: 20, color: p.textSec),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('密咒名称',
                  style:
                      TextStyle(fontSize: 12, color: p.textSec, letterSpacing: 0.5)),
              const SizedBox(height: 8),
              TextField(
                controller: _nameCtrl,
                autofocus: true,
                maxLength: 30,
                onChanged: (_) => setState(() {}),
                style:
                    TextStyle(fontSize: 16, color: p.text, letterSpacing: 1),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: '如：药师灌顶真言',
                  hintStyle: TextStyle(fontSize: 14, color: p.textHint),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: p.accent),
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
              if (duplicated)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '已有相同的密咒：换一个名字，或照旧展示已有的那条',
                    style: TextStyle(fontSize: 12, color: p.accentDeep),
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child:
                        Text('取消', style: TextStyle(fontSize: 14, color: p.textSec)),
                  ),
                  const SizedBox(width: 6),
                  FilledButton(
                    onPressed: name.isEmpty || _saving ? null : _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: p.primary,
                      foregroundColor: p.card,
                      disabledBackgroundColor: p.muted,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 10),
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    child: const Text('添加'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
