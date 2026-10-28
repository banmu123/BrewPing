import XCTest
import Darwin
@testable import BrewPingCore

// ─── HTTP 请求解析加固的回归测试 ─────────────────────────────────────────────
//
// 两层：
//  1. `HTTPServer.parseHead` 的纯函数断言 —— 覆盖长度头/请求行/头的各种畸形输入；
//  2. 真起一个 `HTTPServer` 监听 127.0.0.1，用裸 socket 发字节 —— 覆盖
//     「头与体同包到达」「体分多次到达」「负数长度不再让进程崩」这些只有走真实
//     读取路径才成立的行为。
//
// 二层测试故意发送会让旧实现 `Data.prefix(-1)` 崩溃的请求：修好之前进程会直接
// 挂掉，测试套件连带失败 —— 这正是回归测试要守住的东西。

final class HTTPParsingTests: XCTestCase {

    // MARK: - parseHead：正常请求

    func testParseNormalGET() {
        let parsed = parse([
            "GET /api/status HTTP/1.1",
            "Host: 127.0.0.1:8787",
            "Accept: */*"
        ])
        XCTAssertEqual(parsed?.method, "GET")
        XCTAssertEqual(parsed?.path, "/api/status")
        XCTAssertNil(parsed?.query)
        XCTAssertEqual(parsed?.contentLength, 0)
        XCTAssertEqual(parsed?.headers["host"], "127.0.0.1:8787")
    }

    func testParseNormalPOSTWithBody() {
        let parsed = parse([
            "POST /api/message HTTP/1.1",
            "Content-Type: application/json",
            "Content-Length: 42"
        ])
        XCTAssertEqual(parsed?.method, "POST")
        XCTAssertEqual(parsed?.path, "/api/message")
        XCTAssertEqual(parsed?.contentLength, 42)
    }

    func testParseSplitsQueryAndKeepsHeaderNamesLowercased() {
        let parsed = parse([
            "GET /api/folders?path=%2FUsers%2Fme&depth=2 HTTP/1.1",
            "X-BrewPing-Timestamp: 1700000000"
        ])
        XCTAssertEqual(parsed?.path, "/api/folders")
        XCTAssertEqual(parsed?.query, "path=%2FUsers%2Fme&depth=2")
        // 头名大小写不敏感：取值一律用小写 key
        XCTAssertEqual(parsed?.headers["x-brewping-timestamp"], "1700000000")
    }

    func testParseAcceptsHTTP10() {
        XCTAssertEqual(parse(["GET /api/status HTTP/1.0"])?.path, "/api/status")
    }

    // MARK: - Content-Length：负数 / 非法 / 溢出 / 超限

    func testParseRejectsNegativeContentLength() {
        // 旧实现：`Int("-1") ?? 0` → 通过校验 → `Data.prefix(-1)` → 运行时崩溃
        XCTAssertEqual(failure(["POST /api/message HTTP/1.1", "Content-Length: -1"]), .invalidContentLength)
    }

    func testParseRejectsNonNumericContentLength() {
        for value in ["abc", "1.5", "0x10", "+5", "1 0", ""] {
            XCTAssertEqual(
                failure(["POST /api/message HTTP/1.1", "Content-Length: \(value)"]),
                .invalidContentLength,
                "Content-Length: '\(value)' 应被拒绝，而不是静默变成 0"
            )
        }
    }

    func testParseRejectsOverflowingContentLength() {
        // 20 位数字远超 Int，旧实现 `Int(value) ?? 0` 会静默变成「无请求体」
        XCTAssertEqual(
            failure(["POST /api/message HTTP/1.1", "Content-Length: 99999999999999999999"]),
            .payloadTooLarge
        )
    }

    func testParseRejectsContentLengthAboveLimit() {
        XCTAssertEqual(
            failure(["POST /api/message HTTP/1.1", "Content-Length: \(HTTPServer.maxBodyBytes + 1)"]),
            .payloadTooLarge
        )
    }

    func testParseAcceptsContentLengthAtLimit() {
        XCTAssertEqual(
            parse(["POST /api/message HTTP/1.1", "Content-Length: \(HTTPServer.maxBodyBytes)"])?.contentLength,
            HTTPServer.maxBodyBytes
        )
    }

    // MARK: - Content-Length：重复

