import Foundation

final class CloudXMLNode {
    let name: String
    var text = ""
    var children: [CloudXMLNode] = []

    init(name: String) { self.name = name }

    func children(named name: String) -> [CloudXMLNode] {
        children.filter { $0.name == name }
    }

    func child(named name: String) -> CloudXMLNode? {
        children.first { $0.name == name }
    }
}

final class CloudXML: NSObject, XMLParserDelegate {
    private var root: CloudXMLNode?
    private var parents: [CloudXMLNode] = []
    private var nodes = 0

    static func parse(_ data: Data, expecting name: String) throws -> CloudXMLNode {
        let delegate = Self()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root, root.name == name else {
            throw CloudRemoteError.invalidResponse
        }
        return root
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        nodes += 1
        guard parents.count < 32, nodes <= 100_000 else {
            parser.abortParsing()
            return
        }
        let node = CloudXMLNode(name: elementName)
        if let parent = parents.last { parent.children.append(node) }
        else { root = node }
        parents.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = parents.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        parents.last?.text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        parents.last?.text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?
    ) {
        parser.abortParsing()
    }
}
