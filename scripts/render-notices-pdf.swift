import AppKit
import CoreText
import CryptoKit
import PDFKit

// Native macOS renderer: no HTML engine, network access or external fonts.
struct Entry: Decodable {
    let identity: String
    let version: String
    let location: String
    let licence_files: [[String]]
}

func normalized(_ text: String) -> String {
    String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--text" {
    guard let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])),
          let text = document.string else { exit(1) }
    print(text)
    exit(0)
}

func bookmarkDestinations(_ document: PDFDocument) -> [String]? {
    guard let root = document.outlineRoot, root.numberOfChildren > 0 else { return nil }
    var result: [String] = []
    for index in 0..<root.numberOfChildren {
        guard let item = root.child(at: index), let label = item.label,
              let page = item.destination?.page else { return nil }
        result.append(label + ":" + String(document.index(for: page)))
    }
    return result
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--compare" {
    guard let lhs = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])),
          let rhs = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[3])),
          lhs.pageCount == rhs.pageCount,
          let lhsBookmarks = bookmarkDestinations(lhs), let rhsBookmarks = bookmarkDestinations(rhs),
          lhsBookmarks == rhsBookmarks,
          lhs.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String == rhs.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String else {
        exit(1)
    }
    for index in 0..<lhs.pageCount {
        guard let a = lhs.page(at: index), let b = rhs.page(at: index),
              a.string == b.string, a.bounds(for: .mediaBox) == b.bounds(for: .mediaBox) else { exit(1) }
    }
    exit(0)
}

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: render-notices-pdf.swift INPUT.json OUTPUT.pdf")
}
let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let entries = try JSONDecoder().decode([Entry].self, from: input)
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let rendererSource = try Data(contentsOf: URL(fileURLWithPath: #filePath))
let fingerprint = SHA256.hash(data: input + rendererSource).map { String(format: "%02x", $0) }.joined()
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

func attributes(size: CGFloat, bold: Bool = false, monospaced: Bool = false) -> [NSAttributedString.Key: Any] {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = monospaced ? 1.5 : 2.5
    paragraph.paragraphSpacing = monospaced ? 0 : 5
    let font = NSFont(name: monospaced ? "Menlo" : (bold ? "Helvetica-Bold" : "Helvetica"), size: size)!
    return [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph]
}

let cover = NSMutableAttributedString(string: "MacSCP\nThird-party licenses\n\n", attributes: attributes(size: 26, bold: true))
cover.append(NSAttributedString(string: "Copyright notices and license terms for software included in MacSCP.\n\n", attributes: attributes(size: 11)))
for entry in entries {
    cover.append(NSAttributedString(string: "\(entry.identity)  |  \(entry.version)\n", attributes: attributes(size: 11, bold: true)))
    cover.append(NSAttributedString(string: entry.location.replacingOccurrences(of: ".git", with: "") + "\n", attributes: attributes(size: 9)))
}

var sections: [(String, NSAttributedString)] = [("Included software", cover)]
for entry in entries {
    let text = NSMutableAttributedString(string: entry.identity + "\n", attributes: attributes(size: 22, bold: true))
    text.append(NSAttributedString(string: entry.version + "\n" + entry.location + "\n\n", attributes: attributes(size: 10)))
    for file in entry.licence_files {
        guard file.count == 2 else { fatalError("Invalid license entry") }
        text.append(NSAttributedString(string: file[0] + "\n\n", attributes: attributes(size: 11, bold: true)))
        let bodyStyle = attributes(size: 9.5, monospaced: true)
        // Wrap at word boundaries before layout. Tiny automatic continuation
        // lines can otherwise be interpreted as separate PDF text columns.
        let displayLines = file[1].split(separator: "\n", omittingEmptySubsequences: false).flatMap { source -> [String] in
            var remaining = String(source)
            var lines: [String] = []
            while remaining.count > 80 {
                guard let split = remaining.prefix(80).lastIndex(where: { $0.isWhitespace }),
                      split > remaining.startIndex else { break }
                lines.append(String(remaining[..<split]))
                remaining = String(remaining[remaining.index(after: split)...])
            }
            lines.append(remaining)
            return lines
        }
        for line in displayLines {
            var style = bodyStyle
            // Prefer a compact face for long source lines. Wrapped indented
            // license lines can otherwise be reordered by PDF text extraction.
            if NSAttributedString(string: String(line), attributes: style).size().width > 499 {
                style[.font] = NSFont(name: "Helvetica", size: 9.5)!
                let width = NSAttributedString(string: String(line), attributes: style).size().width
                if width > 499 { style[.font] = NSFont(name: "Helvetica", size: max(8, 9.5 * 499 / width))! }
            }
            let paragraph = (bodyStyle[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            paragraph.headIndent = min(120, NSAttributedString(string: indent, attributes: style).size().width)
            style[.paragraphStyle] = paragraph
            text.append(NSAttributedString(string: String(line) + "\n", attributes: style))
        }
        text.append(NSAttributedString(string: "\n", attributes: bodyStyle))
    }
    sections.append((entry.identity, text))
}

var mediaBox = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
let metadata: [CFString: Any] = [kCGPDFContextTitle: "MacSCP - Third-party licenses",
    kCGPDFContextCreator: "MacSCP", kCGPDFContextSubject: fingerprint]
guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, metadata as CFDictionary) else {
    fatalError("Cannot create PDF")
}
var pageNumber = 0
var bookmarks: [(String, Int)] = []
for (title, section) in sections {
    bookmarks.append((title, pageNumber))
    let framesetter = CTFramesetterCreateWithAttributedString(section)
    var offset = 0
    while offset < section.length {
        context.beginPDFPage(nil)
        pageNumber += 1
        let path = CGPath(rect: CGRect(x: 48, y: 56, width: mediaBox.width - 96, height: mediaBox.height - 104), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
        let visible = CTFrameGetVisibleStringRange(frame)
        guard visible.length > 0 else { fatalError("PDF pagination made no progress") }
        CTFrameDraw(frame, context)
        let footer = NSAttributedString(string: "MacSCP - Third-party licenses                                      \(pageNumber)", attributes: attributes(size: 8))
        context.textPosition = CGPoint(x: 48, y: 28)
        CTLineDraw(CTLineCreateWithAttributedString(footer), context)
        context.endPDFPage()
        offset += visible.length
    }
}
// Write outlines in the original Core Graphics context. PDFKit can omit
// newly assigned outlines when reserializing a generated document on newer SDKs.
let children: [CFDictionary] = bookmarks.map { label, index in
    [kCGPDFOutlineTitle: label, kCGPDFOutlineDestination: index + 1] as CFDictionary
}
CGPDFContextSetOutline(context, [kCGPDFOutlineChildren: children] as CFDictionary)
context.closePDF()
guard let document = PDFDocument(url: output), document.outlineRoot?.numberOfChildren == bookmarks.count else {
    fatalError("Saved PDF lost its dependency bookmarks")
}

// Verify all source license text survived pagination and Unicode extraction.
let extracted = normalized((document.string ?? "").replacingOccurrences(
    of: "MacSCP - Third-party licenses\\s+\\d+", with: "", options: .regularExpression))
for entry in entries {
    for file in entry.licence_files {
        // Footers interrupt text spanning pages, so compare each original
        // nonempty line independently, without changing the rendered text.
        for line in file[1].split(whereSeparator: \.isNewline) {
            let expected = normalized(String(line))
            if expected.isEmpty { continue }
            guard extracted.contains(expected) else { fatalError("PDF omitted license text in \(entry.identity): \(file[0])") }
        }
    }
}
print("wrote \(output.lastPathComponent) (\(pageNumber) pages)")
