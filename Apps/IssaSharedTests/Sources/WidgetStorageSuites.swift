import Testing

/// Parent of every suite that points `CurrentBookSnapshotStore.directoryOverride`
/// at a temporary directory. That override is process-global, and `.serialized`
/// only orders the tests inside one suite: two suites could run side by side,
/// and one resetting the override while the other's cover write was suspended
/// sent the write to the real container, or lost it. Serialised here, the
/// nested suites run one after another.
@Suite("Widget storage", .serialized)
enum WidgetStorage {}
