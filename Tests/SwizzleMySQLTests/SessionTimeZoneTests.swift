import Foundation
import Testing
@testable import SwizzleMySQL

/// The session time zone, and the two places its sign is decided.
///
/// ## The bug this suite was written for
///
/// A `MySQLSessionTimeZone.offset` is stated as an hours/minutes pair, and two
/// separate pieces of code turn that pair back into a signed quantity:
/// `settingValue` builds the string for `SET time_zone`, and `offsetFromUTC`
/// produces the seconds `MySQLDateTime.date(in:)` converts with.
///
/// They disagreed. `settingValue` treated the offset as negative when **either**
/// component was, which is right — `offset(hours: -3, minutes: 30)` is
/// `-03:30`, not minus three hours plus thirty minutes. `offsetFromUTC` looked
/// only at the hours, so `offset(hours: 0, minutes: -30)` sent `-00:30` to the
/// server and then converted every `TIMESTAMP` as **+00:30** — an hour apart,
/// silently, with the session correctly configured the whole time.
///
/// Zero is the only hours value where the two rules differ, which is why no
/// test caught it: every realistic zone has a non-zero hour.
///
/// ## Why this is a class rather than an instance
///
/// Any time one value is rendered by two different pieces of code, the
/// interesting test is that they agree — not that either matches an expected
/// string. So the property here is stated over the whole space of offsets
/// rather than over examples.
@Suite("MySQL session time zone")
struct SessionTimeZoneTests {

    /// Every offset MySQL accepts, at every combination of signs.
    ///
    /// The range is `-13:59` to `+14:00`, which is wider than the set of real
    /// zones — MySQL validates the format, not the geography.
    static var allOffsets: [(Int, Int)] {
        var out: [(Int, Int)] = []
        for hours in [-14, -13, -5, -3, -1, 0, 1, 3, 5, 13, 14] {
            for minutes in [-45, -30, -1, 0, 1, 15, 30, 45] {
                out.append((hours, minutes))
            }
        }
        return out
    }

