import SwiftUI

/// 危险命令确认窗。
///
/// 在 Mac 端授权门卫挂起一条命令后弹出，让用户在手机上决定是否放行。
/// 三档决定：允许一次 / 总是允许此类型 / 拒绝。
/// 用户命令正文属用户内容，展示用 `Text` 但命令本身经 `privacy: .private` 记日志。
struct ApprovalRequestView: View {
    let approval: PendingApprovalInfo
    let decide: (String) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Label("This command needs your approval", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                commandCard

                reasonsCard

                Spacer()

                buttons
            }
            .padding(16)
            .navigationTitle("Approval Required")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var commandCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption)
                .foregroundStyle(Color.bpMutedForeground)
            Text(approval.text ?? "")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color.bpForeground)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.bpCard)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.bpBorder, lineWidth: 1)
                )
        }
    }

    private var reasonsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Reason")
                .font(.caption)
                .foregroundStyle(Color.bpMutedForeground)
            ForEach(approval.localizedReasons(), id: \.self) { reason in
                Label(reason, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(Color.bpDestructive)
            }
        }
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button {
                decide("approve")
            } label: {
                Text("Approve Once")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                decide("always_approve")
            } label: {
                Text("Always Allow This Type")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                decide("deny")
            } label: {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}
