/// A tiny typed event bus so game parts do not need to know each other.
///
/// ```dart
/// class Crash { final double speed; Crash(this.speed); }
/// final cancel = bus.on<Crash>((e) => print(e.speed));
/// bus.emit(Crash(30));
/// cancel();
/// ```
class EventBus {
  final Map<Type, List<void Function(Object)>> _handlers = {};

  /// Listens for events of exactly type [T]. Returns a function that cancels.
  void Function() on<T extends Object>(void Function(T event) handler) {
    void wrapped(Object e) => handler(e as T);
    (_handlers[T] ??= []).add(wrapped);
    return () => _handlers[T]?.remove(wrapped);
  }

  /// Sends [event] to everyone listening for its exact type.
  void emit(Object event) {
    final list = _handlers[event.runtimeType];
    if (list == null) return;
    for (final h in List.of(list)) {
      h(event);
    }
  }
}
