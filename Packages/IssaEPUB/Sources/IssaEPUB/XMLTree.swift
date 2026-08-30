import Foundation

/// A minimal XML tree, built on the system parser.
///
/// EPUB packages, navigation documents and SMIL overlays are all small,
/// well-formed XML. A tree keeps the parsing code declarative without pulling in
/// a dependency.
final class XMLNode: @unchecked Sendable {
    let name: String
    var attributes: [String: String]
    var text: String = ""
    private(set) var children: [XMLNode] = []
    weak var parent: XMLNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func add(_ child: XMLNode) {
        child.parent = self
        children.append(child)
    }

    /// Direct children with this local name.
    func children(_ localName: String) -> [XMLNode] {
        children.filter { $0.name == localName }
    }

    func firstChild(_ localName: String) -> XMLNode? {
        children.first { $0.name == localName }
    }

    /// Depth-first search by local name.
    func descendants(_ localName: String) -> [XMLNode] {
        var found: [XMLNode] = []
        for child in children {
            if child.name == localName { found.append(child) }
            found.append(contentsOf: child.descendants(localName))
        }
        return found
    }

    subscript(attribute: String) -> String? { attributes[attribute] }
}

enum XML {
    /// Parses into a tree, stripping namespace prefixes.
    ///
    /// EPUB documents vary wildly in whether and how they prefix `opf:`, `dc:`,
    /// `epub:` and `smil:`. Matching on the local name is what makes the parser
    /// work across real-world books rather than only tidy ones.
    static func parse(_ data: Data) throws -> XMLNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw EPUBError.malformedPackage(
                parser.parserError?.localizedDescription ?? "XML parse failed",
            )
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        private var stack: [XMLNode] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String],
        ) {
            // Namespace processing is on, so elementName is already the local
            // name — but attribute keys still arrive qualified (e.g. epub:type).
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                attributes[key] = value
                if let colon = key.firstIndex(of: ":") {
                    attributes[String(key[key.index(after: colon)...])] = value
                }
            }
            let node = XMLNode(name: elementName, attributes: attributes)
            if let current = stack.last { current.add(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
        ) {
            if let node = stack.popLast() {
                node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}
