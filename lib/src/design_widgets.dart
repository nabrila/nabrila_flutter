// Apps written before Flutter 3.50 build their screens with the Material and
// Cupertino libraries bundled in Flutter; newer apps use the `material_ui` and
// `cupertino_ui` packages. Both define the same widgets as different types,
// so a `TextField` from one is not a `TextField` from the other. The SDK
// reads the app's widget tree, so it has to know both. Its own screens use
// only the packages.
//
// Delete the two bundled imports once Flutter removes those libraries.
// ignore_for_file: deprecated_member_use
import 'package:cupertino_ui/cupertino_ui.dart' as cupertino;
import 'package:flutter/cupertino.dart' as bundled_cupertino;
import 'package:flutter/material.dart' as bundled;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as material;

/// A field where a person types: what is in it is never read.
bool isTextField(Widget widget) =>
    widget is EditableText ||
    widget is material.TextField ||
    widget is bundled.TextField ||
    widget is cupertino.CupertinoTextField ||
    widget is bundled_cupertino.CupertinoTextField;

/// Material pieces every button is built from: their names tell nothing.
bool isMaterialPlumbing(Widget widget) =>
    widget is material.InkResponse ||
    widget is bundled.InkResponse ||
    widget is material.Material ||
    widget is bundled.Material;

/// Material widgets a person taps, as named in a tap's hint.
bool isMaterialTapTarget(Widget widget) =>
    widget is material.ButtonStyleButton ||
    widget is bundled.ButtonStyleButton ||
    widget is material.IconButton ||
    widget is bundled.IconButton ||
    widget is material.FloatingActionButton ||
    widget is bundled.FloatingActionButton ||
    widget is material.ListTile ||
    widget is bundled.ListTile ||
    widget is material.Chip ||
    widget is bundled.Chip ||
    widget is material.Tab ||
    widget is bundled.Tab ||
    widget is material.BottomNavigationBar ||
    widget is bundled.BottomNavigationBar ||
    widget is material.NavigationDestination ||
    widget is bundled.NavigationDestination ||
    widget is material.InkResponse ||
    widget is bundled.InkResponse;

/// Material widgets that stand for one control when a person points at it.
bool isMaterialControl(Widget widget) =>
    widget is material.ButtonStyleButton ||
    widget is bundled.ButtonStyleButton ||
    widget is material.IconButton ||
    widget is bundled.IconButton ||
    widget is material.FloatingActionButton ||
    widget is bundled.FloatingActionButton ||
    widget is material.ListTile ||
    widget is bundled.ListTile ||
    widget is material.Chip ||
    widget is bundled.Chip ||
    widget is material.InkWell ||
    widget is bundled.InkWell ||
    widget is material.Switch ||
    widget is bundled.Switch ||
    widget is material.Checkbox ||
    widget is bundled.Checkbox;

/// The message of a Material `Tooltip`, or null for any other widget.
String? tooltipMessage(Widget widget) => switch (widget) {
  material.Tooltip(:final message) => message,
  bundled.Tooltip(:final message) => message,
  _ => null,
};
