import Foundation
import NIOCore

/// The session time zone, which decides what a `TIMESTAMP` column means.
///
/// MySQL has exactly one timezone-aware temporal type, and it is not obvious
/// which. `DATETIME` is a **wall clock with no zone** — what you stored is what
/// you read, forever. `TIMESTAMP` is an **instant**: the server converts it from
/// the session's `time_zone` on write and back to it on read.
///
/// Measured against a live server, one row written at `+00:00`:
///
/// | session `time_zone` | `TIMESTAMP` reads back | `DATETIME` reads back |
/// |---|---|---|
/// | `+00:00` | 12:00:00 | 12:00:00 |
/// | `+05:30` | **17:30:00** | 12:00:00 |
/// | `-08:00` | **04:00:00** | 12:00:00 |
///
/// The wire format is *identical* for both — a broken-down local wall clock with
/// no zone attached. Only the column type byte distinguishes them (7 for
/// `TIMESTAMP`, 12 for `DATETIME`). So a `TIMESTAMP` value on its own is
/// meaningless: it is a wall clock in a zone the value does not name, and you
/// cannot turn it into an instant without knowing which zone the session was in.
///
/// This is why the setting exists. Pinning the session zone makes every
/// `TIMESTAMP` the driver reads unambiguous, and lets
/// ``MySQLDateTime/date(in:)`` convert one to a `Foundation.Date`.
///
/// ## Against the references
///
/// go-sql-driver splits this into **two** settings that must agree: `loc`
/// attaches a `time.Location` to the naive value the driver received, while the
/// actual server-side conversion is controlled separately by passing `time_zone`
/// as a DSN system variable. Its own README warns that `loc` *"does not change
/// MySQL's time_zone setting"*. Set one without the other and every instant is
/// silently wrong by the offset between them.
///
/// `mysql_async` has no timezone handling at all — values arrive as
/// `Value::Date(y, m, d, …)`, a naive wall clock, and what zone it is in is the
/// caller's problem.
///
/// One setting here, applied to the server, and remembered by the connection.
public enum MySQLSessionTimeZone: Sendable, Equatable {
    /// Leave `time_zone` alone and inherit whatever the server defaults to.
    ///
    /// The default, because changing it also moves `NOW()`, `CURDATE()` and
    /// every `TIMESTAMP` a session reads or writes — not something to do to an
    /// existing deployment without being asked.
    ///
    /// The cost is that `TIMESTAMP` values cannot be converted to an instant:
    /// the zone is whatever `@@session.time_zone` happens to be, which for a
    /// pooled connection is the server's local zone and may not even be stable
    /// across a DST boundary. If you read `TIMESTAMP` columns, prefer ``utc``.
    case server

    /// `SET time_zone = '+00:00'`.
    ///
    /// The recommended setting, and the only one that is unambiguous everywhere:
    /// it needs no timezone tables on the server, never shifts under DST, and
    /// makes every `TIMESTAMP` the driver sees a UTC wall clock.
    case utc

    /// A fixed offset from UTC.
    ///
    /// Always available — MySQL accepts numeric offsets without any timezone
    /// tables loaded. Note that a *fixed* offset does not observe DST, so this
    /// is right for `+05:30` and wrong for "Europe/London".
    case offset(hours: Int, minutes: Int = 0)

    /// A named zone such as `Europe/London`.
    ///
    /// **Requires the server's timezone tables to be populated** — MySQL ships
    /// them empty and they are loaded with `mysql_tzinfo_to_sql`. On a server
    /// without them the `SET` fails, and the connection fails with it rather
    /// than silently continuing in the wrong zone.
    case named(String)

    /// The value for `SET time_zone`, or nil when nothing should be set.
    var settingValue: String? {
        switch self {
        case .server:
            return nil
        case .utc:
            return "+00:00"
        case .offset(let hours, let minutes):
            let sign = (hours < 0 || minutes < 0) ? "-" : "+"
            return String(
                format: "%@%02d:%02d", sign, abs(hours), abs(minutes)
            )
        case .named(let name):
            return name
        }
    }

