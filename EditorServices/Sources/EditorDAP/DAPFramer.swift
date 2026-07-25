import Foundation

public struct DAPFramer: Sendable {
    private var buffer = Data()
    public let maxHeaderBytes: Int
    public let maxContentBytes: Int
    private static let separator = Data("\r\n\r\n".utf8)

    public init(maxHeaderBytes: Int = 64 * 1024, maxContentBytes: Int = 16 * 1024 * 1024) {
        self.maxHeaderBytes = max(0, maxHeaderBytes)
        self.maxContentBytes = max(0, maxContentBytes)
    }

    public static func frame(_ payload: Data) -> Data {
        Data("Content-Length: \(payload.count)\r\n\r\n".utf8) + payload
    }

    public static func frame<T: Encodable>(_ message: T, encoder: JSONEncoder = JSONEncoder()) throws -> Data {
        frame(try encoder.encode(message))
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        if buffer.count > maxHeaderBytes + maxContentBytes - min(data.count, maxHeaderBytes + maxContentBytes) {
            throw DAPError.messageTooLarge
        }
        buffer.append(data)
        var messages: [Data] = []

        while true {
            guard let separatorRange = buffer.range(of: Self.separator) else {
                if buffer.count > maxHeaderBytes { throw DAPError.headerTooLarge }
                break
            }
            guard separatorRange.lowerBound <= maxHeaderBytes else { throw DAPError.headerTooLarge }
            guard let header = String(data: buffer[..<separatorRange.lowerBound], encoding: .utf8) else {
                throw DAPError.malformedHeader
            }

            var contentLengths: [Int] = []
            for line in header.components(separatedBy: "\r\n") where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":") else { throw DAPError.malformedHeader }
                let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                    guard let count = Int(value), count >= 0 else { throw DAPError.invalidContentLength }
                    contentLengths.append(count)
                }
            }
            guard let length = contentLengths.first, contentLengths.allSatisfy({ $0 == length }) else {
                throw DAPError.invalidContentLength
            }
            guard length <= maxContentBytes else { throw DAPError.messageTooLarge }
            let bodyStart = separatorRange.upperBound
            let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(length)
            guard !overflow else { throw DAPError.messageTooLarge }
            guard buffer.count >= bodyEnd else { break }
            messages.append(buffer.subdata(in: bodyStart..<bodyEnd))
            buffer.removeSubrange(0..<bodyEnd)
        }
        return messages
    }
}
