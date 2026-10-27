import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// TC3-HMAC-SHA256 signing for Tencent Cloud API 3.0 JSON POST requests.
///
/// Tencent's documented scheme (cloud.tencent.com/document/api/1300/81014):
/// the canonical request signs `content-type` and `host` only, the credential
/// scope is `<UTC date>/<service>/tc3_request`, and the signing key is derived
/// by chaining HMAC-SHA256 over date → service → `tc3_request`.
struct TencentCloudTC3Signer: Sendable {
  let secretID: String
  let secretKey: String
  /// Temporary-credentials session token, sent as `X-TC-Token` when present.
  /// It is part of the credential, not the signed headers.
  let sessionToken: String?
  let service: String
  let region: String?

  init(secretID: String, secretKey: String, sessionToken: String? = nil,
       service: String, region: String? = nil) {
    self.secretID = secretID
    self.secretKey = secretKey
    self.sessionToken = sessionToken
    self.service = service
    self.region = region
  }

  /// Signed headers for a JSON action call. `timestamp` is injectable so tests
  /// pin the signature; `date` must be the timestamp's UTC calendar day.
  func signedRequest(
    action: String,
    version: String,
    body: Data,
    endpoint: URL,
    timestamp: Date
  ) throws -> URLRequest {
    guard let host = endpoint.host, !host.isEmpty else {
      throw ProviderClientError(kind: .notConfigured, message: "TokenHub endpoint URL must include a host.")
    }

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.httpBody = body
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(host, forHTTPHeaderField: "Host")
    request.setValue(action, forHTTPHeaderField: "X-TC-Action")
    request.setValue(version, forHTTPHeaderField: "X-TC-Version")
    request.setValue(String(Int(timestamp.timeIntervalSince1970)), forHTTPHeaderField: "X-TC-Timestamp")
    if let region { request.setValue(region, forHTTPHeaderField: "X-TC-Region") }
    if let sessionToken, !sessionToken.isEmpty {
      request.setValue(sessionToken, forHTTPHeaderField: "X-TC-Token")
    }
    request.setValue("LLimit/0.1", forHTTPHeaderField: "User-Agent")
    request.setValue(authorization(action: nil, host: host, body: body, timestamp: timestamp),
                     forHTTPHeaderField: "Authorization")
    return request
  }

  private func authorization(action: String?, host: String, body: Data, timestamp: Date) -> String {
    let signedHeaders = "content-type;host"
    let canonicalHeaders = "content-type:application/json\nhost:\(host)\n"
    let canonicalRequest = [
      "POST", "/", "", canonicalHeaders, signedHeaders, SHA256.hexDigest(body)
    ].joined(separator: "\n")

    let day = Self.utcDayFormatter.string(from: timestamp)
    let credentialScope = "\(day)/\(service)/tc3_request"
    let stringToSign = [
      "TC3-HMAC-SHA256",
      String(Int(timestamp.timeIntervalSince1970)),
      credentialScope,
      SHA256.hexDigest(Data(canonicalRequest.utf8))
    ].joined(separator: "\n")

    let dateKey = HMACSHA256.sign(key: "TC3\(secretKey)", message: day)
    let serviceKey = HMACSHA256.sign(key: dateKey, message: [UInt8](service.utf8))
    let signingKey = HMACSHA256.sign(key: serviceKey, message: [UInt8]("tc3_request".utf8))
    let signature = HMACSHA256.hexSign(key: signingKey, message: [UInt8](stringToSign.utf8))

    return "TC3-HMAC-SHA256 Credential=\(secretID)/\(credentialScope), "
      + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
  }

  private static let utcDayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()
}