    /// Seconds east of UTC, when that is knowable from the setting alone.
    ///
    /// `nil` for ``server`` and ``named``: the first is unknown by definition,
    /// and the second depends on the date, which a zone name alone does not fix.
    /// ``MySQLDateTime/date(in:)`` needs this, which is why it can only convert
    /// for ``utc`` and ``offset(hours:minutes:)``.
    public var offsetFromUTC: TimeInterval? {
        switch self {
        case .server, .named: return nil
        case .utc: return 0
        case .offset(let hours, let minutes):
            // The sign rule has to be *the same one* `settingValue` uses, or
            // the driver tells the server one offset and converts by another.
            // It did: with `hours` zero and `minutes` negative — a legal offset
            // MySQL accepts — the statement said `-00:30` while this returned
            // +1800, so every TIMESTAMP came back an hour the wrong side of
            // where the session had been set.
            //
            // Deriving both from "is either component negative" keeps them in
            // step. Every other combination is unchanged.
            let isNegative = hours < 0 || minutes < 0
            let magnitude = abs(hours) * 3600 + abs(minutes) * 60
            return TimeInterval(isNegative ? -magnitude : magnitude)
        }
    }

    /// The statement that applies this, or nil for ``server``.
    ///
    /// Quoted as a literal, and the only values that reach it are either
    /// generated here or a zone name — which is validated below, because it is
    /// the one case that comes from the caller.
    func setupStatement() throws -> String? {
        guard let value = settingValue else { return nil }
        if case .named(let name) = self {
            // A zone name is an identifier-like token; anything that could
            // terminate the literal is rejected rather than escaped, because a
            // legitimate zone name never contains one.
            guard !name.isEmpty,
                  !name.contains("'"), !name.contains("\\"), !name.contains(";")
            else {
                throw MySQLProtocolError.unexpectedPacket(
                    "invalid time zone name '\(name)'"
                )
            }
        }
        return "SET time_zone = '\(value)'"
    }
}

// MARK: - Converting a wall clock to an instant

extension MySQLDateTime {

    /// Interprets this wall clock in `timeZone` and returns the instant it names.
    ///
    /// Returns `nil` when the conversion is not well defined:
    ///
    /// - the zone's offset is not knowable (``MySQLSessionTimeZone/server`` or
    ///   ``MySQLSessionTimeZone/named(_:)``), or
    /// - the value is not a real point in time — MySQL permits `0000-00-00` and
    ///   zero months and days, which `Date` cannot represent. That is exactly
    ///   why ``MySQLDateTime`` exists rather than decoding straight to `Date`.
    ///
    /// Only meaningful for a `TIMESTAMP` column. A `DATETIME` has no zone at
    /// all, so converting one is asserting a zone the database never recorded —
    /// legitimate if your application has a convention, but it is your
    /// convention and not the server's.
    public func date(in timeZone: MySQLSessionTimeZone) -> Date? {
        guard let offset = timeZone.offsetFromUTC else { return nil }
        return date(atOffsetFromUTC: offset)
    }

    /// Interprets this wall clock at a fixed offset east of UTC.
    public func date(atOffsetFromUTC offset: TimeInterval) -> Date? {
        guard !isZero, month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        var components = DateComponents()
        components.year = Int(year)
        components.month = Int(month)
        components.day = Int(day)
        components.hour = Int(hour)
        components.minute = Int(minute)
        components.second = Int(second)

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        calendar.timeZone = utc

        guard let base = calendar.date(from: components) else { return nil }
        // Microseconds are added separately: DateComponents carries nanoseconds,
        // and routing them through the calendar risks rounding.
        return base
            .addingTimeInterval(-offset)
            .addingTimeInterval(Double(microsecond) / 1_000_000)
    }
}

extension MySQLColumnDefinition {
    /// Whether this column's values are converted by the session time zone.
    ///
    /// True only for `TIMESTAMP`. The value on the wire looks exactly like a
    /// `DATETIME`, so this is the only way to know that what you are holding is
    /// an instant rendered into the session's zone rather than a plain wall
    /// clock — and therefore the only way to know that converting it with
    /// ``MySQLDateTime/date(in:)`` is meaningful.
    public var isTimeZoneAware: Bool {
        switch MySQLColumnType(rawValueOrUnknown: type) {
        case .timestamp, .timestamp2: true
        default: false
        }
    }
}