    func testParseRejectsDuplicateIdenticalContentLength() {
        // 即使两个值一致也拒绝：策略必须是单一的，不能依赖「谁能赢」的解释
        XCTAssertEqual(
            failure([
                "POST /api/message HTTP/1.1",
                "Content-Length: 5",
                "Content-Length: 5"
            ]),
            .duplicateContentLength
        )
    }

    func testParseRejectsDuplicateConflictingContentLength() {
        XCTAssertEqual(
            failure([
                "POST /api/message HTTP/1.1",
                "Content-Length: 5",
                "Content-Length: 6"
            ]),
            .duplicateContentLength
        )
    }

    func testParseRejectsDuplicateContentLengthAcrossCase() {
        XCTAssertEqual(
            failure([
                "POST /api/message HTTP/1.1",
                "content-length: 5",
                "Content-Length: 5"
            ]),
            .duplicateContentLength
        )
    }

    // MARK: - Transfer-Encoding

    func testParseRejectsChunkedTransferEncoding() {
        XCTAssertEqual(
            failure([
                "POST /api/message HTTP/1.1",
                "Transfer-Encoding: chunked"
            ]),
            .unsupportedTransferEncoding
        )
    }

    func testParseRejectsTransferEncodingEvenWithContentLength() {
        // 同时出现时以 Transfer-Encoding 为准：绝不能让请求退化成按 CL 读
        XCTAssertEqual(
            failure([
                "POST /api/message HTTP/1.1",
                "Content-Length: 5",
                "Transfer-Encoding: chunked"
            ]),
            .unsupportedTransferEncoding
        )
    }

    func testParseRejectsAnyTransferEncodingValue() {
        XCTAssertEqual(
            failure(["POST /api/message HTTP/1.1", "Transfer-Encoding: identity"]),
            .unsupportedTransferEncoding
        )
    }

    // MARK: - 请求行 / 头格式

    func testParseRejectsBadRequestLines() {
        for line in [
            "",
            "GET",
            "GET /api/status",
            "GET /api/status HTTP/2.0",
            "GET /api/status HTTP/1.1 extra",
            "GET api/status HTTP/1.1",      // 必须是 origin-form，以 / 开头
            "GE T /api/status HTTP/1.1"
        ] {
            XCTAssertEqual(failure([line]), .malformed, "请求行 '\(line)' 应被拒绝")
        }
    }

    func testParseRejectsHeaderWithoutColon() {
        XCTAssertEqual(
            failure(["GET /api/status HTTP/1.1", "ThisIsNotAHeader"]),
            .malformed
        )
    }

    func testParseRejectsHeaderNameWithSpace() {
        XCTAssertEqual(
            failure(["POST /api/message HTTP/1.1", "Content Length: 5"]),
            .malformed
        )
    }

    func testParseRejectsObsoleteLineFolding() {
        XCTAssertEqual(
            failure(["GET /api/status HTTP/1.1", "X-Long: part1", " part2"]),
            .malformed
        )
    }

    func testParseRejectsControlCharactersInHeaderValue() {
        XCTAssertEqual(
            failure(["GET /api/status HTTP/1.1", "X-Test: a\u{0}b"]),
            .malformed
        )
    }

    func testParseRejectsOversizedHead() {
        let padding = String(repeating: "a", count: HTTPServer.maxHeadBytes + 16)
        XCTAssertEqual(
            failure(["GET /api/status HTTP/1.1", "X-Pad: \(padding)"]),
            .headerTooLarge
        )
    }

    // MARK: - 端到端：真实监听 + 裸 socket

