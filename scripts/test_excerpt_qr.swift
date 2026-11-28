// Decode synthetic KOReader screenshots with the macOS built-in QR detector.
// Usage: swift scripts/test_excerpt_qr.swift <screenshot.png> [more.png ...]
import Foundation
import CoreImage

guard CommandLine.arguments.count > 1,
      let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
    fputs("Expected one or more synthetic screenshots and a QR detector.\n", stderr)
    exit(1)
}
for path in CommandLine.arguments.dropFirst() {
    guard let image = CIImage(contentsOf: URL(fileURLWithPath: path)),
          let qr = detector.features(in: image).compactMap({ $0 as? CIQRCodeFeature }).first,
          let text = qr.messageString,
          text.range(of: #"^http://127\.0\.0\.1:[0-9]+/[0-9a-f]{32}/$"#, options: .regularExpression) != nil else {
        fputs("Synthetic QR could not be decoded.\n", stderr)
        exit(1)
    }
    print("Synthetic QR decoded.")
}
