import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:nabrila/src/l10n.dart';

void main() {
  test('English is the default; es and pt follow the device locale', () {
    expect(NabrilaStrings.forLocale(const Locale('fr')).send, 'Send');
    expect(NabrilaStrings.forLocale(const Locale('en', 'US')).send, 'Send');
    expect(NabrilaStrings.forLocale(const Locale('es', 'BO')).send, 'Enviar');
    expect(NabrilaStrings.forLocale(const Locale('pt', 'BR')).send, 'Enviar');
    expect(NabrilaStrings.forLocale(const Locale('pt')).cancel, 'Cancelar');
    expect(
      NabrilaStrings.forLocale(const Locale('pt')).errQuota,
      contains('limite mensal'),
    );
    expect(
      NabrilaStrings.forLocale(const Locale('en')).errQuota,
      contains('monthly report limit'),
    );
  });
}
