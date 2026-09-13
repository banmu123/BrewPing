package com.brewping.android.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.sp
import com.brewping.android.R
import com.brewping.android.model.FolderBrowse
import com.brewping.android.model.FolderRoots
import com.brewping.android.model.pathLabel
import com.brewping.android.ui.theme.LatteCard
import com.brewping.android.ui.theme.LatteDestructive
import com.brewping.android.ui.theme.LatteOnSurface
import com.brewping.android.ui.theme.LatteOnSurfaceVariant
import com.brewping.android.ui.theme.LattePrimary

// ─── 目录浏览（对话级 workdir 绑定；对齐桌面端 WorkdirPicker 的浏览语义）────────
//
// 进入 = 桌面端根列表（home + 盘符）；点目录名进入；「Bind this folder」绑定当前
// 目录；顶部「Unbind」解绑。数据来自 `GET /api/folders/roots` 与 `GET /api/folders`。

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FolderBrowserSheet(
    currentDir: String?,
    onDismiss: () -> Unit,
    onFetchRoots: (onResult: (FolderRoots?) -> Unit) -> Unit,
    onFetchFolder: (path: String?, onResult: (FolderBrowse?) -> Unit) -> Unit,
    onBind: (path: String?) -> Unit,
) {
    var roots by remember { mutableStateOf<FolderRoots?>(null) }
    var browse by remember { mutableStateOf<FolderBrowse?>(null) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    // 非组合上下文的 load() 里也要用本地化文案：捕获 Activity context
    val context = androidx.compose.ui.platform.LocalContext.current

    fun load(path: String?) {
        loading = true
        error = null
        if (path == null) {
            onFetchRoots { result ->
                roots = result
                loading = false
                if (result == null) error = context.getString(R.string.cant_browse_folders)
            }
        } else {
            onFetchFolder(path) { result ->
                browse = result
                loading = false
                if (result == null) error = context.getString(R.string.cant_open_folder)
            }
        }
    }

    LaunchedEffect(Unit) { load(null) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .padding(bottom = 24.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = stringResource(R.string.working_folder),
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = LatteOnSurface,
                    modifier = Modifier.weight(1f),
                )
                if (currentDir != null) {
                    Text(
                        text = stringResource(R.string.unbind),
                        fontSize = 12.sp,
                        color = LatteDestructive,
                        modifier = Modifier
                            .clickable { onBind(null) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    )
                }
            }
            // 当前路径面包屑（可点上级）
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.padding(vertical = 4.dp),
            ) {
                if (browse?.parentPath != null) {
                    IconButton(onClick = { load(browse?.parentPath) }) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.up),
                            tint = LatteOnSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                    }
                }
                Text(
                    text = browse?.path?.let { pathLabel(it) } ?: stringResource(R.string.folders_on_desktop),
                    fontSize = 12.sp,
                    color = LatteOnSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                if (browse != null) {
                    Text(
                        text = stringResource(R.string.bind_this_folder),
                        fontSize = 12.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = LattePrimary,
                        modifier = Modifier
                            .clickable { onBind(browse?.path) }
                            .padding(horizontal = 8.dp, vertical = 6.dp),
                    )
                }
            }

            error?.let {
                Text(text = it, fontSize = 12.sp, color = LatteDestructive, modifier = Modifier.padding(vertical = 8.dp))
            }

            Surface(shape = MaterialTheme.shapes.medium, color = LatteCard) {
                LazyColumn(modifier = Modifier.fillMaxWidth().height(360.dp)) {
                    if (loading) {
                        item {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(16.dp),
                            ) {
                                CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(stringResource(R.string.loading), fontSize = 12.sp, color = LatteOnSurfaceVariant)
                            }
                        }
                    }
                    // 根列表：home + 盘符
                    if (browse == null && roots != null) {
                        val rootList = buildList {
                            if (!roots!!.homeDir.isEmpty()) add(roots!!.homeDir)
                            addAll(roots!!.drives)
                        }
                        items(rootList, key = { it }) { root ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { load(root) }
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                            ) {
                                Icon(
                                    Icons.Filled.Folder,
                                    contentDescription = null,
                                    tint = LattePrimary.copy(alpha = 0.85f),
                                    modifier = Modifier.size(14.dp),
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    text = pathLabel(root).ifEmpty { root },
                                    fontSize = 15.sp,
                                    color = LatteOnSurface,
                                )
                            }
                            HorizontalDivider(color = LatteOnSurfaceVariant.copy(alpha = 0.12f), thickness = 0.5.dp)
                        }
                    }
                    // 目录内容
                    browse?.let { current ->
                        val dirs = current.entries
                        if (dirs.isEmpty() && !loading) {
                            item {
                                Text(
                                    text = stringResource(R.string.no_subfolders),
                                    fontSize = 12.sp,
                                    color = LatteOnSurfaceVariant,
                                    modifier = Modifier.padding(16.dp),
                                )
                            }
                        }
                        items(dirs, key = { it.absolutePath }) { entry ->
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable(enabled = !entry.isUnreadable) { load(entry.absolutePath) }
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                            ) {
                                Icon(
                                    Icons.Filled.Folder,
                                    contentDescription = null,
                                    tint = if (entry.isUnreadable) LatteOnSurfaceVariant
                                    else LattePrimary.copy(alpha = 0.85f),
                                    modifier = Modifier.size(14.dp),
                                )
                                Text(
                                    text = entry.name,
                                    fontSize = 15.sp,
                                    color = if (entry.isUnreadable) LatteOnSurfaceVariant else LatteOnSurface,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                    modifier = Modifier.weight(1f),
                                )
                                // 当前已绑定的目录打勾
                                if (currentDir == entry.absolutePath) {
                                    Icon(
                                        Icons.Filled.Check,
                                        contentDescription = null,
                                        tint = LattePrimary,
                                        modifier = Modifier.size(14.dp),
                                    )
                                }
                            }
                            HorizontalDivider(color = LatteOnSurfaceVariant.copy(alpha = 0.12f), thickness = 0.5.dp)
                        }
                    }
                }
            }
        }
    }
}
