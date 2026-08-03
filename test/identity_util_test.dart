import 'package:flutter_test/flutter_test.dart';
import 'package:my_flutter_app/identity_util.dart';

void main() {
  group('validateRealName', () {
    test('accepts Chinese names', () {
      expect(validateRealName('张三'), isNull);
      expect(validateRealName('欧阳娜娜'), isNull);
      expect(validateRealName('阿依古丽·买买提'), isNull);
    });

    test('rejects invalid names', () {
      expect(validateRealName(''), isNotNull);
      expect(validateRealName('张'), isNotNull);
      expect(validateRealName('Zhang3'), isNotNull);
      expect(validateRealName('张 三'), isNotNull);
      expect(validateRealName('张.三'), isNotNull);
      expect(validateRealName('张' * 21), isNotNull);
    });
  });

  group('validateIdCard', () {
    test('accepts valid id card', () {
      expect(validateIdCard('11010519491231002X'), isNull);
      expect(validateIdCard('11010519491231002x'), isNull);
    });

    test('rejects wrong length or characters', () {
      expect(validateIdCard(''), isNotNull);
      expect(validateIdCard('1101051949123100210'), isNotNull);
      expect(validateIdCard('11010519491231002'), isNotNull);
      expect(validateIdCard('1101051949123100AB'), isNotNull);
      expect(validateIdCard('11010519491231002a1'), isNotNull);
    });

    test('rejects invalid region code', () {
      expect(validateIdCard('101105194912310028'), isNotNull);
      expect(validateIdCard('831105194912310021'), isNotNull);
    });

    test('rejects invalid birth date', () {
      expect(validateIdCard('110105199902300026'), isNotNull);
      expect(validateIdCard('110105202801010022'), isNotNull);
    });

    test('rejects wrong checksum', () {
      expect(validateIdCard('110105194912310021'), isNotNull);
      expect(validateIdCard('110105194912310022'), isNotNull);
    });
  });
}