    func testEndToEndNormalGET() throws {
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let raw = RawHTTP.exchange(port: port, payloads: [Data("GET /api/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)])
            XCTAssertEqual(RawHTTP.status(of: raw), 200)
            XCTAssertTrue(raw.contains("\"success\":true"))
        }
    }

    func testEndToEndNormalPOSTWithBodyInSamePacket() throws {
        let seen = LockedBox<String>("")
        try withServer({ request in
            let text = String(data: request.body, encoding: .utf8) ?? ""
            seen.with { $0 = text }
            return .json(200, "OK", ["echo": text])
        }) { port in
            let payload = Data("POST /api/message HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world".utf8)
            let raw = RawHTTP.exchange(port: port, payloads: [payload])
            XCTAssertEqual(RawHTTP.status(of: raw), 200)
            XCTAssertEqual(seen.value, "hello world")
        }
    }

    func testEndToEndBodySplitAcrossPackets() throws {
        try withServer({ request in
            .json(200, "OK", ["echo": String(data: request.body, encoding: .utf8) ?? ""])
        }) { port in
            let raw = RawHTTP.exchange(port: port, payloads: [
                Data("POST /api/message HTTP/1.1\r\nContent-Length: 11\r\n\r\n".utf8),
                Data("hello ".utf8),
                Data("world".utf8)
            ], gap: 0.05)
            XCTAssertEqual(RawHTTP.status(of: raw), 200)
            XCTAssertTrue(raw.contains("hello world"))
        }
    }

    func testEndToEndTruncatesBodyBeyondDeclaredLength() throws {
        // 声明 5 字节却发了 11 字节：只取前 5 字节，其余丢弃（连接随即关闭）
        try withServer({ request in
            .json(200, "OK", ["count": request.body.count, "echo": String(data: request.body, encoding: .utf8) ?? ""])
        }) { port in
            let payload = Data("POST /api/message HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello world".utf8)
            let raw = RawHTTP.exchange(port: port, payloads: [payload])
            XCTAssertEqual(RawHTTP.status(of: raw), 200)
            XCTAssertTrue(raw.contains("\"count\":5"))
            XCTAssertTrue(raw.contains("hello"))
        }
    }

    func testEndToEndRejectsNegativeContentLengthWithoutCrashing() throws {
        // 旧实现在这里 `prefix(-1)` 触发运行时陷阱 → 整个进程（含桌面端）退出
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let raw = RawHTTP.exchange(port: port, payloads: [
                Data("POST /api/message HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
            ])
            XCTAssertEqual(RawHTTP.status(of: raw), 400)
        }
    }

    func testEndToEndRejectsOverflowingContentLength() throws {
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let raw = RawHTTP.exchange(port: port, payloads: [
                Data("POST /api/message HTTP/1.1\r\nContent-Length: 99999999999999999999\r\n\r\n".utf8)
            ])
            XCTAssertEqual(RawHTTP.status(of: raw), 413)
        }
    }

    func testEndToEndRejectsOversizedBodyBeforeReadingIt() throws {
        // 只发头，不发 8MB+1 的体：校验必须在读取请求体之前完成
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let head = "POST /api/message HTTP/1.1\r\nContent-Length: \(HTTPServer.maxBodyBytes + 1)\r\n\r\n"
            let raw = RawHTTP.exchange(port: port, payloads: [Data(head.utf8)])
            XCTAssertEqual(RawHTTP.status(of: raw), 413)
        }
    }

