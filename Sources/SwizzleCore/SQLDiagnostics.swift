#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
// The static-linux SDK links musl rather than glibc, and `stderr` lives here.
import Musl
#elseif canImport(WinSDK)
import ucrt
#endif

/// Where the builder sends warnings about statements it ran but found suspicious.
///
/// ## Why a warning rather than a type
///
/// An `UPDATE` or `DELETE` with no `WHERE` is almost always a mistake, and the
/// obvious fix — refuse it, and make the caller spell an unfiltered write
/// differently — was tried on paper and rejected. It makes the API's *shape*
/// depend on whether you happened to call `.where()`: the same operation spelled
/// two ways, with the compiler as the only clue about which one today's query
/// needs. That is a worse cost than the mistake it prevents.
///
/// So `execute(on:)` is the only spelling, on every write, filtered or not, and
/// the help moved here — where it costs no syntax at all. It informs; it does not
/// obstruct.
///
/// ## Setting a handler
///
/// The default writes one line to standard error. Point it at your logger during
/// start-up, before any query runs:
///
/// ```swift
/// SQLDiagnostics.handler = { logger.warning("\($0)") }
/// ```
///
/// Safe to reassign at any time, including while queries are running.
public enum SQLDiagnostics {
    /// Receives one message per warning. Replace to route into your own logging.
    ///
    /// Lock-protected rather than a bare global. An earlier version was
    /// `nonisolated(unsafe)` with a comment saying "assign once at start-up",
    /// on the reasoning that a diagnostic sink should not pay for
    /// synchronisation. That reasoning was wrong twice over: a closure is two
    /// words, so a concurrent read during reassignment retains a garbage
    /// context pointer and corrupts the heap — and the very first test written
    /// against this swapped the handler while other suites were running. The
    /// crash landed in unrelated code, several test files away, which is
    /// exactly why the trade was not worth making.
    public static var handler: @Sendable (String) -> Void {
        get { storage.get() }
        set { storage.set(newValue) }
    }

    /// Writes to file descriptor 2 rather than to `stderr`.
    ///
    /// `stderr` is a **global `var`** in glibc, so Swift 6 strict concurrency
    /// refuses to let a `@Sendable` closure touch it: *"reference to var 'stderr'
    /// is not concurrency-safe because it involves shared mutable state"*. Darwin
    /// imports the same symbol in a form that does not trip the check and musl
    /// likewise, so this compiled on macOS and on the static-musl cross-build and
    /// failed only on Linux glibc — which nothing had built in a long time.
    ///
    /// The file descriptor is what `stderr` wraps, so writing to it directly is
    /// the same destination with no global in the way, and no `fflush` because
    /// descriptor writes are not buffered.
    private static let storage = HandlerBox { message in
        var line = "[swizzle] \(message)\n"
        line.withUTF8 { buffer in
            guard var base = buffer.baseAddress.map({ UnsafeRawPointer($0) }) else { return }
            var remaining = buffer.count
            // A short write is legal on a pipe, and a diagnostic that silently
            // loses its second half is worse than no diagnostic.
            while remaining > 0 {
                let written = write(STDERR_FILENO, base, remaining)
                guard written > 0 else { return }
                base += written
                remaining -= written
            }
        }
    }

    /// A mutex-protected closure.
    ///
    /// `Synchronization.Mutex` would do this and needs macOS 15; Swizzle targets
    /// macOS 14, so it is a pthread mutex.
    private final class HandlerBox: @unchecked Sendable {
        private var value: @Sendable (String) -> Void
        private let lock: UnsafeMutablePointer<pthread_mutex_t>

        init(_ value: @escaping @Sendable (String) -> Void) {
            self.value = value
            lock = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
            lock.initialize(to: pthread_mutex_t())
            pthread_mutex_init(lock, nil)
        }

        func get() -> @Sendable (String) -> Void {
            pthread_mutex_lock(lock)
            defer { pthread_mutex_unlock(lock) }
            return value
        }

        func set(_ newValue: @escaping @Sendable (String) -> Void) {
            pthread_mutex_lock(lock)
            defer { pthread_mutex_unlock(lock) }
            value = newValue
        }
    }

    /// Silences warnings. Useful in tests that deliberately exercise the path.
    public static func silence() { handler = { _ in } }

    static func warn(_ message: @autoclosure () -> String) {
        handler(message())
    }

    /// Called by `UPDATE`/`DELETE` when they run with no `WHERE` clause.
    ///
    /// Reports the row count as well as the table, because the count is what
    /// tells you whether this was the intended full-table write or the one you
    /// are about to have a bad afternoon over.
    public static func unfilteredWrite(_ verb: String, table: String, rowsAffected: Int) {
        warn("\(verb) on \(table) had no WHERE clause and changed \(rowsAffected) row\(rowsAffected == 1 ? "" : "s")")
    }
}
