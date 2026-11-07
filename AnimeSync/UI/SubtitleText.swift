import Foundation

struct SubtitleCue: Equatable {
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}
enum SubtitleText {
    static func time(_ raw: String) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 2 || parts.count == 3, let seconds = Double(parts.last!), seconds >= 0, seconds < 60,
              let minutes = Double(parts[parts.count - 2]), minutes >= 0, minutes < 60 else { return nil }
        let hours = parts.count == 3 ? Double(parts[0]) : 0
        guard let h = hours, h >= 0, h < 168 else { return nil }
        return h * 3600 + minutes * 60 + seconds
    }
    static func plain(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: " ")
        text = text.replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        for (a,b) in [("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'"),("&nbsp;"," ")] { text = text.replacingOccurrences(of: a, with: b) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func parse(_ source: String, extension ext: String) -> [SubtitleCue] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var cues: [SubtitleCue] = []
        if ["ass", "ssa"].contains(ext.lowercased()) {
            var fields = ["layer","start","end","style","name","marginl","marginr","marginv","effect","text"]
            var events = false
            for line in lines {
                if line.hasPrefix("[") { events = line.lowercased() == "[events]"; continue }
                guard events else { continue }
                if line.lowercased().hasPrefix("format:") { fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }; continue }
                guard line.lowercased().hasPrefix("dialogue:"), let startIndex = fields.firstIndex(of: "start"), let endIndex = fields.firstIndex(of: "end"), let textIndex = fields.firstIndex(of: "text") else { continue }
                let values = line.dropFirst(9).split(separator: ",", maxSplits: max(0, fields.count - 1), omittingEmptySubsequences: false).map(String.init)
                guard values.count == fields.count, let start = time(values[startIndex]), let end = time(values[endIndex]), end > start else { continue }
                let text = plain(values[textIndex]); if !text.isEmpty { cues.append(SubtitleCue(start: start,end: end,text: text)) }
                if cues.count >= 30_000 { break }
            }
        } else {
            var index = 0
            while index < lines.count && cues.count < 30_000 {
                let line = lines[index]; index += 1
                guard line.contains("-->") else { continue }
                let timing = line.components(separatedBy: "-->")
                guard timing.count == 2, let start = time(timing[0]), let token = timing[1].split(whereSeparator: { $0.isWhitespace }).first, let end = time(String(token)), end > start else { continue }
                var text: [String] = []
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).isEmpty { text.append(lines[index]); index += 1 }
                let plainText = plain(text.joined(separator: "\n")); if !plainText.isEmpty { cues.append(SubtitleCue(start: start,end: end,text: plainText)) }
            }
        }
        return cues.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
    static func active(_ cues: [SubtitleCue], at position: TimeInterval) -> String {
        guard position.isFinite, !cues.isEmpty else { return "" }
        var low = 0, high = cues.count
        while low < high { let mid = (low + high) / 2; if cues[mid].start <= position { low = mid + 1 } else { high = mid } }
        return cues[max(0,low - 100)..<low].filter { position >= $0.start && position < $0.end }.suffix(5).map(\.text).joined(separator: "\n")
    }
}
