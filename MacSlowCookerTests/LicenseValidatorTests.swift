import XCTest
@testable import MacSlowCooker

final class LicenseValidatorTests: XCTestCase {

    private func makeResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.gumroad.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    func testVerifyReturnsVerifiedOnSuccess() async {
        let body = #"{"success":true,"purchase":{"license_key":"ABCD-1234-EFGH-5678"}}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 200))
        }
        let result = await validator.verify(key: "ABCD-1234-EFGH-5678")
        XCTAssertEqual(result, .verified)
    }

    func testVerifyReturnsInvalidOnFailure() async {
        let body = #"{"success":false,"message":"That license does not exist for the provided product."}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 404))
        }
        let result = await validator.verify(key: "INVALID-KEY")
        XCTAssertEqual(result, .invalid("That license does not exist for the provided product."))
    }

    func testVerifyReturnsNetworkErrorOnThrow() async {
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            throw URLError(.notConnectedToInternet)
        }
        let result = await validator.verify(key: "ANY-KEY")
        if case .networkError = result { } else {
            XCTFail("Expected .networkError, got \(result)")
        }
    }

    func testVerifySendsCorrectFormBody() async {
        var capturedRequest: URLRequest?
        let body = #"{"success":true}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { req in
            capturedRequest = req
            return (Data(body.utf8), self.makeResponse(statusCode: 200))
        }
        _ = await validator.verify(key: "MY-KEY-1234")
        let bodyString = String(data: capturedRequest!.httpBody!, encoding: .utf8)!
        XCTAssertEqual(
            bodyString,
            "product_permalink=fzifrw&license_key=MY-KEY-1234&increment_uses_count=false"
        )
    }

    func testVerifyUsesInvalidMessageFallback() async {
        let body = #"{"success":false}"#
        let validator = LicenseValidator(productPermalink: "fzifrw") { _ in
            (Data(body.utf8), self.makeResponse(statusCode: 404))
        }
        let result = await validator.verify(key: "BAD-KEY")
        XCTAssertEqual(result, .invalid("Invalid license key"))
    }
}
