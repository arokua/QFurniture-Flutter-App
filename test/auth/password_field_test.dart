import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/auth/presentation/widgets/password_field.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

EditableText _editable(WidgetTester tester) =>
    tester.widget<EditableText>(find.byType(EditableText));

void main() {
  testWidgets('starts obscured', (tester) async {
    final controller = TextEditingController(text: 'hunter2');
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    expect(_editable(tester).obscureText, isTrue);
    expect(find.byIcon(Icons.visibility_off), findsOneWidget);
    controller.dispose();
  });

  testWidgets('the toggle reveals and re-hides the password', (tester) async {
    final controller = TextEditingController(text: 'hunter2');
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();
    expect(_editable(tester).obscureText, isFalse);
    expect(find.byIcon(Icons.visibility), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility));
    await tester.pumpAndSettle();
    expect(_editable(tester).obscureText, isTrue);
    controller.dispose();
  });

  testWidgets('toggling preserves the caret position', (tester) async {
    final controller = TextEditingController(text: 'abcdefgh');
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    // Put the caret mid-string, as if the user were editing.
    controller.selection = const TextSelection.collapsed(offset: 3);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();

    expect(controller.selection.baseOffset, 3,
        reason: 'revealing the password must not move the caret to the end');
    expect(controller.text, 'abcdefgh');
    controller.dispose();
  });

  testWidgets('toggling preserves a selection range', (tester) async {
    final controller = TextEditingController(text: 'abcdefgh');
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    controller.selection = const TextSelection(baseOffset: 2, extentOffset: 5);
    await tester.pump();

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();

    expect(controller.selection.baseOffset, 2);
    expect(controller.selection.extentOffset, 5);
    controller.dispose();
  });

  testWidgets('toggling does not clear the text', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_host(PasswordField(controller: controller)));

    await tester.enterText(find.byType(TextFormField), 'secret pass');
    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();

    expect(controller.text, 'secret pass');
    controller.dispose();
  });

  testWidgets('validation state survives a visibility toggle', (tester) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    await tester.pumpWidget(_host(Form(
      key: formKey,
      child: PasswordField(
        controller: controller,
        validator: (v) =>
            (v == null || v.length < 6) ? 'At least 6 characters' : null,
      ),
    )));

    await tester.enterText(find.byType(TextFormField), 'abc');
    formKey.currentState!.validate();
    await tester.pumpAndSettle();
    expect(find.text('At least 6 characters'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.visibility_off));
    await tester.pumpAndSettle();

    expect(find.text('At least 6 characters'), findsOneWidget,
        reason: 'the error must not be cleared by toggling visibility');
    controller.dispose();
  });

  testWidgets('the toggle is disabled while the field is disabled',
      (tester) async {
    final controller = TextEditingController(text: 'hunter2');
    await tester.pumpWidget(
      _host(PasswordField(controller: controller, enabled: false)),
    );

    final button = tester.widget<IconButton>(find.byType(IconButton));
    expect(button.onPressed, isNull);

    // warnIfMissed: the button is disabled, so missing the hit test is the point.
    await tester.tap(find.byType(IconButton), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_editable(tester).obscureText, isTrue,
        reason: 'a disabled field must not reveal the password');
    controller.dispose();
  });

  testWidgets('a custom label is rendered', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_host(
      PasswordField(controller: controller, labelText: 'New password'),
    ));
    expect(find.text('New password'), findsOneWidget);
    controller.dispose();
  });
}
