import 'package:flutter/material.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);
const Color _border = Color(0xFFEBE1D6);

/// 通用底部输入弹窗：自行持有 TextEditingController 并随弹窗生命周期释放，
/// 避免在弹窗退出动画期间 dispose 控制器触发 `dependents.isEmpty` 断言红屏。
/// 通过 `Navigator.pop(context, 文本)` 返回输入内容。
class SheetTextInput extends StatefulWidget {
  final String title;
  final String hint;
  final String initialText;
  final int maxLength;
  final int minLines;
  final int maxLines;
  final String confirmText;

  const SheetTextInput({
    super.key,
    required this.title,
    required this.hint,
    this.initialText = '',
    this.maxLength = 500,
    this.minLines = 2,
    this.maxLines = 3,
    this.confirmText = '确定',
  });

  @override
  State<SheetTextInput> createState() => _SheetTextInputState();
}

class _SheetTextInputState extends State<SheetTextInput> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    Navigator.pop(context, text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: _text)),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                maxLength: widget.maxLength,
                minLines: widget.minLines,
                maxLines: widget.maxLines,
                style: const TextStyle(fontSize: 14, color: _text),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: const TextStyle(color: _textHint),
                  filled: true,
                  fillColor: _bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _textSec,
                        side: const BorderSide(color: _border),
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
                        backgroundColor: _gold,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        minimumSize: const Size(0, 44),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: Text(widget.confirmText),
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
