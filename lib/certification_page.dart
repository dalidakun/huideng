import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_palette.dart';
import 'admin_manage_page.dart';
import 'auth_service.dart';
import 'cloud_notes_service.dart';
import 'login_page.dart';
import 'settings_widgets.dart';

Color get _gold => AppPalette.p.accent;
Color get _bg => AppPalette.p.bg;
Color get _card => AppPalette.p.card;
Color get _text => AppPalette.p.text;
Color get _textSec => AppPalette.p.textSec;
Color get _textHint => AppPalette.p.textHint;
Color get _border => AppPalette.p.border;

/// 「订阅服务」页：无限次 AI 白话翻译（附赠支持者徽标）。
///
/// 收款流程（个人收款码没有支付回调，不做自动核销）：
/// 1. 用户扫码付款，并在付款备注里填写自己的账户名或邮箱；
/// 2. 管理员在 App 内「关于我们 → 管理员 → 订阅服务」按账户名/邮箱
///    手动开通无限翻译并附赠徽标；
/// 3. 用户回到本页即可看到「已开通」。
///
/// 页面介绍的重点是 AI 翻译服务，徽标是随订阅附赠的权益。
class CertificationPage extends StatefulWidget {
  const CertificationPage({super.key});

  @override
  State<CertificationPage> createState() => _CertificationPageState();
}

class _CertificationPageState extends State<CertificationPage> {
  bool _loading = true;
  bool _verified = false;
  bool _banned = false;
  bool _isRootAdmin = false;
  Map<String, dynamic> _quota = const {};
  String _accountName = '';
  String _email = '';
  String _uid = '';

