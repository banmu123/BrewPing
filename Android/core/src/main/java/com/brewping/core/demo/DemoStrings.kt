package com.brewping.core.demo

/**
 * Demo 后端需要本地化的文案。
 *
 * 为什么用注入而不是让 `:core` 直接持有资源：`:core` 是手机端与手表端共用的**纯逻辑库**
 * （见模块约定「UI 组件一律不得进入本模块」），文案属于各端的资源层。
 * 因此由消费方（`:app`）从自己的 `strings.xml` 构造后注入 —— 这样 Demo 文案同样跟随
 * 应用内语言切换（system / zh / en），与 iOS 把 Demo 文案放进 `Localizable.strings` 等价。
 */
data class DemoStrings(
    /** 状态页显示的「主机名」，Demo 里明确标注是模拟的。 */
    val hostLabel: String,
    /** 命令成功时的回复模板，参数：%1$s = 用户输入的命令。 */
    val commandResponse: String,
    /** 命令失败时的错误文案（由含 "fail" 的命令触发）。 */
    val commandFailed: String,
    /** 内置对话①的标题（已绑定工作目录）。 */
    val conversationTitleBound: String,
    /** 内置对话②的标题（未绑定工作目录）。 */
    val conversationTitleUnbound: String,
    /** 对话①的 system 转录行。 */
    val systemPromptBound: String,
    /** 对话②的 system 转录行。 */
    val systemPromptUnbound: String,
    /** 对话①的 assistant 回复。 */
    val replyBound: String,
    /** 对话②的 assistant 回复。 */
    val replyUnbound: String,
)
