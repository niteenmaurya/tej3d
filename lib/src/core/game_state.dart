/// A small state machine for game flow: menu, playing, paused, game over.
///
/// ```dart
/// enum Flow { menu, playing, paused, over }
/// final flow = GameStateMachine<Flow>(Flow.menu);
/// flow.listen((from, to) => print('$from -> $to'));
/// flow.go(Flow.playing);
/// ```
class GameStateMachine<T extends Enum> {
  GameStateMachine(this._state, {Map<T, Set<T>>? allowed}) : _allowed = allowed;

  T _state;
  final Map<T, Set<T>>? _allowed;
  final List<void Function(T from, T to)> _listeners = [];

  T get state => _state;

  /// Adds a listener. Returns a function that removes it.
  void Function() listen(void Function(T from, T to) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Moves to [next]. Returns false if it is the same state or not allowed.
  bool go(T next) {
    if (next == _state) return false;
    final rules = _allowed;
    if (rules != null && !(rules[_state]?.contains(next) ?? false)) {
      return false;
    }
    final from = _state;
    _state = next;
    for (final l in List.of(_listeners)) {
      l(from, next);
    }
    return true;
  }
}
