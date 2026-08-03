import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'identity_util.dart';

const Color _gold = Color(0xFFD4A06A);
const Color _bg = Color(0xFFF5EDE3);
const Color _card = Color(0xFFFFFAF5);
const Color _text = Color(0xFF3E2723);
const Color _textSec = Color(0xFF8B6B5A);
const Color _textHint = Color(0xFFC4B5A8);

/// 实名认证页：输入真实姓名与身份证号，通过格式核验后获得认证标识。
class CertificationPage extends StatefulWidget {
  const CertificationPage({super.key});

  @override
  State<CertificationPage> createState() => _CertificationPageState();
}

class _CertificationPageState extends State<CertificationPage> {
  final _nameCtrl = TextEditingController();
  final _idCtrl = TextEditingController();
  bool _loading = true;
  bool _verified = false;
  bool _submitting = false;
  String _verifiedName = '';
  int _verifiedAt = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _idCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var verified = false;
    var name = '';
    var at = 0;
    if (AuthService.instance.isLoggedIn) {
      try {
        final info = await CloudNotesService.instance.getMyVerification();
        verified = info.verified;
        name = info.realNameMasked;
        at = info.verifiedAt;
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _verified = verified;
      _verifiedName = name;
      _verifiedAt = at;
    });
  }

  Future<void> _submit() async {
    final name = _nameCtrl.text.trim();
    final idCard = _idCtrl.text.trim();
    final nameErr = validateRealName(name);
    if (nameErr != null) {
      _toast(nameErr);
      return;
    }
    final idErr = validateIdCard(idCard);
    if (idErr != null) {
      _toast(idErr);
      return;
    }
    setState(() => _submitting = true);
    try {
      final ok = await CloudNotesService.instance
          .verifyIdentity(realName: name, idCard: idCard);
      if (!mounted) return;
      if (ok) {
        final info = await CloudNotesService.instance.getMyVerification();
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('user_verified', true);
        if (info.realNameMasked.isNotEmpty) {
          await prefs.setString('user_verified_name', info.realNameMasked);
        }
        if (!mounted) return;
        setState(() {
          _verified = true;
          _verifiedName = info.realNameMasked;
          _verifiedAt = info.verifiedAt;
        });
        _toast('认证成功');
      }
    } catch (e) {
      if (mounted) _toast(e.toString());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  String _formatDate(int ms) {
    if (ms <= 0) return '';
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${t.year}年${t.month}月${t.day}日';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        shadowColor: Colors.transparent,
        iconTheme: const IconThemeData(color: _text),
        title: const Text('实名认证',
            style: TextStyle(
                color: _text,
                fontSize: 17,
                fontWeight: FontWeight.w600)),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                  color: _gold, strokeWidth: 2.5))
          : _verified
              ? _buildVerifiedView()
              : _buildForm(),
    );
  }

  Widget _buildVerifiedView() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFEBE1D6)),
          ),
          child: Column(
            children: [
              const Icon(Icons.verified, size: 64, color: Color(0xFF70867A)),
              const SizedBox(height: 16),
              const Text('已实名认证',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: _text)),
              const SizedBox(height: 10),
              if (_verifiedName.isNotEmpty)
                Text('认证姓名：$_verifiedName',
                    style: const TextStyle(
                        fontSize: 14, color: _textSec)),
              if (_verifiedAt > 0) ...[
                const SizedBox(height: 6),
                Text('认证时间：${_formatDate(_verifiedAt)}',
                    style: const TextStyle(
                        fontSize: 14, color: _textSec)),
              ],
              const SizedBox(height: 12),
              const Text('昵称旁已显示认证标识',
                  style: TextStyle(fontSize: 13, color: _textHint)),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            child: const Text('知道了',
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
          ),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            children: [
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: _card,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: const Color(0xFFEBE1D6)),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: _textSec),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '认证通过后，昵称旁将显示认证标识。\n本应用无法与公安系统比对证件真伪，仅做身份证号格式核验（18 位、地区码、出生日期、校验位）；身份信息仅保存脱敏姓名与证件哈希，不保存明文。',
                        style: TextStyle(
                            fontSize: 12,
                            color: _textSec,
                            height: 1.6),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Text('真实姓名',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _textSec)),
              const SizedBox(height: 6),
              TextField(
                controller: _nameCtrl,
                maxLength: 20,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp('[\\u4e00-\\u9fa5·]')),
                ],
                style: const TextStyle(fontSize: 16, color: _text),
                decoration: const InputDecoration(
                  hintText: '与身份证一致的姓名',
                  hintStyle: TextStyle(color: _textHint),
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: Color(0xFFEFE6DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: Color(0xFFEFE6DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: _gold, width: 1.5),
                  ),
                  filled: true,
                  fillColor: _card,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 16),
              const Text('身份证号',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: _textSec)),
              const SizedBox(height: 6),
              TextField(
                controller: _idCtrl,
                maxLength: 18,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(
                      RegExp('[0-9xX]')),
                  LengthLimitingTextInputFormatter(18),
                ],
                style: const TextStyle(fontSize: 16, color: _text),
                decoration: const InputDecoration(
                  hintText: '18 位身份证号，末位可为 X',
                  hintStyle: TextStyle(color: _textHint),
                  counterText: '',
                  border: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: Color(0xFFEFE6DB)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: Color(0xFFEFE6DB)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius:
                        BorderRadius.all(Radius.circular(12)),
                    borderSide:
                        BorderSide(color: _gold, width: 1.5),
                  ),
                  filled: true,
                  fillColor: _card,
                  contentPadding: EdgeInsets.symmetric(
                      horizontal: 16, vertical: 14),
                ),
              ),
              const SizedBox(height: 12),
              const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.lock_outline,
                      size: 14, color: _textHint),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '身份证号仅用于格式核验，云端只保存哈希，不会泄露明文；同一账号仅可认证一次。',
                      style: TextStyle(
                          fontSize: 12,
                          color: _textHint,
                          height: 1.5),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 12),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5))
                  : const Text('提交认证',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600)),
            ),
          ),
        ),
      ],
    );
  }
}
