import 'package:flutter_test/flutter_test.dart';
import 'package:bookoo_brew/brewguide_api.dart';
import 'package:bookoo_brew/models.dart';

void main() {
  Bean bean(String name, String? roastDate) => Bean(
        id: name,
        name: name,
        roastLevel: 'light',
        roastDate: roastDate,
        remaining: 100,
        raw: const {},
      );

  test('sortBeansForDisplay puts missing and in-transit roast dates last', () {
    final beans = [
      bean('in transit', '在途'),
      bean('march', '2026-03-01'),
      bean('missing', null),
      bean('empty', ''),
      bean('january', '2026-01-15'),
      bean('slash date', '2026/02/01'),
    ];

    BrewGuideApi.sortBeansForDisplay(beans);

    expect(beans.map((b) => b.name), [
      'january',
      'slash date',
      'march',
      'empty',
      'in transit',
      'missing',
    ]);
  });
}
