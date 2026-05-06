import Foundation

enum LicenseVerificationResult: Equatable {
    case verified
    case invalid(String)
    case networkError(String)
}

struct LicenseValidator {
    typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    let productPermalink: String
    var fetch: Fetch

    init(productPermalink: String, fetch: Fetch? = nil) {
        self.productPermalink = productPermalink
        self.fetch = fetch ?? { req in try await URLSession.shared.data(for: req) }
    }

    func verify(key: String) async -> LicenseVerificationResult {
        var request = URLRequest(
            url: URL(string: "https://api.gumroad.com/v2/licenses/verify")!
        )
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        guard let encodedPermalink = productPermalink.formEncoded,
              let encodedKey = key.formEncoded else {
            return .invalid("License key contains unencodable characters")
        }
        let body = [
            "product_permalink=\(encodedPermalink)",
            "license_key=\(encodedKey)",
            "increment_uses_count=false"
        ].joined(separator: "&")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await fetch(request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .networkError("No HTTP response")
            }
            guard httpResponse.statusCode < 500 else {
                return .networkError("Server error (\(httpResponse.statusCode))")
            }
            let decoded = try JSONDecoder().decode(GumroadResponse.self, from: data)
            return decoded.success
                ? .verified
                : .invalid(decoded.message ?? "Invalid license key")
        } catch {
            return .networkError(error.localizedDescription)
        }
    }
}

private struct GumroadResponse: Decodable {
    let success: Bool
    let message: String?
}

private extension String {
    var formEncoded: String? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