    func testEndToEndRejectsDuplicateConflictingContentLength() throws {
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let head = "POST /api/message HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello"
            let raw = RawHTTP.exchange(port: port, payloads: [Data(head.utf8)])
            XCTAssertEqual(RawHTTP.status(of: raw), 400)
        }
    }

    func testEndToEndRejectsChunkedTransferEncoding() throws {
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let head = "POST /api/message HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n"
            let raw = RawHTTP.exchange(port: port, payloads: [Data(head.utf8)])
            XCTAssertEqual(RawHTTP.status(of: raw), 400)
        }
    }

    func testEndToEndRejectsOversizedHeadWith431() throws {
        let padding = String(repeating: "a", count: HTTPServer.maxHeadBytes + 32)
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let head = "GET /api/status HTTP/1.1\r\nX-Pad: \(padding)\r\n\r\n"
            let raw = RawHTTP.exchange(port: port, payloads: [Data(head.utf8)], timeout: 10)
            XCTAssertEqual(RawHTTP.status(of: raw), 431)
        }
    }

    func testEndToEndRejectsGarbageAndKeepsServing() throws {
        try withServer({ _ in .json(200, "OK", ["success": true]) }) { port in
            let garbage = RawHTTP.exchange(port: port, payloads: [Data([0x16, 0x03, 0x01, 0x00, 0x50])])
            XCTAssertTrue(garbage.isEmpty || RawHTTP.status(of: garbage) == 400)

            // 同一进程仍然能正常服务下一个请求
            let ok = RawHTTP.exchange(port: port, payloads: [
                Data("GET /api/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            ])
            XCTAssertEqual(RawHTTP.status(of: ok), 200)
        }
    }

    func testEndToEndAcceptsTypicalURLSessionRequest() throws {
        // URLSession / OkHttp 实际会带上的头：Connection、Accept-Encoding、
        // 带分号与括号的 User-Agent —— 解析器必须照常放行，兼容性不能靠猜。
        let body = "{\"text\":\"hi\"}"
        let lines = [
            "POST /api/message HTTP/1.1",
            "Host: 192.168.1.10:8787",
            "Accept: */*",
            "Accept-Encoding: gzip, deflate",
            "Accept-Language: zh-Hans-CN;q=1.0",
            "Content-Type: application/json",
            "Content-Length: \(body.utf8.count)",
            "Connection: keep-alive",
            "User-Agent: BrewPing/1.0 (iPhone; iOS 17.0)"
        ]
        let seen = LockedBox<String>("")
        try withServer({ request in
            seen.with { $0 = String(data: request.body, encoding: .utf8) ?? "" }
            return .json(200, "OK", ["success": true])
        }) { port in
            let payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8)
            let raw = RawHTTP.exchange(port: port, payloads: [payload])
            XCTAssertEqual(RawHTTP.status(of: raw), 200)
            XCTAssertEqual(seen.value, body)
        }
    }

    func testEndToEndReportsPeerAddress() throws {
        let peer = LockedBox<String?>(nil)
        try withServer({ request in
            peer.with { $0 = request.remoteAddress }
            return .json(200, "OK", ["success": true])
        }) { port in
            _ = RawHTTP.exchange(port: port, payloads: [
                Data("GET /api/status HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
            ])
            // 来源必须是内核给的连接信息，而不是任何请求头
            XCTAssertEqual(peer.value, "127.0.0.1")
        }
    }

    // MARK: - Helpers

    private func parse(_ lines: [String]) -> HTTPServer.ParsedHead? {
        guard case .success(let head) = HTTPServer.parseHead(Data(lines.joined(separator: "\r\n").utf8)) else {
            return nil
        }
        return head
    }

    private func failure(_ lines: [String]) -> HTTPServer.HeadParseFailure? {
        guard case .failure(let failure) = HTTPServer.parseHead(Data(lines.joined(separator: "\r\n").utf8)) else {
            return nil
        }
        return failure
    }

    /// 在 127.0.0.1 的随机端口起一个真实服务，跑完必然停掉。
    private func withServer(
        _ handler: @escaping (HTTPRequest) -> HTTPResponse,
        _ body: (UInt16) throws -> Void
    ) throws {
        var started: (server: HTTPServer, port: UInt16)?
        for _ in 0..<3 {
            let candidate = HTTPServer(
                port: UInt16.random(in: 30_000...58_000),
                lanInterface: nil,
                handler: handler
            )
            if let result = try? candidate.start() {
                started = (candidate, result.port)
                break
            }
        }
        guard let started else {
            throw XCTSkip("无法在随机端口上启动测试用 HTTP 服务")
        }
        defer { started.server.stop() }
        try body(started.port)
    }
}

// MARK: - 测试用工具

/// 极简线程安全盒子：handler 跑在连接队列上，断言在主线程，必须显式同步。
final class LockedBox<T> {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func with(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&storage)
    }
}

/// 裸 TCP 客户端：URLSession 发不出畸形请求，只能自己拼字节。
enum RawHTTP {
    static func exchange(
        port: UInt16,
        payloads: [Data],
        gap: TimeInterval = 0,
        timeout: TimeInterval = 5
    ) -> String {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        // 服务端可能在我们写完之前就关连接 —— 不能让 SIGPIPE 杀掉测试进程
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return "" }

        for (index, payload) in payloads.enumerated() {
            if index > 0, gap > 0 { usleep(useconds_t(gap * 1_000_000)) }
            let bytes = [UInt8](payload)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBufferPointer { buffer in
                    write(fd, buffer.baseAddress, buffer.count)
                }
                if written <= 0 { break }
                offset += written
            }
        }
        shutdown(fd, SHUT_WR)

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
            } else {
                break
            }
        }
        return String(decoding: response, as: UTF8.self)
    }

    static func status(of raw: String) -> Int? {
        guard let line = raw.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    static func header(_ name: String, in raw: String) -> String? {
        guard let headEnd = raw.range(of: "\r\n\r\n") else { return nil }
        let head = String(raw[raw.startIndex..<headEnd.lowerBound])
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            if key == name.lowercased() {
                return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
