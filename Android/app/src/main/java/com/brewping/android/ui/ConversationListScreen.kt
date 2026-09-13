package com.brewping.android.ui

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.PushPin
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.res.stringResource
import com.brewping.android.R
import com.brewping.android.model.ConversationDirGroup
import com.brewping.android.model.ConversationSummary
import com.brewping.android.model.pathLabel
import com.brewping.android.model.timeLabel
import com.brewping.android.store.ConversationStore
import com.brewping.android.ui.theme.BrewMotion
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteDestructive
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LattePrimary
import com.brewping.android.ui.theme.LatteWarning

// ─── 对话列表（连接机器后的主页，对齐 iOS ConversationListView）────────────────
//
// 数据来自桌面端 `GET /api/conversations`：按「绑定的工作目录」分组，
// 每组下是该目录产生的对话。点某条对话 → 进入对话详情（转录 + 输入框）。

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ConversationListScreen(
    store: ConversationStore,
    online: Boolean,
    agentNames: Map<String, String>,
    isRefreshing: Boolean,
    onRefresh: () -> Unit,
    onOpenConversation: (String) -> Unit,
    onNewConversation: () -> Unit,
    /** 置顶 / 归档（对齐桌面端侧栏的同名操作，PATCH /api/conversations/{id}）。 */
    onPinConversation: (id: String, pinned: Boolean) -> Unit = { _, _ -> },
    onArchiveConversation: (id: String) -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val conversations by store.conversations.collectAsState()
    val loadError by store.loadError.collectAsState()
    val unsupported by store.unsupported.collectAsState()
    val dirGroups = store.dirGroups
    // 折叠的目录组（仅视觉折叠，不改变过滤——与 iOS / 桌面端一致）
    var collapsedGroups by remember { mutableStateOf(setOf<String>()) }

    PullToRefreshBox(
        isRefreshing = isRefreshing,
        onRefresh = onRefresh,
        modifier = modifier.fillMaxSize(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
        ) {
            // ─── 新对话入口 ────────────────────────────────────────────────
            item(key = "__new__") {
                Surface(
                    shape = MaterialTheme.shapes.medium,
                    color = LatteCard,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onNewConversation() },
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Edit,
                            contentDescription = null,
                            tint = LattePrimary,
                            modifier = Modifier.size(14.dp),
                        )
                        Spacer(modifier = Modifier.width(10.dp))
                        Text(
                            text = stringResource(R.string.new_conversation),
                            fontSize = 15.sp,
                            fontWeight = FontWeight.Medium,
                            color = LatteOnSurface,
                        )
                    }
                }
            }

            // ─── 加载错误（网络抖动保留旧列表时显示）────────────────────────
            loadError?.let { error ->
                item(key = "__error__") {
                    NoticeRow(icon = Icons.Filled.Warning, iconTint = LatteWarning, text = error)
                }
            }

            when {
                // ─── 老版本桌面端：静默降级提示（不是错误）───────────────────
                unsupported -> {
                    item(key = "__unsupported__") {
                        PlainNotice(text = stringResource(R.string.unsupported_desktop))
                    }
                }
                // ─── 空态 ──────────────────────────────────────────────────
                conversations.isEmpty() -> {
                    item(key = "__empty__") {
                        PlainNotice(text = stringResource(R.string.no_conversations_yet))
                    }
                }
                // ─── 按工作目录分组 ─────────────────────────────────────────
                else -> {
                    dirGroups.forEach { group ->
                        groupSection(
                            group = group,
                            collapsed = group.key in collapsedGroups,
                            onToggle = {
                                collapsedGroups = if (group.key in collapsedGroups) {
                                    collapsedGroups - group.key
                                } else {
                                    collapsedGroups + group.key
                                }
                            },
                            agentNames = agentNames,
                            onOpenConversation = onOpenConversation,
                            onPinConversation = onPinConversation,
                            onArchiveConversation = onArchiveConversation,
                        )
                    }
                }
            }

            if (!online) {
                item(key = "__offline__") {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = stringResource(R.string.offline_last_synced),
                        fontSize = 11.sp,
                        color = LatteOnSurfaceVariant,
                        modifier = Modifier.padding(horizontal = 4.dp),
                    )
                }
            }
        }
    }
}

