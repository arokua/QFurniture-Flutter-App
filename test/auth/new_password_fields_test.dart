import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:Qtoys/features/auth/presentation/widgets/new_password_fields.dart';

void main() {
  late TextEditingController password;
  late TextEditingController confirm;

  setUp(() {
    password = TextEditingController();
    confirm = TextEditingController();
  });

  tearDown(() {
    password.dispose();
    confirm.dispose();
  });

  Future<void> pump(WidgetTester tester, {bool enabled = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewPasswordFields(
            passwordController: password,
            confirmController: confirm,
            enabled: enabled,
          ),
        ),
      ),
    );
  }

  testWidgets('the strength meter stays hidden until typing starts',
      (tester) async {
    await pump(tester);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    await tester.enterText(find.byType(TextFormField).first, 'Trumpet9Walrus');
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('the meter reflects strength as the password improves',
      (tester) async {
    await pump(tester);
    final field = find.byType(TextFormField).first;

    await tester.enterText(field, 'abc');
    await tester.pump();
    expect(find.text('Too short'), findsOneWidget);

    await tester.enterText(field, 'trumpetwalrus');
    await tester.pump();
    expect(find.text('Weak'), findsOneWidget);

    await tester.enterText(field, 'Trumpet9Walrus');
    await tester.pump();
    expect(find.text('Strong'), findsOneWidget);
  });

  testWidgets('a match is confirmed only once both fields agree',
      (tester) async {
    await pump(tester);
    final fields = find.byType(TextFormField);

    await tester.enterText(fields.first, 'Trumpet9Walrus');
    await tester.enterText(fields.last, 'Trumpet9Walru');
    await tester.pump();
    expect(find.text('Passwords match'), findsNothing);

    await tester.enterText(fields.last, 'Trumpet9Walrus');
    await tester.pump();
    expect(find.text('Passwords match'), findsOneWidget);
  });

  testWidgets('feedback is local — no async gap before the meter updates',
      (tester) async {
    await pump(tester);
    await tester.enterText(find.byType(TextFormField).first, 'Trumpet9Walrus');

    // A single pump with no settle: if any of this waited on a future or a
    // debounce, the label would not be there yet.
    await tester.pump();
    expect(find.text('Strong'), findsOneWidget);
  });

  testWidgets('both fields are disabled while a submission is in flight',
      (tester) async {
    await pump(tester, enabled: false);
    final fields = tester.widgetList<TextFormField>(find.byType(TextFormField));
    expect(fields, hasLength(2));
    for (final f in fields) {
      expect(f.enabled, isFalse);
    }
  });

  testWidgets('a mismatch is reported once, by the confirm field only',
      (tester) async {
    await pump(tester);
    final fields = find.byType(TextFormField);

    await tester.enterText(fields.first, 'Trumpet9Walrus');
    await tester.enterText(fields.last, 'something-else');
    await tester.pump();

    expect(find.text("These passwords don't match."), findsOneWidget);
    expect(find.text('Passwords match'), findsNothing);
  });
}
