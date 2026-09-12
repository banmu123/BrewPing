package com.brewping.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.brewping.android.ui.theme.LatteMuted
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant

// ─── 轻量 Markdown 渲染（零依赖，对齐 iOS inline-only 观感）───────────────────
//
// iOS 用 AttributedString(markdown:, inlineOnlyPreservingWhitespace)。
// Android 无内置等价物且不引第三方库 —— 这里实现常用子集：
//   标题（#..####）、无序列表（- / *）、引用（>）、代码围栏（```）、
//   行内 **加粗** 与 `代码`。解析失败/半截内容原样显示，绝不 crash。

@Composable
fun MarkdownText(text: String, modifier: Modifier = Modifier) {
    val blocks = remember(text) { splitBlocks(text) }
    Column(modifier = modifier.fillMaxWidth()) {
        blocks.forEach { block ->
            when (block) {
                is MdBlock.Code -> Surface(
                    shape = RoundedCornerShape(8.dp),
                    color = LatteMuted,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                ) {
                    Text(
                        text = block.content,
                        fontFamily = FontFamily.Monospace,
                        fontSize = 12.5.sp,
                        lineHeight = 18.sp,
                        color = LatteOnSurface,
                        modifier = Modifier.padding(10.dp),
                    )
                }
                is MdBlock.Heading -> Text(
                    text = inlineMarkdown(block.content),
                    fontSize = 17.sp,
                    lineHeight = 24.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = LatteOnSurface,
                    modifier = Modifier.padding(top = 6.dp, bottom = 2.dp),
                )
                is MdBlock.Bullet -> Row(modifier = Modifier.padding(vertical = 1.dp)) {
                    Text(
                        text = "•  ",
                        fontSize = 15.sp,
                        color = LatteOnSurfaceVariant,
                    )
                    Text(
                        text = inlineMarkdown(block.content),
                        fontSize = 15.sp,
                        lineHeight = 22.sp,
                        color = LatteOnSurface,
                    )
                }
                is MdBlock.Quote -> Surface(
                    color = Color.Transparent,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(vertical = 2.dp),
                ) {
                    Text(
                        text = inlineMarkdown(block.content),
                        fontSize = 14.sp,
                        lineHeight = 20.sp,
                        color = LatteOnSurfaceVariant,
                        modifier = Modifier
                            .background(LatteMuted, RoundedCornerShape(4.dp))
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
                is MdBlock.Paragraph -> Text(
                    text = inlineMarkdown(block.content),
                    fontSize = 15.sp,
                    lineHeight = 22.sp,
                    color = LatteOnSurface,
                    modifier = Modifier.padding(vertical = 2.dp),
                )
            }
        }
    }
}

private sealed interface MdBlock {
    data class Paragraph(val content: String) : MdBlock
    data class Heading(val content: String) : MdBlock
    data class Bullet(val content: String) : MdBlock
    data class Quote(val content: String) : MdBlock
    data class Code(val content: String) : MdBlock
}

private fun splitBlocks(text: String): List<MdBlock> {
    val blocks = mutableListOf<MdBlock>()
    var paragraph = mutableListOf<String>()
    var codeLines = mutableListOf<String>()
    var inCode = false

    fun flushParagraph() {
        if (paragraph.isNotEmpty()) {
            blocks.add(MdBlock.Paragraph(paragraph.joinToString("\n")))
            paragraph = mutableListOf()
        }
    }

    for (rawLine in text.lines()) {
        val line = rawLine.trimEnd()
        if (line.trimStart().startsWith("```")) {
            if (inCode) {
                blocks.add(MdBlock.Code(codeLines.joinToString("\n")))
                codeLines = mutableListOf()
                inCode = false
            } else {
                flushParagraph()
                inCode = true
            }
            continue
        }
        if (inCode) {
            codeLines.add(rawLine)
            continue
        }
        val trimmed = line.trim()
        when {
            trimmed.isEmpty() -> flushParagraph()
            trimmed.startsWith("#") -> {
                flushParagraph()
                blocks.add(MdBlock.Heading(trimmed.trimStart('#').trim()))
            }
            trimmed.startsWith("- ") || trimmed.startsWith("* ") -> {
                flushParagraph()
                blocks.add(MdBlock.Bullet(trimmed.substring(2).trim()))
            }
            trimmed.startsWith("> ") -> {
                flushParagraph()
                blocks.add(MdBlock.Quote(trimmed.substring(2).trim()))
            }
            else -> paragraph.add(line)
        }
    }
    if (inCode && codeLines.isNotEmpty()) blocks.add(MdBlock.Code(codeLines.joinToString("\n")))
    flushParagraph()
    return blocks
}

/** 行内 `**加粗**` 与 `` `代码` `` —— 解析不出就原样返回，绝不抛异常。 */
private fun inlineMarkdown(text: String): AnnotatedString = buildAnnotatedString {
    var i = 0
    while (i < text.length) {
        when {
            text.startsWith("**", i) -> {
                val end = text.indexOf("**", i + 2)
                if (end > i + 1) {
                    pushStyle(SpanStyle(fontWeight = FontWeight.SemiBold))
                    append(text.substring(i + 2, end))
                    pop()
                    i = end + 2
                } else {
                    append(text[i]); i++
                }
            }
            text[i] == '`' -> {
                val end = text.indexOf('`', i + 1)
                if (end > i) {
                    pushStyle(SpanStyle(fontFamily = FontFamily.Monospace, background = LatteMuted))
                    append(text.substring(i + 1, end))
                    pop()
                    i = end + 1
                } else {
                    append(text[i]); i++
                }
            }
            else -> {
                append(text[i]); i++
            }
        }
    }
}
