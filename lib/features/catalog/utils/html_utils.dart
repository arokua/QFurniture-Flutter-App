/// Decode common HTML entities so text displays correctly (e.g. &amp; -> &).
String decodeHtmlEntities(String text) {
  if (text.isEmpty) return text;
  String s = text
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&#8217;', "'") // right single quote
      .replaceAll('&#8216;', "'") // left single quote
      .replaceAll('&#8220;', '"')
      .replaceAll('&#8221;', '"')
      .replaceAll('&#8211;', '–')
      .replaceAll('&#8212;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&mdash;', '—');
  // Numeric decimal: &#1234;
  s = s.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final code = int.tryParse(m.group(1)!);
    if (code != null && code < 0x10FFFF) return String.fromCharCode(code);
    return m.group(0)!;
  });
  // Numeric hex: &#x1a2b; or &#X1a2b;
  s = s.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final code = int.tryParse(m.group(1)!, radix: 16);
    if (code != null && code < 0x10FFFF) return String.fromCharCode(code);
    return m.group(0)!;
  });
  return s;
}
