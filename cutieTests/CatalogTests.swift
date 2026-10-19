import AppKit
import Testing
@testable import cutie

struct CatalogTests {
    let withFFmpeg = Toolbox(ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"), ffprobe: URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"))
    let url = { (name: String) in URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func imagesSkipTheirOwnFormat() {
        let formats = Catalog.conversions(for: [url("a.jpeg")], toolbox: .none)
        #expect(!formats.contains(.jpg))
        #expect(formats.contains(.png))
        #expect(!formats.contains(.webp)) // needs cwebp
    }

    @Test func ffmpegUnlocksFormats() {
        #expect(Catalog.conversions(for: [url("a.wav")], toolbox: .none) == [.m4a, .flac, .aiff])
        #expect(Catalog.conversions(for: [url("a.wav")], toolbox: withFFmpeg).contains(.mp3))
        #expect(Catalog.conversions(for: [url("a.mkv")], toolbox: .none).isEmpty)
        #expect(Catalog.conversions(for: [url("a.mkv")], toolbox: withFFmpeg).first == .mp4)
    }

    @Test func iWorkFormatsNeedTheApps() {
        #expect(!Catalog.conversions(for: [url("a.docx")], toolbox: .none).contains(.pages))
        #expect(Catalog.conversions(for: [url("a.pptx")], toolbox: .none).isEmpty)
        let keynote = Toolbox(keynote: URL(fileURLWithPath: "/Applications/Keynote.app"))
        #expect(Catalog.conversions(for: [url("a.pptx")], toolbox: keynote) == [.pdf, .key, .jpg, .png])
    }

    @Test func mixedFilesGetArchives() {
        #expect(Catalog.conversions(for: [url("a.png"), url("b.pdf")], toolbox: .none) == [.zip, .tar, .gzip])
    }

    @Test func toolsDependOnTheFiles() {
        let one = Catalog.tools(for: [url("a.png")], toolbox: .none)
        #expect(!one.contains(.combineToPDF))
        #expect(!one.contains(.compressImage)) // PNG is lossless
        #expect(Catalog.tools(for: [url("a.png"), url("b.png")], toolbox: .none).contains(.combineToPDF))
        #expect(Catalog.tools(for: [url("a.jpg")], toolbox: .none).first == .compressImage)
        #expect(Catalog.tools(for: [url("a.zip")], toolbox: .none) == [.extract, .checksum])
        #expect(Catalog.tools(for: [url("a.mp4")], toolbox: .none).contains(.trimMedia))
        #expect(!Catalog.tools(for: [url("a.mp4"), url("b.mp4")], toolbox: .none).contains(.trimMedia))
    }

    @Test func everyWheelHasSomething() {
        for name in ["a.png", "a.mp4", "a.wav", "a.pdf", "a.docx", "a.epub", "a.csv", "a.srt", "a.zip", "a.xyz"] {
            for wheel in Wheel.allCases {
                #expect(!Catalog.items(for: [url(name)], wheel: wheel, toolbox: withFFmpeg).isEmpty, "\(name) \(wheel)")
            }
        }
    }

    @Test func everySymbolExists() {
        let symbols = Format.allCases.map(\.symbol) + Tool.allCases.map(\.symbol) + FileAction.allCases.map(\.symbol)
        for symbol in Set(symbols) {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func compoundExtensions() {
        #expect(FileKind.fileExtension(of: url("trip.tar.gz")) == "tar.gz")
        #expect(FileKind.of(url("trip.tar.gz")) == .archive)
        #expect(Output.split("trip.tar.gz") == ("trip", "tar.gz"))
        #expect(Output.split("README") == ("README", ""))
        #expect(Output.baseName(of: url("photo.final.png")) == "photo.final")
    }

    @Test func triggerKeysMapToWheels() {
        let defaults = UserDefaults(suiteName: "CatalogTests-\(UUID().uuidString)")!
        #expect(Preferences.wheel(forPressed: .shift, in: defaults) == .convert)
        #expect(Preferences.wheel(forPressed: .command, in: defaults) == .tools)
        #expect(Preferences.wheel(forPressed: .control, in: defaults) == .actions)
        #expect(Preferences.wheel(forPressed: .option, in: defaults) == nil)
        defaults.set(TriggerKey.option.rawValue, forKey: Preferences.Key.toolsKey)
        #expect(Preferences.wheel(forPressed: .option, in: defaults) == .tools)
    }
}
