import AppKit
import XCTest
@testable import PodFlick

/// The pure parsing seams of the two background entry points (B.9): the
/// podflick:// URL scheme and the Finder service pasteboard. The AppKit
/// glue (activation policy, menu-bar item, notifications) is verified by
/// hand on a real machine — it has no headless-testable surface.
final class BackgroundTransferTests: XCTestCase {

    // MARK: - podflick:// URL scheme

    func testTransferURLsParsesPathQueryItems() throws {
        let url = try XCTUnwrap(URL(string:
            "podflick://transfer?path=/Users/x/a.mp4&path=/Users/x/b%20c.mov"))

        XCTAssertEqual(URLScheme.transferURLs(from: url).map(\.path),
                       ["/Users/x/a.mp4", "/Users/x/b c.mov"])
    }

    func testTransferURLsRejectsForeignSchemes() throws {
        let url = try XCTUnwrap(URL(string:
            "https://example.com/transfer?path=/Users/x/a.mp4"))

        XCTAssertTrue(URLScheme.transferURLs(from: url).isEmpty)
    }

    func testTransferURLsWithoutPathsIsEmpty() throws {
        let url = try XCTUnwrap(URL(string: "podflick://transfer"))

        XCTAssertTrue(URLScheme.transferURLs(from: url).isEmpty)
    }

    // MARK: - Finder service pasteboard

    func testServiceProviderExtractsFileURLsOnly() throws {
        let pasteboard = NSPasteboard(name:
            NSPasteboard.Name("PodFlickTest-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let movie = URL(fileURLWithPath: "/tmp/clip.mp4")
        let web = try XCTUnwrap(URL(string: "https://example.com/a.mp4"))
        pasteboard.writeObjects([movie as NSURL, web as NSURL])

        XCTAssertEqual(ServiceProvider.fileURLs(from: pasteboard).map(\.path),
                       ["/tmp/clip.mp4"],
                       "only real file URLs survive; the web URL is dropped")
    }
}
