//
//  FileConversionService.swift
//  boringNotch
//
//  Converts files between formats using only built-in macOS frameworks
//  (ImageIO, PDFKit, the Cocoa text system). Nothing leaves the Mac.
//
//  Images    → any image format macOS can write (PNG, JPG, HEIC, TIFF, GIF, BMP,
//              JPEG 2000, and AVIF/WebP when the system supports writing them) or PDF
//  PDF       → TXT, DOCX, DOC, RTF, ODT, HTML, JSON, PNG/JPG (one image per page)
//  Documents → (TXT, MD, RTF, DOCX, DOC, ODT, HTML) to each other, PDF and JSON
//  JSON      → pretty / minified JSON, CSV (array of objects), TXT
//  CSV       → JSON
//
//  Note: PDF → Word keeps the text and basic styling, not the exact page layout.
//

import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers

struct ConversionTarget: Hashable, Identifiable {
    let id: String
    let title: String
    let fileExtension: String
}

enum FileConversionError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let message): return message
        case .unreadable(let name): return "Couldn't read \"\(name)\"."
        case .writeFailed(let name): return "Couldn't create \"\(name)\"."
        }
    }
}

@MainActor
enum FileConversionService {
    enum Category { case image, pdf, document, json, csv, unsupported }

    // MARK: - Targets

    private static let imageCandidates: [(title: String, type: String, ext: String)] = [
        ("PNG", "public.png", "png"),
        ("JPG", "public.jpeg", "jpg"),
        ("HEIC", "public.heic", "heic"),
        ("AVIF", "public.avif", "avif"),
        ("WebP", "org.webmproject.webp", "webp"),
        ("TIFF", "public.tiff", "tiff"),
        ("GIF", "com.compuserve.gif", "gif"),
        ("BMP", "com.microsoft.bmp", "bmp"),
        ("JPEG 2000", "public.jpeg-2000", "jp2"),
    ]

    /// Image formats this Mac can write (AVIF/WebP depend on the macOS version).
    static let writableImageTargets: [ConversionTarget] = {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return imageCandidates
            .filter { writable.contains($0.type) }
            .map { ConversionTarget(id: "image:\($0.type)", title: $0.title, fileExtension: $0.ext) }
    }()

    static let pdf = ConversionTarget(id: "pdf", title: "PDF", fileExtension: "pdf")
    static let txt = ConversionTarget(id: "txt", title: "Text (.txt)", fileExtension: "txt")
    static let docx = ConversionTarget(id: "docx", title: "Word (.docx)", fileExtension: "docx")
    static let doc = ConversionTarget(id: "doc", title: "Word 97 (.doc)", fileExtension: "doc")
    static let rtf = ConversionTarget(id: "rtf", title: "Rich Text (.rtf)", fileExtension: "rtf")
    static let odt = ConversionTarget(id: "odt", title: "OpenDocument (.odt)", fileExtension: "odt")
    static let html = ConversionTarget(id: "html", title: "Web page (.html)", fileExtension: "html")
    static let json = ConversionTarget(id: "json", title: "JSON", fileExtension: "json")
    static let jsonPretty = ConversionTarget(id: "json-pretty", title: "JSON (pretty)", fileExtension: "json")
    static let jsonMinified = ConversionTarget(id: "json-min", title: "JSON (minified)", fileExtension: "json")
    static let csv = ConversionTarget(id: "csv", title: "CSV", fileExtension: "csv")
    static let pagesPNG = ConversionTarget(id: "pages-png", title: "PNG (each page)", fileExtension: "png")
    static let pagesJPG = ConversionTarget(id: "pages-jpg", title: "JPG (each page)", fileExtension: "jpg")

