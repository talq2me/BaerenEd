package com.talq2me.baerened.webview

import android.annotation.SuppressLint
import android.app.Activity
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.PermissionRequest
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import java.util.Locale

/**
 * Shows the BaerenEd website and speaks through the tablet text-to-speech engine.
 * The pages call Android.readText only when this bridge exists. A normal browser keeps its own voice.
 * Camera and microphone requests from the site are granted through the tablet.
 */
class ViewerActivity : Activity() {
    private var webView: WebView? = null
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var pendingWebPermission: PermissionRequest? = null
    private var pendingFileCallback: ValueCallback<Array<Uri>>? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if ((applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        val view = WebView(this)
        webView = view
        setContentView(view)

        tts = TextToSpeech(this) { status ->
            if (status != TextToSpeech.SUCCESS) return@TextToSpeech
            val engine = tts ?: return@TextToSpeech
            engine.setSpeechRate(0.85f)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {}
                override fun onDone(utteranceId: String?) {
                    if (utteranceId != null && utteranceId.startsWith("tts_callback_")) notifyPage()
                }
                override fun onError(utteranceId: String?) {
                    if (utteranceId != null && utteranceId.startsWith("tts_callback_")) notifyPage()
                }
            })
            ttsReady = true
            engine.setLanguage(Locale.US)
            val french = engine.setLanguage(Locale.FRENCH)
            if (french == TextToSpeech.LANG_AVAILABLE ||
                french == TextToSpeech.LANG_COUNTRY_AVAILABLE ||
                french == TextToSpeech.LANG_COUNTRY_VAR_AVAILABLE
            ) {
                engine.speak(" ", TextToSpeech.QUEUE_FLUSH, null, "tts_prewarm_fr")
            }
            engine.setLanguage(Locale.US)
        }

        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = true
        view.settings.mediaPlaybackRequiresUserGesture = false
        view.settings.setSupportMultipleWindows(false)
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                val scheme = request?.url?.scheme?.lowercase()
                return scheme != "http" && scheme != "https"
            }
        }
        view.webChromeClient = MediaChromeClient()
        view.addJavascriptInterface(PageBridge(), "Android")
        view.loadUrl(getString(R.string.start_url))
    }

    @Deprecated("Kept for the system back button on older tablets.")
    override fun onBackPressed() {
        val view = webView
        if (view != null && view.canGoBack()) view.goBack() else @Suppress("DEPRECATION") super.onBackPressed()
    }

    @Deprecated("Result of the photo file chooser.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (requestCode == REQUEST_FILE) {
            val callback = pendingFileCallback
            pendingFileCallback = null
            val uris = if (resultCode == RESULT_OK) {
                WebChromeClient.FileChooserParams.parseResult(resultCode, data)
            } else {
                null
            }
            callback?.onReceiveValue(uris)
            return
        }
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_MEDIA) return
        val request = pendingWebPermission
        pendingWebPermission = null
        if (request == null) return
        if (grantResults.isEmpty() || grantResults.any { it != PackageManager.PERMISSION_GRANTED }) {
            Toast.makeText(this, R.string.media_permission_denied, Toast.LENGTH_LONG).show()
        }
        finishWebPermission(request)
    }

    override fun onDestroy() {
        pendingWebPermission?.let { request ->
            try {
                request.deny()
            } catch (e: IllegalStateException) {
                Log.w(TAG, "Media request already finished", e)
            }
        }
        pendingWebPermission = null
        pendingFileCallback?.onReceiveValue(null)
        pendingFileCallback = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        webView?.removeJavascriptInterface("Android")
        webView = null
        super.onDestroy()
    }

    private fun hasPermission(name: String): Boolean {
        return checkSelfPermission(name) == PackageManager.PERMISSION_GRANTED
    }

    private fun missingOsPermissions(resources: Array<String>): List<String> {
        val needed = ArrayList<String>(2)
        if (resources.contains(PermissionRequest.RESOURCE_VIDEO_CAPTURE) &&
            !hasPermission(android.Manifest.permission.CAMERA)
        ) {
            needed.add(android.Manifest.permission.CAMERA)
        }
        if (resources.contains(PermissionRequest.RESOURCE_AUDIO_CAPTURE) &&
            !hasPermission(android.Manifest.permission.RECORD_AUDIO)
        ) {
            needed.add(android.Manifest.permission.RECORD_AUDIO)
        }
        return needed
    }

    private fun siteMayUseMedia(request: PermissionRequest): Boolean {
        val originHost = request.origin?.host
        if (originHost == ALLOWED_HOST) return true
        val pageHost = webView?.url?.let { runCatching { Uri.parse(it).host }.getOrNull() }
        return pageHost == ALLOWED_HOST && originHost.isNullOrEmpty()
    }

    private fun finishWebPermission(request: PermissionRequest) {
        try {
            val allowed = request.resources.filter { resource ->
                when (resource) {
                    PermissionRequest.RESOURCE_VIDEO_CAPTURE ->
                        hasPermission(android.Manifest.permission.CAMERA)
                    PermissionRequest.RESOURCE_AUDIO_CAPTURE ->
                        hasPermission(android.Manifest.permission.RECORD_AUDIO)
                    else -> false
                }
            }
            if (allowed.isEmpty()) {
                Log.i(TAG, "Denying media for ${request.origin}")
                request.deny()
            } else {
                Log.i(TAG, "Granting ${allowed.joinToString()} for ${request.origin}")
                request.grant(allowed.toTypedArray())
            }
        } catch (e: IllegalStateException) {
            Log.w(TAG, "Media request already finished", e)
        }
    }

    private fun notifyPage() {
        val script = """
            (function(){
              function ping(w){
                try {
                  if (w && typeof w.__baerenTtsDone === 'function') {
                    var fn = w.__baerenTtsDone;
                    w.__baerenTtsDone = null;
                    fn();
                    return true;
                  }
                } catch (e) {}
                return false;
              }
              if (ping(window)) return;
              var frames = document.querySelectorAll('iframe');
              for (var i = 0; i < frames.length; i++) {
                if (ping(frames[i].contentWindow)) return;
              }
            })();
        """.trimIndent()
        runOnUiThread {
            webView?.evaluateJavascript(script, null)
        }
    }

    private inner class MediaChromeClient : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest?) {
            if (request == null) return
            runOnUiThread {
                if (!siteMayUseMedia(request)) {
                    Log.i(TAG, "Blocking media for ${request.origin}")
                    request.deny()
                    return@runOnUiThread
                }
                val missing = missingOsPermissions(request.resources)
                if (missing.isEmpty()) {
                    finishWebPermission(request)
                    return@runOnUiThread
                }
                pendingWebPermission?.let { previous ->
                    pendingWebPermission = null
                    try {
                        previous.deny()
                    } catch (e: IllegalStateException) {
                        Log.w(TAG, "Previous media request already finished", e)
                    }
                }
                pendingWebPermission = request
                requestPermissions(missing.toTypedArray(), REQUEST_MEDIA)
            }
        }

        override fun onPermissionRequestCanceled(request: PermissionRequest?) {
            runOnUiThread {
                if (pendingWebPermission == request) pendingWebPermission = null
            }
        }

        override fun onShowFileChooser(
            webView: WebView?,
            filePathCallback: ValueCallback<Array<Uri>>?,
            fileChooserParams: FileChooserParams?
        ): Boolean {
            val callback = filePathCallback ?: return false
            val params = fileChooserParams ?: run {
                callback.onReceiveValue(null)
                return false
            }
            pendingFileCallback?.onReceiveValue(null)
            pendingFileCallback = callback
            return try {
                @Suppress("DEPRECATION")
                startActivityForResult(params.createIntent(), REQUEST_FILE)
                true
            } catch (e: android.content.ActivityNotFoundException) {
                Log.w(TAG, "No file chooser available", e)
                pendingFileCallback = null
                callback.onReceiveValue(null)
                false
            }
        }
    }

    private inner class PageBridge {
        @JavascriptInterface
        fun readText(text: String, lang: String) {
            readText(text, lang, "")
        }

        @JavascriptInterface
        fun readText(text: String, lang: String, rate: String) {
            val engine = tts
            if (engine == null || !ttsReady || text.isBlank()) {
                notifyPage()
                return
            }
            val locale = if (lang.lowercase().startsWith("fr")) Locale.FRENCH else Locale.US
            val parsed = rate.toFloatOrNull()?.takeIf { it in 0.1f..2.0f }
            engine.setSpeechRate(parsed ?: 0.85f)
            engine.setLanguage(locale)
            val utteranceId = "tts_callback_${System.currentTimeMillis()}"
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
        }
    }

    companion object {
        private const val TAG = "BaerenEdWeb"
        private const val ALLOWED_HOST = "talq2me.github.io"
        private const val REQUEST_MEDIA = 41
        private const val REQUEST_FILE = 42
    }
}
