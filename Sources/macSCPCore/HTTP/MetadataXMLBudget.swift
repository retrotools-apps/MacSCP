import Foundation

/// Bound XML work even for injected transports and internal entity expansion.
enum MetadataXMLBudget {
    static let maximumBytes = 8 * 1024 * 1024

    static func validate(_ data: Data) throws {
        guard data.count <= maximumBytes else { throw limitError }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        // Leave ordinary syntax errors to the owning parser's existing mapper.
        if delegate.exceeded { throw limitError }
    }

    static var limitError: RemoteFSError {
        .finding(.metadataLimitExceeded)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var exceeded = false
        private var depth = 0
        private var elements = 0
        private var textBytes = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            depth += 1
            elements += 1
            if depth > 64 || elements > 200_000 { stop(parser) }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            textBytes += string.utf8.count
            if textBytes > MetadataXMLBudget.maximumBytes { stop(parser) }
        }

        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String,
                    value: String?) {
            stop(parser)
        }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            stop(parser)
        }

        private func stop(_ parser: XMLParser) {
            exceeded = true
            parser.abortParsing()
        }
    }
}
