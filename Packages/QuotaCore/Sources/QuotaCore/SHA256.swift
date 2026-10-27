import Foundation

/// Pure-Swift SHA-256 and HMAC-SHA256 for request signing.
///
/// QuotaCore stays dependency-free and compiles on Linux, where CryptoKit does
/// not exist, so Tencent Cloud's TC3-HMAC-SHA256 signature needs an in-house
/// primitive. Verified against the RFC 4231 and FIPS 180-4 vectors in
/// TencentCloudTC3Tests; this is a signing primitive, not a password hash.
enum SHA256 {
  private static let h0: [UInt32] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ]

  private static let k: [UInt32] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
  ]

  static func hash(_ bytes: [UInt8]) -> [UInt8] {
    var message = bytes
    let bitLength = UInt64(message.count) * 8

    message.append(0x80)
    while message.count % 64 != 56 { message.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var h = h0
    var w = [UInt32](repeating: 0, count: 64)

    for blockStart in stride(from: 0, to: message.count, by: 64) {
      for index in 0..<16 {
        let offset = blockStart + index * 4
        w[index] = (UInt32(message[offset]) << 24)
          | (UInt32(message[offset + 1]) << 16)
          | (UInt32(message[offset + 2]) << 8)
          | UInt32(message[offset + 3])
      }
      for index in 16..<64 {
        let s0 = w[index - 15].rotateRight(7) ^ w[index - 15].rotateRight(18) ^ (w[index - 15] >> 3)
        let s1 = w[index - 2].rotateRight(17) ^ w[index - 2].rotateRight(19) ^ (w[index - 2] >> 10)
        w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
      }

      var a = h[0], b = h[1], c = h[2], d = h[3]
      var e = h[4], f = h[5], g = h[6], hh = h[7]

      for index in 0..<64 {
        let s1 = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
        let ch = (e & f) ^ (~e & g)
        let temp1 = hh &+ s1 &+ ch &+ k[index] &+ w[index]
        let s0 = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = s0 &+ maj

        hh = g; g = f; f = e; e = d &+ temp1
        d = c; c = b; b = a; a = temp1 &+ temp2
      }

      h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
      h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }

    var digest = [UInt8]()
    digest.reserveCapacity(32)
    for word in h {
      digest.append(UInt8((word >> 24) & 0xff))
      digest.append(UInt8((word >> 16) & 0xff))
      digest.append(UInt8((word >> 8) & 0xff))
      digest.append(UInt8(word & 0xff))
    }
    return digest
  }

  static func hash(_ data: Data) -> [UInt8] {
    hash([UInt8](data))
  }

  static func hexDigest(_ data: Data) -> String {
    hash(data).map { String(format: "%02x", $0) }.joined()
  }
}

enum HMACSHA256 {
  private static let blockSize = 64

  static func sign(key: [UInt8], message: [UInt8]) -> [UInt8] {
    var blockKey = key
    if blockKey.count > blockSize {
      blockKey = SHA256.hash(blockKey)
    }
    if blockKey.count < blockSize {
      blockKey += [UInt8](repeating: 0, count: blockSize - blockKey.count)
    }

    let outer = blockKey.map { $0 ^ 0x5c }
    let inner = blockKey.map { $0 ^ 0x36 }
    return SHA256.hash(outer + SHA256.hash(inner + message))
  }

  static func sign(key: String, message: String) -> [UInt8] {
    sign(key: [UInt8](key.utf8), message: [UInt8](message.utf8))
  }

  static func hexSign(key: [UInt8], message: [UInt8]) -> String {
    sign(key: key, message: message).map { String(format: "%02x", $0) }.joined()
  }
}

private extension UInt32 {
  func rotateRight(_ amount: UInt32) -> UInt32 {
    (self >> amount) | (self << (32 - amount))
  }
}
