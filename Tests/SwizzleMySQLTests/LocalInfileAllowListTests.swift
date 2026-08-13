import Foundation
import SwizzleMySQL
import Testing

/// The `LOCAL INFILE` allow-list.
///
/// ## Why this had to be tested rather than assumed
///
/// This function decides whether the **server** may make the client read a file
/// off its own disk. The request arrives unsolicited — the client never asked for
/// a file to be sent — so a malicious or compromised server names a path and a
/// client that says yes hands it over. `permits` is the whole defence, and a
/// public-API sweep found nothing calling it.
///
/// It is also the exact shape of check that fails quietly: an allow-list that
/// accidentally says yes looks identical to one that works, right up until it
/// doesn't.
@Suite("MySQL LOCAL INFILE allow-list")
struct LocalInfileAllowListTests {

    typealias LocalInfile = MySQLConnectionConfiguration.LocalInfile

    /// Off by default is the security-relevant default, and `disabled` must
    /// refuse everything — including paths a caller might expect to be innocuous.
    @Test("disabled permits nothing at all")
    func disabledPermitsNothing() {
        let mode = LocalInfile.disabled
        #expect(!mode.permits("/tmp/data.csv"))
        #expect(!mode.permits("/etc/passwd"))
        #expect(!mode.permits(""))
        #expect(!mode.isEnabled)
    }

    @Test("an allow-list permits exactly what it names")
    func allowsListedPaths() {
        let mode = LocalInfile.allowList(["/tmp/data.csv", "/tmp/other.csv"])
        #expect(mode.permits("/tmp/data.csv"))
        #expect(mode.permits("/tmp/other.csv"))
        #expect(mode.isEnabled)
    }

    /// **The attack the standardisation exists for.** Matching the raw string
    /// would let a server name the same file under a spelling the list does not
    /// contain, and every one of these resolves to a permitted path.
    @Test("the same file under a different spelling is still permitted")
    func equivalentSpellingsMatch() {
        let mode = LocalInfile.allowList(["/tmp/data.csv"])
        #expect(mode.permits("/tmp/./data.csv"))
        #expect(mode.permits("/tmp/x/../data.csv"))
        #expect(mode.permits("/tmp//data.csv"))
    }

    /// And the same trick pointed the other way: traversal must not escape the
    /// list. `/tmp/../etc/passwd` is `/etc/passwd`, which was never permitted.
    @Test("traversal cannot reach a path that was not listed")
    func traversalCannotEscape() {
        let mode = LocalInfile.allowList(["/tmp/data.csv"])
        #expect(!mode.permits("/tmp/../etc/passwd"))
        #expect(!mode.permits("/etc/passwd"))
        #expect(!mode.permits("/tmp/data.csv.bak"))
        #expect(!mode.permits("/tmp/data.cs"))
        // A directory prefix is not a permission: listing a file must not permit
        // its siblings or anything below it.
        #expect(!mode.permits("/tmp"))
        #expect(!mode.permits("/tmp/data.csv/../secrets"))
    }

    /// Standardisation is applied to **both** sides, so a list written with an
    /// unclean path still matches the clean request the server sends.
    @Test("an allow-list entry written untidily still works")
    func untidyListEntry() {
        let mode = LocalInfile.allowList(["/tmp/./sub/../data.csv"])
        #expect(mode.permits("/tmp/data.csv"))
        #expect(mode.permits("/tmp/./data.csv"))
    }

    /// An empty list is a list that permits nothing — not a list that permits
    /// everything, which is how allow-lists usually go wrong.
    @Test("an empty allow-list permits nothing")
    func emptyList() {
        let mode = LocalInfile.allowList([])
        #expect(!mode.permits("/tmp/data.csv"))
        // Still "enabled", because the capability is advertised to the server;
        // the list is what refuses. Worth pinning: the two are separate.
        #expect(mode.isEnabled)
    }

    /// **Symlinks are deliberately not resolved**, and that is the security-
    /// relevant direction: resolving them would let a permitted path be
    /// repointed at an arbitrary file after the list was written.
    ///
    /// So a symlink at a permitted path is permitted *as that path*, and the real
    /// file behind it is not separately permitted.
    @Test("a symlink is judged by its own path, not its target")
    func symlinksAreNotResolved() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swizzle-infile-\(UInt32.random(in: 0..<UInt32.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = directory.appendingPathComponent("real.csv")
        let link = directory.appendingPathComponent("link.csv")
        try Data("x".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let mode = LocalInfile.allowList([link.path])
        #expect(mode.permits(link.path))
        // The target is a different path, and permitting the link did not permit
        // it. If symlinks were resolved these would be the same entry.
        #expect(!mode.permits(target.path))
    }
}
