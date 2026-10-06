// Verifies a Sparkle EdDSA signature against a public key, the way the installed app will.
// Usage: swift scripts/verify-ed-signature.swift <public key base64> <signature base64> <file>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let keyData = Data(base64Encoded: args[1]),
      let signature = Data(base64Encoded: args[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      let file = try? Data(contentsOf: URL(fileURLWithPath: args[3])) else {
    FileHandle.standardError.write(Data("usage: verify-ed-signature <public key> <signature> <file>\n".utf8))
    exit(2)
}
if key.isValidSignature(signature, for: file) {
    print("EdDSA signature matches the app's public key")
} else {
    FileHandle.standardError.write(Data("EdDSA signature does NOT match the app's public key\n".utf8))
    exit(1)
}
