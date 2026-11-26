#if DEBUG || SIDELOAD
    import Foundation

    struct SwiptClient {
        struct StatusError: LocalizedError {
            static let unauthenticated = 16

            let code: Int
            let message: String

            var errorDescription: String? {
                message
            }
        }

        let server: URL
        let token: String?

        func checkConnection() async throws {
            try await call("swipt.SystemService/GetInfo", Data())
        }

        func enableJIT(bundleID: String, pid: UInt64) async throws {
            var message = Data()
            let field = Data(bundleID.utf8)
            message.append(0x0A)
            Self.appendVarint(UInt64(field.count), to: &message)
            message.append(field)
            message.append(0x10)
            Self.appendVarint(pid, to: &message)
            try await call("swipt.DeviceService/EnableJIT", message)
        }

        private static func appendVarint(_ value: UInt64, to data: inout Data) {
            var value = value
            while value >= 0x80 {
                data.append(UInt8(value & 0x7F | 0x80))
                value >>= 7
            }
            data.append(UInt8(value))
        }

        private func call(_ method: String, _ message: Data) async throws {
            var request = URLRequest(url: server.appending(path: method), timeoutInterval: 8)
            request.httpMethod = "POST"
            request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
            if let token {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            var body = Data([0])
            withUnsafeBytes(of: UInt32(message.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(message)
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let http = response as! HTTPURLResponse
            var status = http.value(forHTTPHeaderField: "grpc-status")
            var statusMessage = http.value(forHTTPHeaderField: "grpc-message")
            var offset = data.startIndex
            while offset + 5 <= data.endIndex {
                let flags = data[offset]
                let length = data[offset + 1 ..< offset + 5].reduce(0) { $0 << 8 | Int($1) }
                guard offset + 5 + length <= data.endIndex else {
                    throw URLError(.badServerResponse)
                }
                let payload = data[offset + 5 ..< offset + 5 + length]
                offset += 5 + length
                guard flags & 0x80 != 0 else { continue }
                for line in String(decoding: payload, as: UTF8.self).split(separator: "\r\n") {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    switch line[..<colon].lowercased() {
                    case "grpc-status": status = value
                    case "grpc-message": statusMessage = value
                    default: break
                    }
                }
            }
            guard let status, let code = Int(status) else {
                guard http.statusCode != 200 else {
                    throw URLError(.badServerResponse)
                }
                throw StatusError(code: 2, message: HTTPURLResponse.localizedString(forStatusCode: http.statusCode))
            }
            guard code == 0 else {
                throw StatusError(code: code, message: statusMessage?.removingPercentEncoding ?? statusMessage ?? "")
            }
        }
    }
#endif
