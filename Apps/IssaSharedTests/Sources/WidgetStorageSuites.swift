import Testing

/// Parent of every suite that points `CurrentBookSnapshotStore.directoryOverride`
/// at a temporary directory. That override is process-global, and `.serialized`
/// only orders the tests inside one suite: two suites could run side by side,
/// and one resetting the override while the other's cover write was suspended
/// sent the write to the real container, or lost it. Serialised here, the
/// nested suites run one after another.
///
/// Not only the suites that set the override: any suite whose tests reach
/// `CurrentBookSnapshotStore` belongs here too. Leaving an account — a
/// sign-out, a switch of account or of server, a re-identified session —
/// clears the store through `CurrentBookPublisher.clear()`, in whichever
/// directory is the override at that moment, and run beside a widget suite it
/// deleted that suite's files mid-test. A new suite that drives `AppModel`
/// through any of those, or reads the store, is nested the same way.
@Suite("Widget storage", .serialized)
enum WidgetStorage {}
