// Merges a single-release appcast (from make-appcast.sh) into the cumulative update feed,
// site/appcast.xml, which serves both channels: entries without <sparkle:channel> are stable,
// entries with <sparkle:channel>beta</sparkle:channel> are beta.
//
// Usage: swift scripts/merge-appcast.swift <feed.xml> <release-appcast.xml> [--keep N]
//        swift scripts/merge-appcast.swift --self-test
//
// An entry with the same build number is replaced (a re-run of a release); the newest N entries
// per channel are kept (default 10); entries are written newest first.

import Foundation

let sparkleNamespace = "http://www.andymatuschak.org/xml-namespaces/sparkle"

enum MergeError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case .invalid(let detail): detail
        }
    }
}

/// Build number of an entry (`<sparkle:version>`), used for ordering and replacement.
func build(of item: XMLElement) -> Int {
    Int(item.elements(forLocalName: "version", uri: sparkleNamespace).first?.stringValue ?? "") ?? 0
}

/// Channel of an entry; "" for the default (stable) channel.
func channel(of item: XMLElement) -> String {
    item.elements(forLocalName: "channel", uri: sparkleNamespace).first?.stringValue ?? ""
}

func channelElement(_ document: XMLDocument, _ name: String) throws -> XMLElement {
    guard let element = try document.nodes(forXPath: "/rss/channel").first as? XMLElement else {
        throw MergeError.invalid("\(name) has no /rss/channel")
    }
    return element
}

/// Merges `release` into `feed` in place.
func merge(feed: XMLDocument, release: XMLDocument, keepPerChannel: Int) throws {
    let feedChannel = try channelElement(feed, "the feed")
    let newItems = try channelElement(release, "the release appcast").elements(forName: "item")
    guard !newItems.isEmpty else { throw MergeError.invalid("the release appcast has no item") }

    var items = feedChannel.elements(forName: "item")
    for item in items { item.detach() }
    for newItem in newItems {
        let newBuild = build(of: newItem)
        guard newBuild > 0 else { throw MergeError.invalid("an item has no numeric sparkle:version") }
        items.removeAll { build(of: $0) == newBuild }
        guard let copy = newItem.copy() as? XMLElement else { throw MergeError.invalid("cannot copy item") }
        items.append(copy)
    }

    // Newest first, then keep the newest N per channel.
    items.sort { build(of: $0) > build(of: $1) }
    var keptPerChannel: [String: Int] = [:]
    for item in items {
        let name = channel(of: item)
        let kept = keptPerChannel[name, default: 0]
        guard kept < keepPerChannel else { continue }
        keptPerChannel[name] = kept + 1
        feedChannel.addChild(item)
    }
}

func load(_ path: String) throws -> XMLDocument {
    try XMLDocument(contentsOf: URL(fileURLWithPath: path), options: [.nodePreserveCDATA])
}

func document(_ text: String) throws -> XMLDocument {
    try XMLDocument(xmlString: text, options: [.nodePreserveCDATA])
}

// MARK: Self-test

func feedXML(_ items: String) -> String {
    """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="\(sparkleNamespace)"><channel><title>Colima Desktop</title>\(items)</channel></rss>
    """
}

func itemXML(_ build: Int, _ version: String, channel: String? = nil) -> String {
    let channelTag = channel.map { "<sparkle:channel>\($0)</sparkle:channel>" } ?? ""
    return "<item><title>\(version)</title><sparkle:version>\(build)</sparkle:version>\(channelTag)"
        + "<description sparkle:format=\"markdown\"><![CDATA[- **\(version)** highlights]]></description></item>"
}

func selfTest() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw MergeError.invalid("self-test failed: \(message)") }
    }
    func builds(_ feed: XMLDocument) throws -> [Int] {
        try channelElement(feed, "feed").elements(forName: "item").map(build(of:))
    }

    // A beta lands next to the stable entry, newest first.
    let feed = try document(feedXML(itemXML(11, "0.6.1")))
    try merge(feed: feed, release: try document(feedXML(itemXML(15, "0.8.0-beta.1", channel: "beta"))), keepPerChannel: 10)
    try check(try builds(feed) == [15, 11], "beta merged before stable: \(try builds(feed))")

    // Re-running a release replaces its entry instead of duplicating it.
    try merge(feed: feed, release: try document(feedXML(itemXML(15, "0.8.0-beta.1", channel: "beta"))), keepPerChannel: 10)
    try check(try builds(feed) == [15, 11], "re-run replaced: \(try builds(feed))")

    // Pruning counts each channel separately.
    for (build, version) in [(16, "0.7"), (17, "0.7.1")] {
        try merge(feed: feed, release: try document(feedXML(itemXML(build, version))), keepPerChannel: 2)
    }
    try check(try builds(feed) == [17, 16, 15], "two stable kept, beta kept: \(try builds(feed))")

    // The channel tag and the Markdown release notes survive the round trip.
    let text = feed.xmlString
    try check(text.contains("<sparkle:channel>beta</sparkle:channel>"), "channel tag kept")
    try check(text.contains("<![CDATA[- **0.7.1** highlights]]>"), "CDATA kept")
    try check(text.contains("sparkle:format=\"markdown\""), "release notes format kept")

    // A release appcast without a build number is rejected.
    do {
        try merge(feed: feed, release: try document(feedXML("<item><title>x</title></item>")), keepPerChannel: 10)
        try check(false, "item without build number rejected")
    } catch MergeError.invalid {}

    print("merge-appcast self-test: OK")
}

// MARK: Main

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    if arguments == ["--self-test"] {
        try selfTest()
        exit(0)
    }
    guard arguments.count == 2 || (arguments.count == 4 && arguments[2] == "--keep") else {
        throw MergeError.invalid("usage: merge-appcast.swift <feed.xml> <release-appcast.xml> [--keep N]")
    }
    let keep = arguments.count == 4 ? (Int(arguments[3]) ?? 10) : 10
    let feed = try load(arguments[0])
    try merge(feed: feed, release: try load(arguments[1]), keepPerChannel: keep)
    try feed.xmlData(options: [.nodePrettyPrint, .nodePreserveCDATA]).write(to: URL(fileURLWithPath: arguments[0]))
    let count = try channelElement(feed, "feed").elements(forName: "item").count
    print("Feed: \(arguments[0]) (\(count) entries)")
} catch {
    FileHandle.standardError.write(Data("merge-appcast: \(error)\n".utf8))
    exit(1)
}
