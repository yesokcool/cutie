import Foundation
import Testing
@testable import cutie

/// Failures say what happened in plain words; archives keep what makes them
/// archives and refuse what they can't open; scratch work stays on the
/// result's disk; a cancelled or failed job leaves nothing behind.
@Suite(.serialized)
struct RobustnessTests {
    // MARK: Error messages

    @Test func toolErrorsSayWhatWentWrong() {
        let ffmpeg = """
        ffmpeg version 8.0.1 Copyright (c) 2000-2025 the FFmpeg developers
          built with Apple clang version 17.0.0
          configuration: --prefix=/opt/homebrew/Cellar/ffmpeg/8.0.1
        Input #0, matroska,webm, from 'movie.mkv':
          Duration: 00:00:02.00, start: 0.000000, bitrate: 1 kb/s
          Stream #0:0: Video: h264
        [mp4 @ 0x12345] Could not find tag for codec pcm_s16le in stream #1, codec not currently supported in container
        [out#0/mp4 @ 0x6000] Could not write header (incorrect codec parameters ?): Invalid argument
        Conversion failed!
        """
        func explain(_ output: String, _ tool: String = "tar") -> String { Shell.Failure.explain(output, tool: tool, status: 1) }
        #expect(explain(ffmpeg, "ffmpeg") == "That format can't hold this file's audio or video.")
        #expect(explain("Trip/run.sh: Incorrect passphrase: Unknown error: -1\ntar: Error exit delayed from previous errors.")
                == "This file is password-protected.")
        #expect(explain("ERROR: Data Error in encrypted file. Wrong password? : Trip/a.txt\nSub items Errors: 1", "7z")
                == "This file is password-protected.")
        #expect(explain("tar: Trip/big.bin: Write failed: No space left on device") == "The disk is full.")
        #expect(explain("tar: could not chdir to '/Volumes/X': Permission denied")
                == "Cutie isn't allowed to read or write there (permission denied).")
        #expect(explain("[mov,mp4 @ 0x1] moov atom not found\nclip.mp4: Invalid data found when processing input", "ffmpeg")
                == "This file is damaged or isn't what its name says.")
        // Nothing known: the line naming the problem, not the summary or progress after it.
        #expect(explain("tar: Trip/x: Some odd problem\ntar: Error exit delayed from previous errors.") == "Trip/x: Some odd problem")
        #expect(explain("[in#0 @ 0x1] Error opening input: Something new\nframe=   10 fps=0.0 q=0.0 size=0kB", "ffmpeg")
                == "Error opening input: Something new")
        #expect(explain("", "bsdtar") == "bsdtar stopped (1).")
    }

    // MARK: Archives

    /// "Trip": a non-ASCII name, an executable script, a symlink and a 1 MB file.
    func tripFolder(_ fixtures: Fixtures) throws -> URL {
        let folder = try fixtures.folder.appending(path: "Trip").create()
        try "hello".write(to: folder.appending(path: "café ü.txt"), atomically: true, encoding: .utf8)
        let script = folder.appending(path: "run.sh")
        try "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link.txt").path, withDestinationPath: "café ü.txt")
        try Data(count: 1_000_000).write(to: folder.appending(path: "zeros.bin"))
        return folder
    }

    func extract(_ archive: URL, _ context: JobContext) async throws -> URL {
        try #require(try await Executor.run(.tool(.extract), inputs: [archive], context: context).files.first)
    }

    func message(of work: () async throws -> Void) async -> String? {
        do { try await work(); return nil } catch { return error.localizedDescription }
    }

    @Test func zipsKeepNamesLinksAndPermissions() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let trip = try tripFolder(fixtures)
        let zip = try #require(try await Executor.run(.tool(.zip), inputs: [trip], context: fixtures.context).files.first)
        let directory = try #require(ZipDirectory(zip))
        #expect(directory.entries == 5)
        #expect(directory.unpackedSize >= 1_000_000)
        #expect(!directory.encrypted && !directory.spanned)
        let listing = try await Shell.run(URL(fileURLWithPath: "/usr/bin/zipinfo"), ["-1", zip.path])
        #expect(!listing.contains("__MACOSX"))

        try FileManager.default.removeItem(at: trip)
        let out = try await extract(zip, fixtures.context)
        #expect(out.lastPathComponent == "Trip")
        let script = try FileManager.default.attributesOfItem(atPath: out.appending(path: "run.sh").path)
        #expect((script[.posixPermissions] as? Int ?? 0) & 0o111 != 0)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: out.appending(path: "link.txt").path) == "café ü.txt")
        #expect(try String(contentsOf: out.appending(path: "café ü.txt"), encoding: .utf8) == "hello")
    }

    @Test func macZipsKeepFinderTags() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let trip = try tripFolder(fixtures)
        let tags = Data(#"("Red\n6")"#.utf8)
        ArchiveConverter.setExtendedAttribute("com.apple.metadata:_kMDItemUserTags", tags, on: trip.appending(path: "café ü.txt"))
        let zip = fixtures.url("Trip.zip")
        // What Finder's Compress makes: tags ride along in __MACOSX.
        try await Shell.run(Shell.ditto, ["-c", "-k", "--sequesterRsrc", "--keepParent", trip.path, zip.path])
        try FileManager.default.removeItem(at: trip)
        let out = try await extract(zip, fixtures.context)
        #expect(ArchiveConverter.extendedAttribute("com.apple.metadata:_kMDItemUserTags", of: out.appending(path: "café ü.txt")) == tags)
        #expect(!FileManager.default.fileExists(atPath: fixtures.url("__MACOSX").path))
    }

    @Test func passwordProtectedArchivesSaySo() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        _ = try tripFolder(fixtures)
        let zip = fixtures.url("secret.zip")
        try await Shell.run(Shell.zip, ["-q", "-r", "-P", "secret", zip.path, "Trip"], in: fixtures.folder)
        #expect(ZipDirectory(zip)?.encrypted == true)
        let zipMessage = await message { _ = try await extract(zip, fixtures.context) }
        #expect(zipMessage == "This archive is password-protected.")

        guard let sevenZip = Toolbox.detect().sevenZip else { return }
        let sevenZ = fixtures.url("secret.7z")
        try await Shell.run(sevenZip, ["a", "-bd", "-psecret", sevenZ.path, "Trip"], in: fixtures.folder)
        // bsdtar ("content is encrypted, but currently not supported") and 7-Zip ("Wrong password?").
        for context in [fixtures.context, fixtures.fullContext] {
            let sevenMessage = await message { _ = try await extract(sevenZ, context) }
            #expect(sevenMessage == "This file is password-protected.")
        }
    }

    @Test func splitArchivesNeed7Zip() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        guard let sevenZip = Toolbox.detect().sevenZip else { return }
        let trip = try tripFolder(fixtures)
        try Data((0..<600_000).map { _ in UInt8.random(in: 0...255) }).write(to: trip.appending(path: "noise.bin"))
        try await Shell.run(sevenZip, ["a", "-bd", "-v200k", fixtures.url("parts.7z").path, "Trip"], in: fixtures.folder)
        let first = fixtures.url("parts.7z.001")
        #expect(FileKind.of(first) == .archive)
        #expect(ArchiveConverter.isSplit(first))
        #expect(Catalog.tools(for: [first], toolbox: .none).contains(.extract))
        let missing = await message { _ = try await extract(first, fixtures.context) }
        #expect(missing?.contains("7-Zip") == true)

        try FileManager.default.removeItem(at: trip)
        let out = try await extract(first, fixtures.fullContext)
        #expect(FileManager.default.fileExists(atPath: out.appending(path: "noise.bin").path))
    }

    @Test func quarantineCarriesOver() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let trip = try tripFolder(fixtures)
        let zip = try #require(try await Executor.run(.tool(.zip), inputs: [trip], context: fixtures.context).files.first)
        try FileManager.default.removeItem(at: trip)
        let mark = Data("0081;6720e1a0;Safari;".utf8)
        ArchiveConverter.setExtendedAttribute(ArchiveConverter.quarantine, mark, on: zip)

        let out = try await extract(zip, fixtures.context)
        #expect(ArchiveConverter.extendedAttribute(ArchiveConverter.quarantine, of: out.appending(path: "run.sh")) == mark)
        let tar = try #require(try await Executor.run(.convert(.tar), inputs: [zip], context: fixtures.context).files.first)
        #expect(ArchiveConverter.extendedAttribute(ArchiveConverter.quarantine, of: tar) == mark)
    }

    // MARK: Disks and space

    /// A small disk image, mounted out of Finder's sight, standing in for an external drive.
    struct Disk {
        let image: URL
        let mount: URL

        init(in folder: URL, megabytes: Int) async throws {
            image = folder.appending(path: "disk.dmg")
            mount = try folder.appending(path: "mnt").create()
            let hdiutil = URL(fileURLWithPath: "/usr/bin/hdiutil")
            try await Shell.run(hdiutil, ["create", "-quiet", "-size", "\(megabytes)m", "-fs", "HFS+", "-volname", "CutieTest", image.path])
            try await Shell.run(hdiutil, ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path])
        }

        func detach() async {
            _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), ["detach", "-quiet", "-force", mount.path])
        }
    }

    @Test func workStaysOnTheResultsDisk() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let disk = try await Disk(in: fixtures.folder, megabytes: 40)
        do {
            let scratch = try Scratch(near: disk.mount)
            #expect(Output.sameVolume(scratch.url, disk.mount))
            #expect(!Output.sameVolume(scratch.url, FileManager.default.temporaryDirectory))
            scratch.remove()

            // A conversion on the external disk: the result lands beside it, nothing else is left there.
            let photo = disk.mount.appending(path: "photo.png")
            try FileManager.default.copyItem(at: try fixtures.png(), to: photo)
            let jpg = try #require(try await Executor.run(.convert(.jpg), inputs: [photo], context: fixtures.context).files.first)
            #expect(jpg.deletingLastPathComponent().standardizedFileURL == disk.mount.standardizedFileURL)
            let visible = try FileManager.default.contentsOfDirectory(atPath: disk.mount.path).filter { !$0.hasPrefix(".") }
            #expect(Set(visible) == ["photo.png", "photo.jpg"])

            // Placing across disks goes through a hidden name and leaves nothing extra.
            let loose = fixtures.url("loose.txt")
            try "x".write(to: loose, atomically: true, encoding: .utf8)
            let placed = try fixtures.context.output.place(loose, named: "loose.txt", beside: photo)
            #expect(FileManager.default.fileExists(atPath: placed.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: disk.mount.path).allSatisfy { !$0.hasPrefix(".cutie-") })

            // An archive that unpacks bigger than the disk is refused up front.
            let big = try fixtures.folder.appending(path: "Big").create()
            try Data(count: 80_000_000).write(to: big.appending(path: "zeros.bin"))
            let zip = try #require(try await Executor.run(.tool(.zip), inputs: [big], context: fixtures.context).files.first)
            let onDisk = disk.mount.appending(path: "Big.zip")
            try FileManager.default.copyItem(at: zip, to: onDisk)
            let full = await message { _ = try await extract(onDisk, fixtures.context) }
            #expect(full?.hasPrefix("Not enough space on “CutieTest”") == true)
            #expect(!FileManager.default.fileExists(atPath: disk.mount.appending(path: "Big").path))
        } catch {
            await disk.detach()
            throw error
        }
        await disk.detach()
    }

    // MARK: Partial results

    @Test func cancellingTakesBackPlacedResults() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let inputs = try ["a.png", "b.png", "c.png"].map { try fixtures.png($0) }
        var context = fixtures.context
        // Cancel the job's own task as soon as the first file is done.
        context.progress = { value in if value >= 0.3 { withUnsafeCurrentTask { $0?.cancel() } } }
        let job = Task { try await Executor.run(.convert(.tiff), inputs: inputs, context: context) }
        let result = await job.result
        #expect(throws: CancellationError.self) { try result.get() }
        for name in ["a.tiff", "b.tiff", "c.tiff"] {
            #expect(!FileManager.default.fileExists(atPath: fixtures.url(name).path), "\(name)")
        }
    }

    @Test func batchesSayWhichFilesFailed() async throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let inputs = [try fixtures.png("a.png"), try fixtures.truncatedJPEG(), try fixtures.png("c.png")]
        let outcome = try await Executor.run(.convert(.tiff), inputs: inputs, context: fixtures.context)
        #expect(outcome.files.map(\.lastPathComponent) == ["a.tiff", "c.tiff"])
        #expect(outcome.failures.count == 1)
        #expect(outcome.failures.first?.hasPrefix("broken.jpg: ") == true)
        #expect(!FileManager.default.fileExists(atPath: fixtures.url("broken.tiff").path))
    }

    @Test func placingNeverOverwrites() throws {
        let fixtures = try Fixtures(); defer { fixtures.remove() }
        let input = fixtures.url("notes.md")
        try "original".write(to: fixtures.url("notes.txt"), atomically: true, encoding: .utf8)
        let scratch = try Scratch(near: fixtures.folder); defer { scratch.remove() }
        let made = scratch.file("notes.txt")
        try "new".write(to: made, atomically: true, encoding: .utf8)
        let placed = try fixtures.context.output.place(made, named: "notes.txt", beside: input)
        #expect(placed.lastPathComponent == "notes 2.txt")
        #expect(try String(contentsOf: fixtures.url("notes.txt"), encoding: .utf8) == "original")
    }
}