/** 目录组：组头（点击折叠/展开）+ 组内对话行。LazyListScope 扩展以发出多个 item。 */
private fun androidx.compose.foundation.lazy.LazyListScope.groupSection(
    group: ConversationDirGroup,
    collapsed: Boolean,
    onToggle: () -> Unit,
    agentNames: Map<String, String>,
    onOpenConversation: (String) -> Unit,
    onPinConversation: (id: String, pinned: Boolean) -> Unit,
    onArchiveConversation: (id: String) -> Unit,
) {
    item(key = "header-${group.key}") {
        // 折叠箭头旋转（150ms easeOut，对齐 iOS withAnimation）
        val chevronRotation by animateFloatAsState(
            targetValue = if (collapsed) 0f else 90f,
            animationSpec = tween(BrewMotion.Fast, easing = BrewMotion.FastEasing),
            label = "chevron",
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onToggle() }
                .padding(horizontal = 4.dp, vertical = 8.dp),
        ) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                contentDescription = null,
                tint = LatteOnSurfaceVariant,
                modifier = Modifier
                    .size(14.dp)
                    .graphicsLayer { rotationZ = chevronRotation },
            )
            Spacer(modifier = Modifier.width(4.dp))
            Icon(
                imageVector = Icons.Filled.Folder,
                contentDescription = null,
                tint = LattePrimary.copy(alpha = 0.8f),
                modifier = Modifier.size(13.dp),
            )
            Spacer(modifier = Modifier.width(5.dp))
            Text(
                text = group.dir?.let { pathLabel(it) } ?: stringResource(R.string.unbound_folder),
                fontSize = 12.sp,
                fontWeight = FontWeight.SemiBold,
                color = LatteOnSurface.copy(alpha = 0.85f),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            Text(
                text = group.items.size.toString(),
                fontSize = 11.sp,
                color = LatteOnSurfaceVariant,
            )
        }
    }

    if (!collapsed) {
        items(group.items, key = { it.id }) { conv ->
            ConversationRow(
                conv = conv,
                agentNames = agentNames,
                onClick = { onOpenConversation(conv.id) },
                onPin = { onPinConversation(conv.id, !conv.isPinned) },
                onArchive = { onArchiveConversation(conv.id) },
            )
            Spacer(modifier = Modifier.height(6.dp))
        }
    }
}

@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(
    conv: ConversationSummary,
    agentNames: Map<String, String>,
    onClick: () -> Unit,
    onPin: () -> Unit,
    onArchive: () -> Unit,
) {
    var showMenu by remember { mutableStateOf(false) }
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = LatteCard,
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(onClick = onClick, onLongClick = { showMenu = true }),
    ) {
        Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (conv.isPinned) {
                    Icon(
                        imageVector = Icons.Filled.PushPin,
                        contentDescription = null,
                        tint = LattePrimary.copy(alpha = 0.8f),
                        modifier = Modifier.size(10.dp),
                    )
                    Spacer(modifier = Modifier.width(4.dp))
                }
                Text(
                    text = conv.title ?: stringResource(R.string.untitled),
                    fontSize = 15.sp,
                    color = LatteOnSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                // 长按菜单（置顶 / 归档）——「▾」显式入口
                Box {
                    Text(
                        text = "▾",
                        fontSize = 12.sp,
                        color = LatteOnSurfaceVariant,
                        modifier = Modifier
                            .padding(start = 6.dp)
                            .clickable { showMenu = true },
                    )
                    androidx.compose.material3.DropdownMenu(
                        expanded = showMenu,
                        onDismissRequest = { showMenu = false },
                        containerColor = LatteCard,
                    ) {
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(if (conv.isPinned) stringResource(R.string.unpin) else stringResource(R.string.pin), color = LatteOnSurface) },
                            onClick = { showMenu = false; onPin() },
                        )
                        androidx.compose.material3.DropdownMenuItem(
                            text = { Text(stringResource(R.string.archive), color = LatteDestructive) },
                            onClick = { showMenu = false; onArchive() },
                        )
                    }
                }
            }
            Spacer(modifier = Modifier.height(2.dp))
            Text(
                text = metaLine(conv, agentNames),
                fontSize = 11.sp,
                color = LatteOnSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/** 「Agent · N 条 · 时间」单行元信息（锁单行，对齐 iOS metaLine + 溢出截断）。 */
private fun metaLine(conv: ConversationSummary, agentNames: Map<String, String>): String {
    val agent = agentNames[conv.agentId] ?: conv.agentId
    val count = "${conv.messageCount} msgs"
    val time = if (conv.updatedAtMs > 0) timeLabel(conv.updatedAtMs) else ""
    return listOf(agent, count, time).filter { it.isNotEmpty() }.joinToString(" · ")
}

@Composable
private fun NoticeRow(icon: androidx.compose.ui.graphics.vector.ImageVector, iconTint: androidx.compose.ui.graphics.Color, text: String) {
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = LatteCard,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(imageVector = icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(12.dp))
            Text(
                text = text,
                fontSize = 12.sp,
                color = LatteOnSurfaceVariant,
            )
        }
    }
}

@Composable
private fun PlainNotice(text: String) {
    Surface(
        shape = MaterialTheme.shapes.medium,
        color = LatteCard,
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 8.dp),
    ) {
        Text(
            text = text,
            fontSize = 12.sp,
            color = LatteOnSurfaceVariant,
            modifier = Modifier.padding(12.dp),
        )
    }
}
