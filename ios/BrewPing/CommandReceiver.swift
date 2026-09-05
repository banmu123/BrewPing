import Foundation
import Combine

enum MessageType {
    case status
    case command

    static func from(_ raw: String?) -> MessageType {
        raw == "command" ? .command : .status
    }
}

final class CommandReceiver: ObservableObject {
    static let shared = CommandReceiver()

    @Published var lastCommandText: String?
    @Published var lastCommandReceivedAt: Date?
    @Published var lastCommandStatus: String = "received"
    @Published var lastCommandID = UUID()

    /// 接入点：下一阶段把 command 转发给 Mac Agent（CommandRouter.submit）时挂在这里。
    var onCommand: ((String) -> Void)?

    private init() {}

    func receive(type: MessageType, text: String) {
        print("CommandReceiver: received \(type) text=\(text)")
        guard type == .command, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async {
            self.lastCommandText = text
            self.lastCommandReceivedAt = Date()
            self.lastCommandStatus = "received"
            self.lastCommandID = UUID()
            print("CommandReceiver: command stored: \(text) at \(self.lastCommandReceivedAt ?? Date())")
            self.onCommand?(text)
        }
    }
}
