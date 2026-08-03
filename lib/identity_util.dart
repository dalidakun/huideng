/// 实名认证输入校验：真实姓名 + 18 位身份证号（GB 11643-1999）。
///
/// 说明：仅凭格式校验无法与公安系统比对身份证真伪，
/// 真正的实名认证需接入第三方人证核验服务（如阿里云/腾讯云实名认证 API）。
/// 这里做的是最严格的本地/服务端格式校验：
///  - 18 位数字，末位允许 X（x 自动转大写）
///  - 前 2 位为有效地区码（11-82）
///  - 第 7-14 位为真实存在的出生日期（不晚于今天）
///  - 第 18 位校验码与权重算法计算结果一致（可拦截 90% 以上随意输入）
library;

/// 校验真实姓名：2-20 位汉字，允许少数民族姓名中的间隔号 ·。
/// 合法返回 null，否则返回可直接展示的错误提示。
String? validateRealName(String raw) {
  final n = raw.trim();
  if (n.isEmpty) return '请输入真实姓名';
  if (n.length < 2 || n.length > 20) return '姓名长度需为 2-20 个汉字';
  if (!RegExp(r'^[\u4e00-\u9fa5·]+$').hasMatch(n)) {
    return '姓名仅支持汉字与间隔号 ·';
  }
  return null;
}

/// 校验 18 位身份证号（含地区码、出生日期、校验位）。
/// 合法返回 null，否则返回可直接展示的错误提示。
String? validateIdCard(String raw) {
  final id = raw.trim().toUpperCase();
  if (id.isEmpty) return '请输入身份证号';
  if (!RegExp(r'^\d{17}[\dX]$').hasMatch(id)) {
    return '身份证号需为 18 位数字，末位可为 X';
  }
  final region = int.parse(id.substring(0, 2));
  if (region < 11 || region > 82) return '身份证号前两位地区码无效';
  final y = int.parse(id.substring(6, 10));
  final m = int.parse(id.substring(10, 12));
  final d = int.parse(id.substring(12, 14));
  final birth = DateTime(y, m, d);
  if (birth.year != y || birth.month != m || birth.day != d) {
    return '身份证号中的出生日期无效';
  }
  if (birth.isAfter(DateTime.now())) return '身份证号中的出生日期无效';
  const weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2];
  const codes = '10X98765432';
  var sum = 0;
  for (var i = 0; i < 17; i++) {
    sum += int.parse(id[i]) * weights[i];
  }
  if (codes[sum % 11] != id[17]) return '身份证号校验位不正确，请核对';
  return null;
}
