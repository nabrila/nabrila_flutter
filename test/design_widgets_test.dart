// Apps still on Flutter's bundled Material are tested on purpose.
// ignore_for_file: deprecated_member_use
import 'package:cupertino_ui/cupertino_ui.dart' as cupertino;
import 'package:flutter/cupertino.dart' as bundled_cupertino;
import 'package:flutter/material.dart' as bundled;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:nabrila/nabrila.dart';
import 'package:nabrila/src/design_widgets.dart';
import 'package:nabrila/src/runtime.dart';

/// An app written with one of the two Material libraries: the screen has an
/// icon button, a list tile and a text field.
typedef _Library = ({
  String name,
  Widget Function(Widget icon) iconButton,
  Widget Function(String title) listTile,
  Widget Function() textField,
  Widget Function(List<Widget> children) app,
});

final _material = (
  name: 'material_ui',
  iconButton: (Widget icon) =>
      material.IconButton(onPressed: () {}, icon: icon),
  listTile: (String title) =>
      material.ListTile(onTap: () {}, title: material.Text(title)),
  textField: () => const material.TextField(),
  app: (List<Widget> children) => material.MaterialApp(
    home: material.Scaffold(body: material.Column(children: children)),
  ),
);

final _bundled = (
  name: 'flutter/material',
  iconButton: (Widget icon) => bundled.IconButton(onPressed: () {}, icon: icon),
  listTile: (String title) =>
      bundled.ListTile(onTap: () {}, title: bundled.Text(title)),
  textField: () => const bundled.TextField(),
  app: (List<Widget> children) => bundled.MaterialApp(
    home: bundled.Scaffold(body: bundled.Column(children: children)),
  ),
);

void main() {
  tearDown(() => Nabrila.debugSetRuntime(null));

  test('knows the widgets of both libraries, and only those', () {
    void noop() {}
    for (final widget in <Widget>[
      material.TextField(),
      bundled.TextField(),
      cupertino.CupertinoTextField(),
      bundled_cupertino.CupertinoTextField(),
    ]) {
      expect(isTextField(widget), isTrue, reason: '$widget');
    }
    for (final widget in <Widget>[
      material.Checkbox(value: false, onChanged: null),
      bundled.Checkbox(value: false, onChanged: null),
      material.InkWell(onTap: noop),
      bundled.InkWell(onTap: noop),
    ]) {
      expect(isMaterialControl(widget), isTrue, reason: '$widget');
    }
    for (final widget in <Widget>[
      material.FilledButton(onPressed: noop, child: material.Text('a')),
      bundled.FilledButton(onPressed: noop, child: bundled.Text('a')),
      material.NavigationDestination(icon: material.Text('a'), label: 'a'),
      bundled.NavigationDestination(icon: bundled.Text('a'), label: 'a'),
    ]) {
      expect(isMaterialTapTarget(widget), isTrue, reason: '$widget');
    }
    expect(tooltipMessage(material.Tooltip(message: 'Save')), 'Save');
    expect(tooltipMessage(bundled.Tooltip(message: 'Save')), 'Save');
    expect(tooltipMessage(material.Text('Save')), isNull);
    expect(isMaterialPlumbing(bundled.Material()), isTrue);
    expect(isMaterialControl(material.Text('a')), isFalse);
    expect(isTextField(material.Text('a')), isFalse);
  });

  for (final library in <_Library>[_material, _bundled]) {
    testWidgets('names taps in an app on ${library.name}', (tester) async {
      final runtime = NabrilaRuntime(appKey: 'nbr_test');
      Nabrila.debugSetRuntime(runtime);
      await tester.pumpWidget(
        NabrilaScope(
          child: library.app([
            library.iconButton(const material.Icon(material.Icons.add)),
            library.listTile('Orders'),
            library.textField(),
          ]),
        ),
      );
      await tester.tap(find.byIcon(material.Icons.add));
      await tester.tap(find.text('Orders'));
      await tester.tap(find.byType(material.EditableText));
      final hints = [
        for (final event in runtime.buffer.toJson())
          if (event['kind'] == 'tap') event['targetHint'],
      ];
      expect(hints, ['IconButton', 'Orders', 'TextField']);
      runtime.delivery.dispose();
    });
  }
}
