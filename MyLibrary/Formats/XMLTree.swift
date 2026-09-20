import Foundation

/// A tiny read-only DOM built on `XMLParser`, enough for OPF/NCX/nav documents.
final class XMLElement {
    let name: String            // local name, namespace prefix stripped
    let qualifiedName: String
    let attributes: [String: String]
    /// Text runs and child elements in document order, so mixed content such as
    /// `<a>Chapter <em>One</em> begins</a>` reads back in the right sequence.
    private(set) var contents: [Content] = []
    private(set) var children: [XMLElement] = []
    weak var parent: XMLElement?

    enum Content {
        case text(String)
        case element(XMLElement)
    }

    init(qualifiedName: String, attributes: [String: String]) {
        self.qualifiedName = qualifiedName
        self.name = qualifiedName.contains(":")
            ? String(qualifiedName.split(separator: ":").last ?? "")
            : qualifiedName
        self.attributes = attributes
    }

    func append(_ child: XMLElement) {
        child.parent = self
        children.append(child)
        contents.append(.element(child))
    }

    func append(text: String) {
        contents.append(.text(text))
    }

    /// Attribute lookup that ignores namespace prefixes (`epub:type` matches `type`).
    func attribute(_ key: String) -> String? {
        if let exact = attributes[key] { return exact }
        return attributes.first { $0.key.split(separator: ":").last.map(String.init) == key }?.value
    }

    func children(named name: String) -> [XMLElement] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> XMLElement? {
        children.first { $0.name == name }
    }

    /// Depth-first search for the first descendant with this local name.
    func firstDescendant(named name: String) -> XMLElement? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(named: name) { return found }
        }
        return nil
    }

    func descendants(named name: String) -> [XMLElement] {
        var result: [XMLElement] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.descendants(named: name))
        }
        return result
    }

    /// All text in this subtree, in document order and whitespace-collapsed.
    var collectedText: String {
        rawText.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var rawText: String {
        contents.reduce(into: "") { result, content in
            switch content {
            case .text(let text): result += text
            case .element(let element): result += element.rawText
            }
        }
    }
}

enum XMLTree {
    static func parse(_ data: Data) -> XMLElement? {
        let parser = XMLParser(data: sanitize(data))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let delegate = Builder()
        parser.delegate = delegate
        // A parse error still leaves a usable partial tree for sloppy XHTML.
        _ = parser.parse()
        return delegate.root
    }

    /// XMLParser rejects HTML entities and chokes on DOCTYPE subsets, both of
    /// which are common in real EPUB navigation documents.
    private static func sanitize(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return data
        }
        text = text.replacingOccurrences(of: "<!DOCTYPE[^>\\[]*(\\[[^\\]]*\\])?[^>]*>",
                                         with: "",
                                         options: .regularExpression)
        for (entity, replacement) in htmlEntities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.data(using: .utf8) ?? data
    }

    private static let htmlEntities: [String: String] = [
        "&nbsp;": " ", "&mdash;": "\u{2014}", "&ndash;": "\u{2013}",
        "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}",
        "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
        "&hellip;": "\u{2026}", "&copy;": "\u{00A9}", "&trade;": "\u{2122}",
        "&reg;": "\u{00AE}", "&deg;": "\u{00B0}", "&eacute;": "\u{00E9}"
    ]

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLElement?
        private var stack: [XMLElement] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            let element = XMLElement(qualifiedName: elementName, attributes: attributeDict)
            stack.last?.append(element)
            if root == nil { root = element }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.append(text: string)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if !stack.isEmpty { stack.removeLast() }
        }
    }
}
