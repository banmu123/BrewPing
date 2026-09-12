package com.brewping.android.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import com.brewping.android.model.PairPayload
import com.brewping.android.ui.theme.LatteOnSurface
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.common.HybridBinarizer
import java.util.concurrent.Executors

// ─── QR 扫码配对（对齐 iOS QRScannerView / AVCaptureSession）───────────────────
//
// 内容格式与 iOS 同一套：`brewping://pair?host=&port=&deviceId=&name=&code=`，
// 也接受纯 6 位数字码（只有码，host/port 由表单补）。识别一次即回调并停流。

@Composable
fun QrScanScreen(
    onResult: (PairPayload) -> Unit,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    var granted by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    var permissionDenied by remember { mutableStateOf(false) }
    var delivered by remember { mutableStateOf(false) }

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { isGranted ->
        granted = isGranted
        permissionDenied = !isGranted
    }

    LaunchedEffect(Unit) {
        if (!granted) permissionLauncher.launch(Manifest.permission.CAMERA)
    }

    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }
    DisposableEffect(Unit) {
        onDispose { analysisExecutor.shutdown() }
    }

    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
        if (granted) {
            AndroidView(
                factory = { ctx ->
                    val previewView = PreviewView(ctx)
                    val future = ProcessCameraProvider.getInstance(ctx)
                    future.addListener({
                        try {
                            val provider = future.get()
                            val preview = Preview.Builder().build().also {
                                it.setSurfaceProvider(previewView.surfaceProvider)
                            }
                            val reader = MultiFormatReader().apply {
                                setHints(
                                    mapOf(
                                        DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                                        DecodeHintType.TRY_HARDER to true,
                                    )
                                )
                            }
                            val analysis = ImageAnalysis.Builder()
                                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                                .build()
                            analysis.setAnalyzer(analysisExecutor) { proxy ->
                                val text = decodeQr(reader, proxy)
                                proxy.close()
                                if (text != null && !delivered) {
                                    val payload = PairPayload.parse(text)
                                    if (payload != null && !delivered) {
                                        delivered = true
                                        previewView.post { onResult(payload) }
                                    }
                                }
                            }
                            provider.unbindAll()
                            provider.bindToLifecycle(
                                lifecycleOwner,
                                CameraSelector.DEFAULT_BACK_CAMERA,
                                preview,
                                analysis,
                            )
                        } catch (_: Exception) {
                            // 相机被占用 / 不可用：界面显示提示文字
                        }
                    }, ContextCompat.getMainExecutor(ctx))
                    previewView
                },
                modifier = Modifier.fillMaxSize(),
            )
        }

        // 顶部提示 + 关闭
        IconButton(
            onClick = onDismiss,
            modifier = Modifier
                .align(Alignment.TopStart)
                .padding(8.dp),
        ) {
            Icon(Icons.Filled.Close, contentDescription = "Close", tint = Color.White)
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .padding(24.dp),
        ) {
            Text(
                text = when {
                    permissionDenied -> "Camera permission denied. Grant it in system settings to scan the pairing code."
                    !granted -> "Requesting camera…"
                    else -> "Point at the pairing QR code shown by the BrewPing desktop app."
                },
                color = Color.White,
                fontSize = 13.sp,
                lineHeight = 18.sp,
            )
        }
    }
}

/** YUV → 灰度 → zxing 解码；旋转 90/270 时手动转置。失败返回 null（绝不抛异常）。 */
private fun decodeQr(reader: MultiFormatReader, proxy: ImageProxy): String? {
    return try {
        val plane = proxy.planes[0]
        val buffer = plane.buffer
        val width = proxy.width
        val height = proxy.height
        val rowStride = plane.rowStride
        val pixelStride = plane.pixelStride
        val y = ByteArray(width * height)
        var idx = 0
        for (row in 0 until height) {
            val rowStart = row * rowStride
            for (col in 0 until width) {
                y[idx++] = buffer.get(rowStart + col * pixelStride)
            }
        }
        val rotation = proxy.imageInfo.rotationDegrees
        fun decodeAt(w: Int, h: Int, data: ByteArray): String? = try {
            val source = PlanarYUVLuminanceSource(data, w, h, 0, 0, w, h, false)
            reader.decodeWithState(BinaryBitmap(HybridBinarizer(source))).text
        } catch (_: Exception) {
            null
        } finally {
            reader.reset()
        }
        if (rotation % 180 == 0) {
            decodeAt(width, height, y)
        } else {
            // 转置后宽高互换
            val transposed = ByteArray(width * height)
            for (r in 0 until height) {
                for (c in 0 until width) {
                    transposed[c * height + r] = y[r * width + c]
                }
            }
            decodeAt(height, width, transposed)
        }
    } catch (_: Exception) {
        null
    }
}
