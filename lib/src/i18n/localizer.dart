/// Simple translations with `{name}` placeholders.
///
/// ```dart
/// final l = Localizer(tables: {
///   'en': {'lap': 'Lap {n} of {total}'},
///   'hi': {'lap': 'लैप {n} / {total}'},
/// }, locale: 'hi');
/// l.tr('lap', args: {'n': 2, 'total': 3});
/// ```
class Localizer {
  Localizer({
    required this.tables,
    this.locale = 'en',
    this.fallback = 'en',
  });

  final Map<String, Map<String, String>> tables;
  String locale;
  final String fallback;

  /// Returns the text for [key]. Falls back to the fallback language, then to
  /// the key itself.
  String tr(String key, {Map<String, Object>? args}) {
    var text = tables[locale]?[key] ?? tables[fallback]?[key] ?? key;
    if (args != null) {
      args.forEach((name, value) {
        text = text.replaceAll('{$name}', value.toString());
      });
    }
    return text;
  }
}