    static func category(of url: URL) -> Category {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .unsupported }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .json) { return .json }
        if type.conforms(to: .commaSeparatedText) { return .csv }
        if type.conforms(to: .svg) { return .unsupported }
        if type.conforms(to: .image) { return .image }
        let documentTypes: [UTType] = [
            .plainText, .rtf, .rtfd, .html,
            UTType("org.openxmlformats.wordprocessingml.document"),
            UTType("com.microsoft.word.doc"),
            UTType("org.oasis-open.opendocument.text"),
        ].compactMap { $0 }
        if documentTypes.contains(where: { type.conforms(to: $0) }) { return .document }
        return .unsupported
    }

    static func targets(for url: URL) -> [ConversionTarget] {
        let ext = url.pathExtension.lowercased()
        let sameFormat: (ConversionTarget) -> Bool = { target in
            target.fileExtension == ext || (ext == "jpeg" && target.fileExtension == "jpg")
                || (ext == "htm" && target.fileExtension == "html") || (ext == "tif" && target.fileExtension == "tiff")
        }
        switch category(of: url) {
        case .image:
            return writableImageTargets.filter { !sameFormat($0) } + [pdf]
        case .pdf:
            return [txt, docx, doc, rtf, odt, html, json] + [pagesPNG, pagesJPG]
        case .document:
            return [pdf, txt, docx, doc, rtf, odt, html, json].filter { !sameFormat($0) }
        case .json:
            return [jsonPretty, jsonMinified, csv, txt]
        case .csv:
            return [json]
        case .unsupported:
            return []
        }
    }

    /// Targets available for every selected file.
    static func commonTargets(for urls: [URL]) -> [ConversionTarget] {
        guard let first = urls.first else { return [] }
        var result = targets(for: first)
        for url in urls.dropFirst() {
            let ids = Set(targets(for: url).map(\.id))
            result.removeAll { !ids.contains($0.id) }
        }
        return result
    }

    static func target(withID id: String, for url: URL) -> ConversionTarget? {
        targets(for: url).first { $0.id == id }
    }

    // MARK: - Convert

    /// Converts `url` and returns the new file (or a folder for per-page images)
    /// inside the temporary directory.
    static func convert(_ url: URL, to target: ConversionTarget) throws -> URL {
        let baseName = url.deletingPathExtension().lastPathComponent
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        var outputName = "\(baseName).\(target.fileExtension)"
        if target == jsonPretty { outputName = "\(baseName)-pretty.json" }
        if target == jsonMinified { outputName = "\(baseName)-min.json" }
        let output = outputDir.appendingPathComponent(outputName)

        switch category(of: url) {
        case .image:
            if target == pdf {
                try imageToPDF(url, output: output)
            } else {
                try convertImage(url, to: target, output: output)
            }
        case .pdf:
            try convertPDF(url, to: target, outputDir: outputDir, output: output)
        case .document:
            try convertDocument(url, to: target, output: output)
        case .json:
            try convertJSON(url, to: target, output: output)
        case .csv:
            try csvToJSON(url, output: output)
        case .unsupported:
            throw FileConversionError.unsupported("\(url.lastPathComponent) can't be converted.")
        }

        if target == pagesPNG || target == pagesJPG {
            return outputDir.appendingPathComponent("\(baseName) pages", isDirectory: true)
        }
        return output
    }

    // MARK: - Images

    private static func convertImage(_ url: URL, to target: ConversionTarget, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FileConversionError.unreadable(url.lastPathComponent) }

        let type = String(target.id.dropFirst("image:".count))
        // JPEG/BMP have no transparency: put transparent images on white instead of black.
        if ["public.jpeg", "com.microsoft.bmp"].contains(type), let flattened = flattenOnWhite(image) {
            image = flattened
        }
        try writeCGImage(image, type: type, to: output)
    }

    private static func writeCGImage(_ image: CGImage, type: String, to output: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, 1, nil) else {
            throw FileConversionError.unsupported("This Mac can't save \(output.pathExtension.uppercased()) images.")
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FileConversionError.writeFailed(output.lastPathComponent)
        }
    }

    private static func flattenOnWhite(_ image: CGImage) -> CGImage? {
        guard ![CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    private static func imageToPDF(_ url: URL, output: URL) throws {
        guard let image = NSImage(contentsOf: url), let page = PDFPage(image: image) else {
            throw FileConversionError.unreadable(url.lastPathComponent)
        }
        let document = PDFDocument()
        document.insert(page, at: 0)
        guard document.write(to: output) else { throw FileConversionError.writeFailed(output.lastPathComponent) }
    }

    // MARK: - PDF

    private static func convertPDF(_ url: URL, to target: ConversionTarget, outputDir: URL, output: URL) throws {
        guard let document = PDFDocument(url: url) else { throw FileConversionError.unreadable(url.lastPathComponent) }
        let baseName = url.deletingPathExtension().lastPathComponent

        switch target {
        case txt:
            try (document.string ?? "").write(to: output, atomically: true, encoding: .utf8)

        case json:
            var pages: [[String: Any]] = []
            for index in 0..<document.pageCount {
                pages.append(["page": index + 1, "text": document.page(at: index)?.string ?? ""])
            }
            let object: [String: Any] = ["file": url.lastPathComponent, "pageCount": document.pageCount, "pages": pages]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: output)

        case pagesPNG, pagesJPG:
            let folder = outputDir.appendingPathComponent("\(baseName) pages", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let type = target == pagesPNG ? "public.png" : "public.jpeg"
            let digits = String(document.pageCount).count
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index), let image = render(page) else { continue }
                let number = String(format: "%0\(digits)d", index + 1)
                let file = folder.appendingPathComponent("\(baseName) - \(number).\(target.fileExtension)")
                try writeCGImage(image, type: type, to: file)
            }

        default:
            // Rich text formats: rebuild the text (with basic styling) page by page.
            let text = NSMutableAttributedString()
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                if let attributed = page.attributedString { text.append(attributed) }
                if index < document.pageCount - 1 { text.append(NSAttributedString(string: "\n\n")) }
            }
            try writeAttributed(text, to: target, output: output)
        }
    }

    /// Renders a PDF page at 2x on a white background.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    // MARK: - Documents

    private static func convertDocument(_ url: URL, to target: ConversionTarget, output: URL) throws {
        let text = try readAttributed(url)
        switch target {
        case pdf:
            try renderPDF(text, to: output)
        case json:
            let object: [String: Any] = ["file": url.lastPathComponent, "text": text.string]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
            try data.write(to: output)
        default:
            try writeAttributed(text, to: target, output: output)
        }
    }

    private static func readAttributed(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["txt", "md", "markdown", "text", "log"].contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .plainText) == true {
            guard let data = try? Data(contentsOf: url) else { throw FileConversionError.unreadable(url.lastPathComponent) }
            let string = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            return NSAttributedString(string: string, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        } catch {
            throw FileConversionError.unreadable(url.lastPathComponent)
        }
    }

    private static func writeAttributed(_ text: NSAttributedString, to target: ConversionTarget, output: URL) throws {
        if target == txt {
            try text.string.write(to: output, atomically: true, encoding: .utf8)
            return
        }
        let documentType: NSAttributedString.DocumentType
        switch target {
        case docx: documentType = .officeOpenXML
        case doc: documentType = .docFormat
        case rtf: documentType = .rtf
        case odt: documentType = .openDocument
        case html: documentType = .html
        default: throw FileConversionError.unsupported("Unsupported target \(target.title).")
        }
        let range = NSRange(location: 0, length: text.length)
        let data = try text.data(from: range, documentAttributes: [.documentType: documentType])
        try data.write(to: output)
    }

    /// Lays text out on A4 pages and draws it into a PDF.
    private static func renderPDF(_ text: NSAttributedString, to output: URL) throws {
        let pageSize = CGSize(width: 595, height: 842)
        let margin: CGFloat = 56
        let textSize = CGSize(width: pageSize.width - margin * 2, height: pageSize.height - margin * 2)

        // Default to black text so dark-mode colors don't end up invisible on paper.
        let printable = NSMutableAttributedString(attributedString: text)
        printable.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: printable.length)) { value, range, _ in
            if value == nil { printable.addAttribute(.foregroundColor, value: NSColor.black, range: range) }
        }

        let storage = NSTextStorage(attributedString: printable)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        var containers: [NSTextContainer] = []
        repeat {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
        } while NSMaxRange(layoutManager.glyphRange(for: containers[containers.count - 1])) < layoutManager.numberOfGlyphs
            && containers.count < 5000

        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw FileConversionError.writeFailed(output.lastPathComponent)
        }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let glyphs = layoutManager.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: glyphs, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    // MARK: - JSON / CSV

    private static func convertJSON(_ url: URL, to target: ConversionTarget, output: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { throw FileConversionError.unreadable(url.lastPathComponent) }

        switch target {
        case jsonMinified:
            try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .withoutEscapingSlashes]).write(to: output)
        case csv:
            try csvString(from: object).write(to: output, atomically: true, encoding: .utf8)
        default: // pretty JSON / txt
            try JSONSerialization.data(withJSONObject: object, options: [.fragmentsAllowed, .prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: output)
        }
    }

    private static func csvString(from object: Any) throws -> String {
        let rows: [[String: Any]]
        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any] {
            rows = [dictionary]
        } else {
            throw FileConversionError.unsupported("CSV needs a JSON list of objects, like [{\"name\": \"A\"}, …].")
        }
        var headers: [String] = []
        for row in rows {
            for key in row.keys.sorted() where !headers.contains(key) { headers.append(key) }
        }
        func cell(_ value: Any?) -> String {
            guard let value, !(value is NSNull) else { return "" }
            var text: String
            if let string = value as? String {
                text = string
            } else if JSONSerialization.isValidJSONObject(value),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes]) {
                text = String(decoding: data, as: UTF8.self)
            } else {
                text = "\(value)"
            }
            if text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
                text = "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return text
        }
        var lines = [headers.map { cell($0) }.joined(separator: ",")]
        for row in rows {
            lines.append(headers.map { cell(row[$0]) }.joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvToJSON(_ url: URL, output: URL) throws {
        guard let data = try? Data(contentsOf: url) else { throw FileConversionError.unreadable(url.lastPathComponent) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let rows = parseCSV(text)
        guard let header = rows.first else { throw FileConversionError.unreadable(url.lastPathComponent) }
        let objects: [[String: String]] = rows.dropFirst().filter { !($0.count == 1 && $0[0].isEmpty) }.map { row in
            var object: [String: String] = [:]
            for (index, key) in header.enumerated() { object[key] = index < row.count ? row[index] : "" }
            return object
        }
        try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: output)
    }

    /// Minimal RFC 4180 parser (quoted fields, escaped quotes, newlines in quotes).
    private static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let char = next() {
            if inQuotes {
                if char == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else { inQuotes = false }
                } else {
                    field.append(char)
                }
            } else {
                switch char {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r\n", "\r":
                    row.append(field); field = ""
                    rows.append(row); row = []
                default: field.append(char)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
