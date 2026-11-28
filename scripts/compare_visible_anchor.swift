// Read a screenshot and source anchor from stdin; return only aggregate
// comparisons. Neither the recognized text nor the image is written to disk.
import Foundation
import Vision
import ImageIO

func finish(_ value: [String: Any], _ status: Int32 = 0) -> Never {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text) }
    exit(status)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard input.count <= 16_000_000,
      let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
      let encoded = obj["image"] as? String,
      let image = Data(base64Encoded: encoded), image.count <= 10_000_000,
      let anchors = obj["anchors"] as? [String], (1...3).contains(anchors.count),
      anchors.allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
      let source = CGImageSourceCreateWithData(image as CFData, nil),
      let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    finish(["result": "INVALID"], 1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
request.usesLanguageCorrection = false
do {
    try VNImageRequestHandler(cgImage: picture, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    func normalize(_ value: String) -> String {
        return String(value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }
    let all = normalize(lines.joined())
    let matches = anchors.map { anchor -> [String: Any] in
        let chars = Array(normalize(anchor))
        var matchingWindows = 0
        if chars.count >= 8 {
            for start in stride(from: 0, through: chars.count - 8, by: 4) {
                if all.contains(String(chars[start..<(start + 8)])) { matchingWindows += 1 }
            }
        }
        return ["exact": !chars.isEmpty && all.contains(String(chars)), "windows": matchingWindows]
    }
    finish(["result": "OK", "recognized_lines": lines.count, "matches": matches])
} catch {
    finish(["result": "UNAVAILABLE"], 1)
}
