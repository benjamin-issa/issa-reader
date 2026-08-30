import Foundation

/// A minimal XML tree, built on the system parser.
///
/// Models mixed content properly: `text` is what appears before the first
/// child, and each child carries the `tail` text that follows it. Without that
/// distinction `<p>Hello <b>world</b> again</p>` loses the word "again", or
/// reorders it — which is exactly the class of bug that makes a reader subtly
/// mangle ordinary prose.
public final class EPUBXMLNode: @unchecked Sendable {
    public let name: String
    public var attributes: [String: String]
    /// Character data before the first child element.
    public var text: String = ""
    /// Character data immediately after this element, belonging to its parent.
    public var tail: String = ""
    public private(set) var children: [EPUBXMLNode] = []
    public weak var parent: EPUBXMLNode?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    func add(_ child: EPUBXMLNode) {
        child.parent = self
        children.append(child)
    }

    public func children(_ localName: String) -> [EPUBXMLNode] {
        children.filter { $0.name == localName }
    }

    public func firstChild(_ localName: String) -> EPUBXMLNode? {
        children.first { $0.name == localName }
    }

    /// Depth-first search by local name.
    public func descendants(_ localName: String) -> [EPUBXMLNode] {
        var found: [EPUBXMLNode] = []
        for child in children {
            if child.name == localName { found.append(child) }
            found.append(contentsOf: child.descendants(localName))
        }
        return found
    }

    public func firstDescendant(named localName: String) -> EPUBXMLNode? {
        if name.lowercased() == localName.lowercased() { return self }
        for child in children {
            if let hit = child.firstDescendant(named: localName) { return hit }
        }
        return nil
    }

    /// All character data beneath this node, in document order.
    public var allText: String {
        var result = text
        for child in children {
            result += child.allText
            result += child.tail
        }
        return result
    }

    /// Leading text with surrounding whitespace removed, for metadata fields.
    public var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public subscript(attribute: String) -> String? { attributes[attribute] }
}

public enum EPUBXML {
    /// Parses into a tree, matching on local names.
    ///
    /// EPUB documents vary wildly in whether and how they prefix `opf:`, `dc:`,
    /// `epub:` and `smil:`. Matching the local name is what makes this work
    /// against real books rather than only tidy ones.
    public static func parse(_ data: Data) throws -> EPUBXMLNode {
        let delegate = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw EPUBError.malformedPackage(
                parser.parserError?.localizedDescription ?? "XML parse failed",
            )
        }
        return root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: EPUBXMLNode?
        private var stack: [EPUBXMLNode] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String],
        ) {
            // Namespaces are processed, so elementName is the local name — but
            // attribute keys still arrive qualified (e.g. `epub:type`), so both
            // forms are indexed.
            var attributes: [String: String] = [:]
            for (key, value) in attributeDict {
                attributes[key] = value
                if let colon = key.firstIndex(of: ":") {
                    attributes[String(key[key.index(after: colon)...])] = value
                }
            }
            let node = EPUBXMLNode(name: elementName, attributes: attributes)
            if let current = stack.last { current.add(node) } else { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last else { return }
            // Text after a child belongs to that child's tail, not to the
            // parent's leading text.
            if let lastChild = current.children.last {
                lastChild.tail += string
            } else {
                current.text += string
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let string = String(data: CDATABlock, encoding: .utf8) else { return }
            self.parser(parser, foundCharacters: string)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName qName: String?,
        ) {
            _ = stack.popLast()
        }
    }
}
