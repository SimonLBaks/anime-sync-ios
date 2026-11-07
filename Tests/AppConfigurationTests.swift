import XCTest
import Foundation
@testable import AnimeSync

final class AppConfigurationTests: XCTestCase {
    private func document(home: String = "https://home.example",tailnet: String = "https://remote.example:8443",overrides: [String:String] = [:],tv: String = "") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["homeURL": home,"tailnetURL": tailnet,"connectOverrides": overrides,"defaultTVHost": tv])
    }
    func testPublicDefaultsHaveNoPersonalRouteOrDefaultTV() {
        let config = AppConfiguration.load(nil)
        XCTAssertEqual(config.homeURL.absoluteString,"https://anime-sync.example")
        XCTAssertEqual(config.tailnetURL.absoluteString,"https://anime-sync-tailnet.example:8443")
        XCTAssertTrue(config.connectOverrides.isEmpty); XCTAssertEqual(config.defaultTVHost,"")
        XCTAssertEqual(config.dashboardOrigins.count,2)
    }
    func testPrivateProfileCanonicalizesOnlyExactTrustedDashboardOriginsAndRoutes() throws {
        let config = try AppConfiguration.decode(document(home: "HTTPS://HOME.EXAMPLE:443/",overrides: ["HOME.EXAMPLE":"10.0.0.10"],tv: "10.0.0.20"))
        XCTAssertEqual(config.dashboardOrigins,["https://home.example","https://remote.example:8443"])
        XCTAssertEqual(config.dashboardHosts,["home.example","remote.example"])
        XCTAssertEqual(config.connectHost(for: "HOME.EXAMPLE"),"10.0.0.10")
        XCTAssertEqual(config.connectHost(for: "media.example"),"media.example")
        XCTAssertEqual(config.defaultTVHost,"10.0.0.20")
    }
    func testProfileRejectsInsecureCredentialedNonOriginAndUnsupportedPortURLs() throws {
        let invalid = ["http://home.example","https://user:password@home.example","https://home.example/path",
                       "https://home.example?x=1","https://home.example#fragment","https://home.example:8080",
                       "https://home.example\n","https://bad_host.example"]
        for home in invalid {
            XCTAssertThrowsError(try AppConfiguration.decode(document(home: home)),home)
        }
        XCTAssertThrowsError(try AppConfiguration.decode(document(home: "https://home.example",tailnet: "https://HOME.EXAMPLE:443/")))
    }
    func testProfileCannotRouteAnUntrustedProviderOrNonPrivateAddress() throws {
        for overrides in [["media.example":"10.0.0.10"],["home.example":"8.8.8.8"],["home.example":"127.0.0.1"],
                          ["home.example":"010.0.0.10"],["home.example":"10.0.0.10\r\n"],["home.example":"https://10.0.0.10"]] {
            XCTAssertThrowsError(try AppConfiguration.decode(document(overrides: overrides)))
        }
        for tv in ["8.8.8.8","127.0.0.1","10.0.0.20:8765","10.0.0.20\n"] {
            XCTAssertThrowsError(try AppConfiguration.decode(document(tv: tv)))
        }
    }
    func testMalformedOrPartiallyUnsafeProfileFailsClosedWithoutKeepingItsValidHalf() throws {
        XCTAssertEqual(AppConfiguration.load(Data("{".utf8)),.generic)
        let unsafe = try document(overrides: ["home.example":"8.8.8.8"])
        XCTAssertEqual(AppConfiguration.load(unsafe),.generic)
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: document()) as? [String:Any])
        unknown["sessionToken"] = "unrecognized-fixture-field"
        let unknownData = try JSONSerialization.data(withJSONObject: unknown)
        XCTAssertThrowsError(try AppConfiguration.decode(unknownData))
        XCTAssertEqual(AppConfiguration.load(unknownData),.generic)
        unknown.removeValue(forKey: "sessionToken"); unknown["connectOverrides"] = NSNull()
        XCTAssertThrowsError(try AppConfiguration.decode(JSONSerialization.data(withJSONObject: unknown)))
        XCTAssertEqual(AppConfiguration.load(Data(repeating: 32,count: 65537)),.generic)
    }
}
