import Foundation

enum HTTPAPI {
    static func handle(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/api/status"):
            return statusResponse(router.route(.status))
        case ("POST", "/api/message"):
            return messageResponse(request, router: router)
        case ("GET", "/api/message"):
            return .json(405, "Method Not Allowed", ["success": false, "error": "use POST /api/message or GET /api/message/:id"])
        case let ("GET", path) where path.hasPrefix("/api/message/"):
            let id = String(path.dropFirst("/api/message/".count))
            return commandResponse(id)
        case ("POST", "/api/status"):
            return .json(405, "Method Not Allowed", ["success": false, "error": "use GET /api/status"])
        default:
            return .json(404, "Not Found", ["success": false, "error": "not found"])
        }
    }

    private static func statusResponse(_ resp: AgentResponse) -> HTTPResponse {
        let session: Any = resp.ok
            ? [
                "id": resp.sessionID ?? "",
                "agent": "opencode",
                "status": resp.status ?? "unknown"
            ]
            : NSNull()
        return .json(200, "OK", ["status": "online", "session": session])
    }

    private static func messageResponse(_ request: HTTPRequest, router: CommandRouter) -> HTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: request.body, options: []),
              let body = object as? [String: Any],
              let text = body["text"] as? String else {
            return .json(400, "Bad Request", ["success": false, "error": "expected JSON body {\"text\": \"...\"}"])
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .json(400, "Bad Request", ["success": false, "error": "text is empty"])
        }
        let resp = router.route(.submit(text: text))
        if resp.ok {
            return .json(200, "OK", [
                "success": true,
                "commandId": resp.commandId ?? "",
                "sessionId": resp.sessionID ?? "",
                "status": resp.status ?? CommandStatus.queued.rawValue
            ])
        }
        return .json(409, "Conflict", ["success": false, "error": resp.error ?? "send failed"])
    }

    private static func commandResponse(_ id: String) -> HTTPResponse {
        guard !id.isEmpty, let info = CommandStore.shared.get(id) else {
            return .json(404, "Not Found", ["success": false, "error": "unknown commandId"])
        }
        var object: [String: Any] = [
            "commandId": info.commandId,
            "sessionId": info.sessionId,
            "status": info.status.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: info.createdAt)
        ]
        if let response = info.response { object["response"] = response }
        if let error = info.error { object["error"] = error }
        if let completedAt = info.completedAt {
            object["completedAt"] = ISO8601DateFormatter().string(from: completedAt)
        }
        return .json(200, "OK", object)
    }
}
