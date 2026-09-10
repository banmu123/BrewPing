package com.brewping.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * 命令接收器单元测试（此前无任何覆盖）。
 */
class CommandReceiverTest {

    // TC-CR-01  正常接收：写入 StateFlow 并回调
    @Test
    fun `receive stores text and invokes callback`() {
        val receiver = CommandReceiver()
        var received: String? = null
        receiver.onCommand = { received = it }

        receiver.receive("hello brewping")

        assertEquals("hello brewping", receiver.lastCommandText.value)
        assertEquals("hello brewping", received)
    }

    // TC-CR-02  首尾空白必须裁剪后再派发
    @Test
    fun `receive trims whitespace`() {
        val receiver = CommandReceiver()
        receiver.receive("   spaced   ")
        assertEquals("spaced", receiver.lastCommandText.value)
    }

    // TC-CR-03  边界：空串与纯空白不得触发回调、不得写状态
    @Test
    fun `blank input is ignored`() {
        val receiver = CommandReceiver()
        var callCount = 0
        receiver.onCommand = { callCount++ }

        receiver.receive("")
        receiver.receive("   ")
        receiver.receive("\n\t ")

        assertEquals(0, callCount)
        assertNull(receiver.lastCommandText.value)
    }

    // TC-CR-04  边界：未注册回调时接收命令不得抛异常
    @Test
    fun `receive without listener does not crash`() {
        val receiver = CommandReceiver()
        receiver.receive("no listener")
        assertEquals("no listener", receiver.lastCommandText.value)
    }

    // TC-CR-05  连续接收按顺序覆盖，回调次数与有效命令数一致
    @Test
    fun `sequential commands invoke callback once each`() {
        val receiver = CommandReceiver()
        val seen = mutableListOf<String>()
        receiver.onCommand = { seen.add(it) }

        receiver.receive("one")
        receiver.receive("")
        receiver.receive("two")

        assertEquals(listOf("one", "two"), seen)
        assertEquals("two", receiver.lastCommandText.value)
    }
}
