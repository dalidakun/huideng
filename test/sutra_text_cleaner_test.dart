import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/sutra_text_cleaner.dart';

const _block = '【经文资讯】大正新修大藏经 第 12 册 No. 366 佛说阿弥陀经\r\n'
    '【版本记录】发行日期：2025-12，最后更新：2025-01-30\r\n'
    '【编辑说明】本资料库由 财团法人佛教电子佛典基金会（CBETA）依「大正新修大藏经」所编辑\r\n'
    '【原始资料】萧镇国大德提供\r\n'
    '【版权宣告】https://cbeta.org/copyright\r\n'
    '【制作说明】感谢志工黄训庆先生将本佛典转换至 DOCX 格式。\r\n';

void main() {
  group('SutraTextCleaner.strip', () {
    test('去掉说明块与紧贴其前的卷末题名', () {
      const content = '佛说阿弥陀经\r\n如是我闻。\r\n佛说此经已，皆大欢喜。\r\n'
          '佛说阿弥陀经卷第一\r\n$_block';
      final out = SutraTextCleaner.strip(content);
      expect(out, '佛说阿弥陀经\r\n如是我闻。\r\n佛说此经已，皆大欢喜。\r\n');
      expect(out.contains('【经文资讯】'), isFalse);
    });

    test('正文以句号收尾、没有题名时只删说明块', () {
      const content = '第一段。\r\n第二段。\r\n\r\n$_block';
      final out = SutraTextCleaner.strip(content);
      expect(out, '第一段。\r\n第二段。\r\n');
    });

    test('题名后还有校勘跋文时，不越过跋文删题名', () {
      const content = '正文。\r\n佛般泥洹经卷下\r\n'
          '从佛般泥洹，到永兴七年二月十一日，凡已八百八十七年。\r\n'
          '$_block';
      final out = SutraTextCleaner.strip(content);
      expect(out.contains('从佛般泥洹，到永兴七年'), isTrue);
      expect(out.contains('佛般泥洹经卷下'), isTrue);
    });

    test('单卷经重复的经名（无卷数）同样去掉', () {
      const content = '正文。\r\n般若波罗蜜多心经\r\n$_block';
      final out = SutraTextCleaner.strip(content, titleHints: ['般若波罗蜜多心经']);
      expect(out, '正文。\r\n');
    });

    test('正文里的目录条目（…卷上（大正五一 P. 833b））不误删', () {
      const content =
          '正文。\r\n三　第二十九造毘卢遮那佛像拂障难感应　三宝感应要略录卷上（大正五一 P. 833b）\r\n'
          '$_block';
      final out = SutraTextCleaner.strip(content);
      expect(out.contains('三宝感应要略录卷上'), isTrue);
    });

    test('没有说明块时原样返回', () {
      const content = '这是正文，没有说明块。\r\n';
      expect(SutraTextCleaner.strip(content), content);
    });

    test('说明块标签不在行首（正文引用）时不动', () {
      const content = '正文提到【经文资讯】这个词，但不是文末说明块。\r\n';
      expect(SutraTextCleaner.strip(content), content);
    });

    test('说明块前带「◎」装饰也能识别', () {
      const content = '正文。\r\n十住毘婆沙论卷第七\r\n◎$_block';
      final out = SutraTextCleaner.strip(content);
      expect(out, '正文。\r\n');
    });

    test('说明块不完整（缺标签）时不误删', () {
      const content = '正文。\r\n标题\r\n【经文资讯】大正藏\r\n【版本记录】x\r\n';
      expect(SutraTextCleaner.strip(content), content);
    });

    test('重复调用结果不变（幂等）', () {
      const content = '正文。\r\n某某经卷第一\r\n$_block';
      final once = SutraTextCleaner.strip(content);
      final twice = SutraTextCleaner.strip(once);
      expect(twice, once);
    });

    test('LF 换行的内容保持 LF', () {
      final lfBlock = _block.replaceAll('\r\n', '\n');
      final content = '正文。\n某某经卷第一\n$lfBlock';
      final out = SutraTextCleaner.strip(content);
      expect(out, '正文。\n');
    });
  });
}