    /// **The property the bug violated.** The string the driver sends and the
    /// seconds it converts with must describe the same offset — for every pair,
    /// not for the ones anybody thought to write down.
    @Test("the offset string and the offset in seconds always agree")
    func stringAndSecondsAgree() throws {
        for (hours, minutes) in Self.allOffsets {
            let zone = MySQLSessionTimeZone.offset(hours: hours, minutes: minutes)
            let text = try #require(zone.settingValue)
            let seconds = try #require(zone.offsetFromUTC)

            // Re-read the string the server would receive, independently of how
            // it was built: sign, then hours, then minutes.
            let negative = text.hasPrefix("-")
            let parts = text.dropFirst().split(separator: ":")
            let parsed = (Int(parts[0])! * 3600 + Int(parts[1])! * 60) * (negative ? -1 : 1)

            #expect(
                Int(seconds) == parsed,
                """
                offset(hours: \(hours), minutes: \(minutes)) sends "\(text)" \
                but converts by \(Int(seconds)) seconds
                """
            )
        }
    }

    /// The exact case that was wrong, named so a regression is recognisable.
    @Test("an offset with zero hours and negative minutes is negative in both")
    func zeroHoursNegativeMinutes() throws {
        let zone = MySQLSessionTimeZone.offset(hours: 0, minutes: -30)
        #expect(zone.settingValue == "-00:30")
        #expect(zone.offsetFromUTC == -1800, "the setting says minus; so must the conversion")
    }

    /// And its mirror, so the fix did not simply invert the sign.
    @Test("an offset with zero hours and positive minutes is positive in both")
    func zeroHoursPositiveMinutes() throws {
        let zone = MySQLSessionTimeZone.offset(hours: 0, minutes: 30)
        #expect(zone.settingValue == "+00:30")
        #expect(zone.offsetFromUTC == 1800)
    }

    /// The real half-hour and three-quarter-hour zones, which are the ones a
    /// user is actually likely to configure.
    @Test("the real fractional-hour zones render and convert correctly")
    func realFractionalZones() {
        let cases: [(Int, Int, String, TimeInterval)] = [
            (5, 30, "+05:30", 19_800),        // India
            (5, 45, "+05:45", 20_700),        // Nepal
            (-3, 30, "-03:30", -12_600),      // Newfoundland
            (9, 30, "+09:30", 34_200),        // South Australia
            (-9, 30, "-09:30", -34_200),      // Marquesas
            (14, 0, "+14:00", 50_400),        // Kiritimati, the eastern extreme
            (-12, 0, "-12:00", -43_200),
        ]
        for (hours, minutes, text, seconds) in cases {
            let zone = MySQLSessionTimeZone.offset(hours: hours, minutes: minutes)
            #expect(zone.settingValue == text, "offset(\(hours), \(minutes))")
            #expect(zone.offsetFromUTC == seconds, "offset(\(hours), \(minutes))")
        }
    }

    /// A pair where **both** components are negative means the same thing as
    /// one — it is one offset stated twice, not a sum.
    @Test("both components negative is the same offset as one")
    func bothNegative() {
        #expect(
            MySQLSessionTimeZone.offset(hours: -3, minutes: -30).offsetFromUTC
                == MySQLSessionTimeZone.offset(hours: -3, minutes: 30).offsetFromUTC
        )
        #expect(MySQLSessionTimeZone.offset(hours: -3, minutes: -30).settingValue == "-03:30")
    }

    @Test("UTC and the server default behave as documented")
    func utcAndServer() {
        #expect(MySQLSessionTimeZone.utc.settingValue == "+00:00")
        #expect(MySQLSessionTimeZone.utc.offsetFromUTC == 0)
        #expect(MySQLSessionTimeZone.server.settingValue == nil, "nothing is set")
        #expect(MySQLSessionTimeZone.server.offsetFromUTC == nil, "and nothing is knowable")
        #expect(
            MySQLSessionTimeZone.named("Europe/London").offsetFromUTC == nil,
            "a zone name alone does not fix an offset — it depends on the date"
        )
        #expect(MySQLSessionTimeZone.named("Europe/London").settingValue == "Europe/London")
    }

    /// Zero offsets, which have no sign to get wrong and must render positive.
    @Test("a zero offset renders as +00:00")
    func zeroOffset() {
        let zone = MySQLSessionTimeZone.offset(hours: 0, minutes: 0)
        #expect(zone.settingValue == "+00:00")
        #expect(zone.offsetFromUTC == 0)
    }

    // MARK: - Converting a wall clock

    /// `date(atOffsetFromUTC:)` validates the date before building it, and the
    /// bounds are where an off-by-one turns a rejection into a wrong `Date`.
    @Test("the month and day bounds reject exactly what is out of range")
    func calendarFieldBounds() {
        func convert(month: UInt8, day: UInt8) -> Date? {
            MySQLDateTime(year: 2024, month: month, day: day, hour: 12)
                .date(atOffsetFromUTC: 0)
        }
        // Inside.
        #expect(convert(month: 1, day: 1) != nil)
        #expect(convert(month: 12, day: 31) != nil)
        #expect(convert(month: 6, day: 15) != nil)
        // Outside, at each boundary.
        #expect(convert(month: 0, day: 15) == nil, "month zero")
        #expect(convert(month: 13, day: 15) == nil, "month thirteen")
        #expect(convert(month: 6, day: 0) == nil, "day zero")
        #expect(convert(month: 6, day: 32) == nil, "day thirty-two")
        #expect(convert(month: 255, day: 255) == nil)
    }

    /// The zero date is MySQL's own, not a missing value, and it has no
    /// instant.
    @Test("the zero date has no instant")
    func zeroDateHasNoInstant() {
        #expect(MySQLDateTime().date(atOffsetFromUTC: 0) == nil)
    }

    /// The conversion applies the offset in the direction the name says: a wall
    /// clock east of UTC is an *earlier* instant.
    @Test("a wall clock is converted in the direction its offset says")
    func offsetDirection() throws {
        let noon = MySQLDateTime(year: 2024, month: 3, day: 5, hour: 12)
        let atUTC = try #require(noon.date(atOffsetFromUTC: 0))
        let eastOfUTC = try #require(noon.date(atOffsetFromUTC: 3600))
        let westOfUTC = try #require(noon.date(atOffsetFromUTC: -3600))

        #expect(
            eastOfUTC == atUTC.addingTimeInterval(-3600),
            "noon in +01:00 is 11:00 UTC, so an earlier instant"
        )
        #expect(westOfUTC == atUTC.addingTimeInterval(3600))
    }

    /// And through a `MySQLSessionTimeZone`, which is the path callers take —
    /// including the half-hour zone that was wrong.
    @Test("converting through a session zone uses that zone's offset")
    func convertThroughSessionZone() throws {
        let noon = MySQLDateTime(year: 2024, month: 3, day: 5, hour: 12)
        let utc = try #require(noon.date(in: .utc))

        #expect(
            noon.date(in: .offset(hours: 5, minutes: 30))
                == utc.addingTimeInterval(-19_800)
        )
        #expect(
            noon.date(in: .offset(hours: 0, minutes: -30))
                == utc.addingTimeInterval(1800),
            "the case that was an hour out"
        )
        #expect(noon.date(in: .server) == nil, "no offset to convert with")
        #expect(noon.date(in: .named("Asia/Kolkata")) == nil)
    }
}
