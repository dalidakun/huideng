/// 腾讯云开发 CloudBase 配置。
///
/// 在「云开发控制台」获取，填入下面常量即可使用：
///  - envId：环境 ID（如 `your-env-id`）
///  - region：地域，短信验证码登录仅支持 `ap-shanghai`（上海）
///  - accessKey：Publishable Key（云开发平台 → 环境 → API Key 配置中生成）
///
/// 注意：类名不用 `CloudBaseConfig`，因为 cloudbase_flutter SDK 内部已有同名类。
class CloudBaseAppConfig {
  CloudBaseAppConfig._();

  /// 环境 ID（必填）
  static const String envId = 'randeng-d8gs968w22a3d98e8';

  /// 地域（默认 ap-shanghai，短信登录仅上海可用）
  static const String region = 'ap-shanghai';

  /// Publishable Key（客户端匿名访问凭证）
  static const String accessKey = 'eyJhbGciOiJSUzI1NiIsImtpZCI6IjlkMWRjMzFlLWI0ZDAtNDQ4Yi1hNzZmLWIwY2M2M2Q4MTQ5OCJ9.eyJpc3MiOiJodHRwczovL3JhbmRlbmctZDhnczk2OHcyMmEzZDk4ZTguYXAtc2hhbmdoYWkudGNiLWFwaS50ZW5jZW50Y2xvdWRhcGkuY29tIiwic3ViIjoiYW5vbiIsImF1ZCI6InJhbmRlbmctZDhnczk2OHcyMmEzZDk4ZTgiLCJleHAiOjQwODkyNDU0MTEsImlhdCI6MTc4NTU2MjIxMSwibm9uY2UiOiJYTmpVYVlTclJONi1ZVkk3bUlOUXF3IiwiYXRfaGFzaCI6IlhOalVhWVNyUk42LVlWSTdtSU5RcXciLCJuYW1lIjoiQW5vbnltb3VzIiwic2NvcGUiOiJhbm9ueW1vdXMiLCJwcm9qZWN0X2lkIjoicmFuZGVuZy1kOGdzOTY4dzIyYTNkOThlOCIsIm1ldGEiOnsicGxhdGZvcm0iOiJQdWJsaXNoYWJsZUtleSJ9LCJ1c2VyX3R5cGUiOiIiLCJjbGllbnRfdHlwZSI6ImNsaWVudF91c2VyIiwiaXNfc3lzdGVtX2FkbWluIjpmYWxzZX0.hCs04BM4hFTqIcdf0SS7vgnIP9-Um4vvwWLNzHlSTaEQ8QzAcaFoW2foDJE7ReiiOPYgnOXw75TcsdHIr6HsRMNgalCNGNmjxRv2WSK3dpgIe6wr65tNOn5eTxWM-M-96hgNLpVksUDw46Ejq58rINjGl674DPw-FxeGc8EbngInBkJSN-6-XWwTCglGDTRdygeR70CQGwbuYjw8MYvFxAo190ENtSJcWZf9ZphlgIj52mMoQXqE1FsefSQEfSDjFyuh1RHSRkNVEbecmO98J8ybQjbkkt0p905DoQucKpz_W6MvMwkDTeH3jnIwYguBs8G_j_jcXQtAguPGZ6ed8w';
}
