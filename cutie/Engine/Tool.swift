import Foundation

/// The Tools wheel: things you do to a file that keep (mostly) its format.
nonisolated enum Tool: String, CaseIterable, Sendable, Hashable {
    // Images
    case compressImage, resizeImage, rotateImage, flipImage, grayscale, cropSquare
    case removeBackground, extractText, stripMetadata, combineToPDF
    // PDF
    case compressPDF, splitPDF, mergePDFs, rotatePDF
    // Video & audio
    case compressVideo, trimMedia, muteVideo, extractAudio, rotateVideo, resizeVideo, snapshot
    case compressAudio, mergeAudio, normalizeAudio
    // Text
    case wordCount
    // Any file
    case zip, extract, checksum

    var title: String {
        switch self {
        case .compressImage, .compressPDF, .compressVideo, .compressAudio: "Compress"
        case .resizeImage: "Half Size"
        case .rotateImage, .rotatePDF, .rotateVideo: "Rotate"
        case .flipImage: "Flip"
        case .grayscale: "Black & White"
        case .cropSquare: "Square"
        case .removeBackground: "Remove Background"
        case .extractText: "Get Text"
        case .stripMetadata: "Remove Metadata"
        case .combineToPDF: "Combine to PDF"
        case .splitPDF: "Split Pages"
        case .mergePDFs, .mergeAudio: "Merge"
        case .trimMedia: "Trim"
        case .muteVideo: "Mute"
        case .extractAudio: "Get Audio"
        case .resizeVideo: "720p"
        case .snapshot: "Snapshot"
        case .normalizeAudio: "Even Volume"
        case .wordCount: "Word Count"
        case .zip: "Zip"
        case .extract: "Extract"
        case .checksum: "Checksum"
        }
    }

    var symbol: String {
        switch self {
        case .compressImage, .compressPDF, .compressVideo, .compressAudio: "arrow.down.right.and.arrow.up.left"
        case .resizeImage, .resizeVideo: "aspectratio"
        case .rotateImage, .rotatePDF, .rotateVideo: "rotate.right"
        case .flipImage: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .grayscale: "circle.lefthalf.filled"
        case .cropSquare: "crop"
        case .removeBackground: "person.crop.rectangle"
        case .extractText: "text.viewfinder"
        case .stripMetadata: "eye.slash"
        case .combineToPDF, .mergePDFs: "doc.on.doc"
        case .splitPDF: "square.split.2x1"
        case .trimMedia: "timeline.selection"
        case .muteVideo: "speaker.slash"
        case .extractAudio: "waveform"
        case .snapshot: "camera"
        case .mergeAudio: "link"
        case .normalizeAudio: "speaker.wave.3"
        case .wordCount: "number"
        case .zip: "archivebox"
        case .extract: "tray.and.arrow.up"
        case .checksum: "checkmark.seal"
        }
    }

    /// Present tense for the progress pill ("Compressing…").
    var progressTitle: String {
        switch self {
        case .compressImage, .compressPDF, .compressVideo, .compressAudio: "Compressing"
        case .resizeImage, .resizeVideo: "Resizing"
        case .rotateImage, .rotatePDF, .rotateVideo: "Rotating"
        case .flipImage: "Flipping"
        case .grayscale: "Removing color"
        case .cropSquare: "Cropping"
        case .removeBackground: "Removing the background"
        case .extractText: "Reading text"
        case .stripMetadata: "Removing metadata"
        case .combineToPDF: "Combining"
        case .splitPDF: "Splitting"
        case .mergePDFs, .mergeAudio: "Merging"
        case .trimMedia: "Trimming"
        case .muteVideo: "Muting"
        case .extractAudio: "Getting the audio"
        case .snapshot: "Taking a snapshot"
        case .normalizeAudio: "Evening the volume"
        case .wordCount: "Counting"
        case .zip: "Zipping"
        case .extract: "Extracting"
        case .checksum: "Checking"
        }
    }

    /// The suffix added to the output's name ("photo compressed.jpg").
    var suffix: String {
        switch self {
        case .compressImage, .compressPDF, .compressVideo, .compressAudio: " compressed"
        case .resizeImage: " half"
        case .rotateImage, .rotatePDF, .rotateVideo: " rotated"
        case .flipImage: " flipped"
        case .grayscale: " bw"
        case .cropSquare: " square"
        case .removeBackground: " cutout"
        case .stripMetadata: " clean"
        case .trimMedia: " trimmed"
        case .muteVideo: " muted"
        case .resizeVideo: " 720p"
        case .normalizeAudio: " even"
        default: ""
        }
    }
}