  static const String _wechatQr = 'assets/images/weixin.png';
  static const String _alipayQr = 'assets/images/zhifubao.png';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    var verified = false;
    var verifiedKnown = false;
    var banned = false;
    var isRootAdmin = false;
    Map<String, dynamic> quota = const {};
    if (AuthService.instance.isLoggedIn) {
      try {
        final info = await CloudNotesService.instance.getMyVerification();
        verified = info.verified;
        banned = info.banned;
        verifiedKnown = true;
      } catch (_) {}
      try {
        quota = await CloudNotesService.instance.getMyAiQuota();
      } catch (_) {}
      try {
        isRootAdmin = await CloudNotesService.instance.isRootAdmin();
      } catch (_) {}
      // 把服务端的订阅状态写回本地：关闭本页后，侧边栏/个人页立即显示徽标，
      // 不必等下一次同步。仅在云端查询成功时写入，避免网络失败误清徽标。
      if (verifiedKnown) {
        final prefs = await SharedPreferences.getInstance();
        if ((prefs.getBool('user_verified') ?? false) != verified) {
          await prefs.setBool('user_verified', verified);
        }
        if (!verified) await prefs.remove('user_verified_name');
      }
    }
    final account = AuthService.instance.isLoggedIn
        ? await AuthService.instance.getAccountName()
        : '';
    final email = AuthService.instance.isLoggedIn
        ? await AuthService.instance.getAccountEmail()
        : '';
    final uid = AuthService.instance.currentUser.value?.id ?? '';
    if (!mounted) return;
    setState(() {
      _loading = false;
      _verified = verified;
      _banned = banned;
      _isRootAdmin = isRootAdmin;
      _quota = quota;
      _accountName = account.trim();
      _email = email.trim();
      _uid = uid.trim();
    });
  }

  int _qInt(String key) {
    final v = _quota[key];
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? 0;
  }

  /// 无限翻译：以服务端额度为准，徽标有效也视为已开通（旧数据兜底）。
  bool get _unlimited => _quota['unlimited'] == true || _verified;

  /// 免费额度是否已用完（用完时页面不再显示次数，只提示开通）。
  bool get _freeExhausted {
    if (_unlimited || _quota.isEmpty) return false;
    return _qInt('remaining') <= 0;
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _copy(String value, String label) async {
    if (value.isEmpty) {
      _toast('暂无可复制的$label');
      return;
    }
    await Clipboard.setData(ClipboardData(text: value));
    _toast('已复制$label：$value');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: '订阅服务',
      child: _loading
          ? Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
            )
          : _banned
              ? _bannedView()
              : ListView(
                  padding: const EdgeInsets.only(top: 8, bottom: 40),
                  children: [
                    _heroCard(),
                    const SizedBox(height: 22),
                    _sectionLabel('订阅包含'),
                    const SizedBox(height: 10),
                    _featureCard(),
                    // 已开通后不再展示付款信息，避免让用户误以为还要再付一次。
                    if (!_unlimited) ...[
                      const SizedBox(height: 22),
                      _sectionLabel('我的账户信息'),
                      const SizedBox(height: 10),
                      _accountCard(),
                      // 未登录时先登录：付款备注必须对应一个可被管理员查找的账号。
                      if (AuthService.instance.isLoggedIn) ...[
                        const SizedBox(height: 22),
                        _sectionLabel('开通步骤'),
                        const SizedBox(height: 10),
                        _stepsCard(),
                        const SizedBox(height: 22),
                        _sectionLabel('扫码付款'),
                        const SizedBox(height: 10),
                        _payCard(),
                      ],
                    ],
                    if (!_unlimited) ...[
                      const SizedBox(height: 18),
                      _footerNotes(),
                    ],
                    if (_isRootAdmin) ...[
                      const SizedBox(height: 22),
                      _sectionLabel('管理员'),
                      const SizedBox(height: 10),
                      SettingsCard(
                        children: [
                          SettingsTile(
                            icon: Icons.admin_panel_settings_outlined,
                            iconColor: _gold,
                            title: '订阅服务管理',
                            subtitle: '按账户名 / 邮箱 / 用户ID 开通',
                            trailing: Icon(Icons.chevron_right,
                                color: _textHint, size: 20),
                            onTap: () => Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const AdminManagePage(),
                              ),
                            ).then((_) => _load()),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: _textSec,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 顶部主卡：先讲 AI 翻译无限次，再提附赠徽标。
  Widget _heroCard() {
    final active = _unlimited;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppPalette.p.tintBg, _card],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppPalette.p.borderSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.auto_awesome, color: _gold, size: 26),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      active ? '无限翻译已开通' : 'AI 翻译 · 无限次',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: _text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      active
                          ? '感谢支持，AI 翻译已不限次数'
                          : '全经藏任意段落，随时翻译',
                      style: TextStyle(fontSize: 12.5, color: _textSec),
                    ),
                  ],
                ),
              ),
              if (active)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '已开通',
                    style: TextStyle(
                      fontSize: 11,
                      color: _gold,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          if (active)
            Row(
              children: [
                Icon(Icons.all_inclusive, size: 18, color: _gold),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'AI 翻译不限次数 · 认证徽标已点亮',
                    style: TextStyle(
                      fontSize: 13,
                      color: _text,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            )
          else ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '¥199',
                  style: TextStyle(
                    fontSize: 32,
                    height: 1,
                    fontWeight: FontWeight.w800,
                    color: _gold,
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    '一次性 · 长期有效',
                    style: TextStyle(fontSize: 12, color: _textSec),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              _freeExhausted
                  ? '免费翻译额度已用完。开通订阅后，AI 翻译不再受次数限制。'
                  : '开通后 AI 翻译不受次数限制，并获取用户认证徽标。',
              style: TextStyle(fontSize: 12.5, color: _textSec, height: 1.6),
            ),
          ],
        ],
      ),
    );
  }

  Widget _featureCard() {
    return SettingsCard(
      children: [
        SettingsTile(
          icon: Icons.all_inclusive,
          iconColor: _gold,
          title: '无限次 AI 翻译',
          subtitle: '不再受免费额度限制，任意段落随时翻译',
        ),
        const SettingsDivider(),
        SettingsTile(
          icon: Icons.menu_book_outlined,
          iconColor: _gold,
          title: '全经藏通用',
          subtitle: '所有经文、所有段落都可使用',
        ),
        const SettingsDivider(),
        SettingsTile(
          icon: Icons.verified_outlined,
          iconColor: _gold,
          title: '徽标认证',
          subtitle: '昵称旁展示，长期有效',
        ),
        const SettingsDivider(),
        SettingsTile(
          icon: Icons.workspace_premium_outlined,
          iconColor: _gold,
          title: '一次性付费',
          subtitle: '无需按月续费，长期有效',
        ),
      ],
    );
  }

  Widget _accountCard() {
    final loggedIn = AuthService.instance.isLoggedIn;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '付款备注请填写以下任一信息',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: _text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow(
            label: '账户名',
            value: _accountName.isEmpty ? '未设置' : '@$_accountName',
            copyValue: _accountName,
            copyLabel: '账户名',
            emptyHint: loggedIn ? '可到「个人资料」设置账户名' : '请先登录',
          ),
          const SizedBox(height: 10),
          _infoRow(
            label: '邮箱',
            value: _email.isEmpty ? '未绑定' : _email,
            copyValue: _email,
            copyLabel: '邮箱',
            emptyHint: loggedIn ? '可只填账户名' : '请先登录',
          ),
          const SizedBox(height: 10),
          _infoRow(
            label: '用户ID',
            value: _uid.isEmpty ? '未登录' : _uid,
            copyValue: _uid,
            copyLabel: '用户ID',
            emptyHint: loggedIn ? '注册后不可更改' : '请先登录',
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              loggedIn
                  ? '付款时请务必在[备注]位置，粘贴以上任一信息，方便核对开通服务。'
                  : '订阅需要绑定账户。请先登录，再回到本页查看你的账户名、邮箱和用户ID。',
              style: TextStyle(
                fontSize: 11.5,
                color: loggedIn ? const Color(0xFFC0392B) : _textSec,
                height: 1.6,
              ),
            ),
          ),
          if (!loggedIn) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 40,
              child: FilledButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const LoginPage()),
                ).then((_) => _load()),
                style: FilledButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: const Text('去登录',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow({
    required String label,
    required String value,
    required String copyValue,
    required String copyLabel,
    required String emptyHint,
  }) {
    final empty = copyValue.isEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          child: Text(
            label,
            style: TextStyle(fontSize: 12.5, color: _textHint),
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  color: empty ? _textHint : _text,
                  fontWeight: empty ? FontWeight.w400 : FontWeight.w600,
                ),
              ),
              if (empty) ...[
                const SizedBox(height: 2),
                Text(
                  emptyHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: _textHint),
                ),
              ],
            ],
          ),
        ),
        if (!empty)
          IconButton(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 32),
            icon: Icon(Icons.copy_rounded, size: 16, color: _gold),
            tooltip: '复制$copyLabel',
            onPressed: () => _copy(copyValue, copyLabel),
          ),
      ],
    );
  }

  Widget _stepsCard() {
    final accountHint = _accountName.isEmpty
        ? '付款时在备注里填写你的邮箱或用户ID（账户名可先到「个人资料」设置），方便我们核对。'
        : '付款时在备注里填写你的账户名 @$_accountName、邮箱或用户ID，方便我们核对。';
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          _step(
            1,
            '扫码付款',
            '用微信或支付宝扫描下方收款码，支付 ¥199。',
          ),
          const SizedBox(height: 14),
          _step(
            2,
            '填写付款备注',
            accountHint,
          ),
          const SizedBox(height: 14),
          _step(
            3,
            '等待人工开通',
            '我们收到款项并核对备注后，立即为你开通无限翻译，并添加认证徽标。',
          ),
          const SizedBox(height: 14),
          _step(
            4,
            '回到本页查看',
            '开通后回到本页即可看到「已开通」，AI 翻译立即变为无限次，并获得认证徽标。',
          ),
          const SizedBox(height: 14),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _bg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 与首行文字视觉对齐（文本行高 18.4，图标 15）。
                Padding(
                  padding: const EdgeInsets.only(top: 1.5),
                  child: Icon(Icons.info_outline, size: 15, color: _gold),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '如果忘记备注，请到「设置 → 关于我们 → 反馈问题」重新填写备注信息，亦可开通。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: const Color(0xFF2E7D32),
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _step(int index, String title, String desc) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Text(
            '$index',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: _gold,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: _text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                desc,
                style: TextStyle(fontSize: 12, color: _textSec, height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _payCard() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _payQrCard(
                label: '微信',
                asset: _wechatQr,
              ),
              const SizedBox(width: 12),
              _payQrCard(
                label: '支付宝',
                asset: _alipayQr,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '微信 / 支付宝任选其一，付款金额 ¥199',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12.5,
              color: _text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '点击收款码可放大；付款时务必填写备注。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 10.5, color: _textHint),
          ),
        ],
      ),
    );
  }

  Widget _payQrCard({required String label, required String asset}) {
    return Expanded(
      child: Column(
        children: [
          GestureDetector(
            onTap: () => _showQr(asset, label),
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppPalette.p.borderSoft),
              ),
              child: Image.asset(
                asset,
                width: double.infinity,
                height: 150,
                fit: BoxFit.contain,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: _text,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// 点击收款码全屏放大，点击任意处关闭。
  void _showQr(String asset, String label) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        // 取屏幕短边，保证横屏 / 桌面窗口下也能完整放下收款码。
        final side = MediaQuery.sizeOf(ctx).shortestSide * 0.8;
        return GestureDetector(
          onTap: () => Navigator.pop(ctx),
          behavior: HitTestBehavior.opaque,
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                InteractiveViewer(
                  maxScale: 5,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(14),
                    child: Image.asset(
                      asset,
                      width: side,
                      height: side,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '$label收款码 · 点击任意处关闭',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _footerNotes() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          Text(
            '虚拟服务一经开通不支持退款。',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11, color: _textHint, height: 1.7),
          ),
        ],
      ),
    );
  }

  Widget _bannedView() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _card,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: _border),
          ),
          child: Column(
            children: [
              const Icon(Icons.block, size: 42, color: Color(0xFFA8552F)),
              const SizedBox(height: 12),
              Text(
                '当前账号已被限制',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: _text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'AI 翻译和订阅暂不可用。如有疑问，可提交申诉，管理员会在后台人工复核。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: _textSec, height: 1.7),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 48,
          child: ElevatedButton(
            onPressed: _appeal,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              elevation: 0,
            ),
            child: const Text(
              '提交申诉',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _appeal() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        title: Text('提交申诉', style: TextStyle(color: _text)),
        content: TextField(
          controller: ctrl,
          maxLines: 4,
          maxLength: 500,
          style: TextStyle(color: _text),
          decoration: const InputDecoration(
            hintText: '说明情况，管理员会人工复核',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: _textSec)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('提交'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await CloudNotesService.instance.submitFeatureAppeal(ctrl.text.trim());
        _toast('申诉已提交，请等待处理');
      } catch (e) {
        _toast(e is CloudApiException ? e.message : '提交失败，请稍后重试');
      }
    }
    ctrl.dispose();
  }
}
