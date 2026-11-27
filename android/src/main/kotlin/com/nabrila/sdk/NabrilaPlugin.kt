package com.nabrila.sdk

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

/**
 * Native side of the replay: compresses frames to JPEG while the app runs
 * and turns the kept frames into one H.264 video when a report is sent.
 *
 * Defenses against known device bugs: no Exynos C2 encoder (broken
 * videos), bitrate clamped to the encoder's range, timestamps forced to
 * increase, no muxer stop without samples, bounded wait for the end of the
 * stream. Frames go in as YUV buffers with their real times instead of being
 * drawn on an input surface: no canvas (whose hardware path crashes natively
 * on some Xiaomi, Motorola and Unisoc phones and on the emulator) and a rate
 * control that knows the time between frames.
 *
 * Replay needs Android 8 (API 26); below it `supported` says no and reports
 * carry the screenshot only.
 *
 * Nothing runs on the main thread: the channel decodes its arguments on a
 * background task queue (on recent Flutter versions the main thread is also
 * the UI thread), JPEGs are made there, and videos on their own thread so a
 * long video never delays the next frame.
 */
class NabrilaPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var shake: EventChannel? = null
  private lateinit var context: Context
  private lateinit var cacheDir: File
  private lateinit var outboxDir: File
  private val videoWorker = Executors.newSingleThreadExecutor()
  private val main = Handler(Looper.getMainLooper())

  /** One bitmap reused for every JPEG of the same size. */
  private var reusable: Bitmap? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    cacheDir = binding.applicationContext.cacheDir
    // Videos left behind by a process killed mid-encode.
    videoWorker.execute {
      cacheDir.listFiles { f -> f.name.startsWith("nabrila-") && f.name.endsWith(".mp4") }
        ?.forEach { it.delete() }
    }
    // Kept out of backups and device transfers: reports wait here only
    // until the server confirms them.
    outboxDir = File(binding.applicationContext.noBackupFilesDir, "nabrila-outbox")
    val messenger = binding.binaryMessenger
    channel = MethodChannel(
      messenger, "nabrila/replay", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue(),
    ).also { it.setMethodCallHandler(this) }
    shake = EventChannel(messenger, "nabrila/shake").also {
      it.setStreamHandler(ShakeDetector(binding.applicationContext))
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    shake?.setStreamHandler(null)
    shake = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "supported" -> main.post { result.success(Build.VERSION.SDK_INT >= MIN_SDK) }
      // iOS needs time granted to finish an upload in the background;
      // Android keeps a backgrounded app running.
      "beginBackground", "endBackground" -> main.post { result.success(null) }
      // Matched by the remote replay switch, e.g. "samsung sm-a155f".
      "deviceModel" -> main.post {
        result.success("${Build.MANUFACTURER} ${Build.MODEL}".lowercase(Locale.ROOT))
      }
      "storageDir" -> {
        val path = try { outboxDir.apply { mkdirs() }.absolutePath } catch (e: Throwable) { null }
        main.post { result.success(path) }
      }
      // A link with the report key: Android 13+ keeps it out of the
      // clipboard preview and the keyboard's suggestions.
      "copySensitive" -> main.post { result.success(copySensitive(call.argument<String>("text"))) }
      "jpeg" -> respond(call, result) { jpeg(call) }
      "video" -> videoWorker.execute { respond(call, result) { video(call) } }
      else -> main.post { result.notImplemented() }
    }
  }

  private fun copySensitive(text: String?): Boolean {
    if (text == null) return false
    return try {
      val clipboard = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
      val clip = ClipData.newPlainText("Nabrila", text)
      // ClipDescription.EXTRA_IS_SENSITIVE (API 33), by name so it builds
      // with any compileSdk; older versions ignore it.
      clip.description.extras = PersistableBundle().apply {
        putBoolean("android.content.extra.IS_SENSITIVE", true)
      }
      clipboard.setPrimaryClip(clip)
      true
    } catch (e: Throwable) {
      false
    }
  }

  private fun respond(call: MethodCall, result: MethodChannel.Result, work: () -> ByteArray) {
    try {
      val bytes = work()
      main.post { result.success(bytes) }
    } catch (e: Throwable) {
      // OutOfMemoryError included: the report goes out without the replay.
      main.post { result.error("${call.method}_failed", e.toString(), null) }
    }
  }

  /** `{rgba, width, height, quality}` → JPEG bytes. */
  private fun jpeg(call: MethodCall): ByteArray {
    val rgba = call.argument<ByteArray>("rgba")!!
    val width = call.argument<Int>("width")!!
    val height = call.argument<Int>("height")!!
    val quality = call.argument<Int>("quality")!!
    require(width > 0 && height > 0 && rgba.size >= width * height * 4)
    val bitmap = reusable?.takeIf { !it.isRecycled && it.width == width && it.height == height }
      ?: Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888).also {
        reusable?.recycle()
        reusable = it
      }
    // ARGB_8888 keeps its pixels as R, G, B, A bytes, the order Flutter gives.
    bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(rgba, 0, width * height * 4))
    val out = ByteArrayOutputStream(64 * 1024)
    check(bitmap.compress(Bitmap.CompressFormat.JPEG, quality, out)) { "compress" }
    return out.toByteArray()
  }

  /**
   * `{frames: [jpeg], times: [ms from the first frame], width, height,
   * bitrate, quality}` → MP4 bytes, one H.264 sample per frame at its time.
   * Tries the hardware encoder first and the software one if it refuses.
   */
  private fun video(call: MethodCall): ByteArray {
    val frames = call.argument<List<ByteArray>>("frames")!!
    val times = call.argument<List<Number>>("times")!!.map { it.toLong() }
    val bitrate = call.argument<Int>("bitrate")!!
    val quality = call.argument<Double>("quality")!!
    val width = call.argument<Int>("width")!!
    val height = call.argument<Int>("height")!!
    require(frames.isNotEmpty() && frames.size == times.size)
    val errors = mutableListOf<String>()
    for (name in avcEncoders()) {
      try {
        return encode(name, frames, times, width, height, bitrate, quality)
      } catch (e: Throwable) {
        if (e is OutOfMemoryError) throw e
        // A video that does not match its frames lands here too: Google's
        // software encoder on the Android 9 and 11 emulators writes black or
        // green pictures without any error.
        errors += "$name: $e"
      }
    }
    throw IllegalStateException(if (errors.isEmpty()) "no usable H.264 encoder" else errors.joinToString("; "))
  }

  private fun encode(
    name: String,
    frames: List<ByteArray>,
    times: List<Long>,
    sourceWidth: Int,
    sourceHeight: Int,
    bitrate: Int,
    quality: Double,
  ): ByteArray {
    val codec = MediaCodec.createByCodecName(name)
    var muxer: MediaMuxer? = null
    var bitmap: Bitmap? = null
    val file = File(cacheDir, "nabrila-${UUID.randomUUID()}.mp4")
    try {
      val type = codec.codecInfo.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
      check(type.colorFormats.contains(YUV420_FLEXIBLE)) { "no flexible YUV input" }
      val (width, height) = fitSize(type.videoCapabilities, sourceWidth, sourceHeight)
      val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
        setInteger(MediaFormat.KEY_COLOR_FORMAT, YUV420_FLEXIBLE)
        setInteger(MediaFormat.KEY_FRAME_RATE, 1)
        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 30)
        setInteger(MediaFormat.KEY_BIT_RATE, type.videoCapabilities.bitrateRange.clamp(bitrate))
        // B-frames would reorder samples; one picture per second needs none.
        if (Build.VERSION.SDK_INT >= 29) setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
        // Software encoders (and some cheap hardware ones) overshoot the
        // bitrate on busy frames; a floor on the quantizer keeps them close.
        if (Build.VERSION.SDK_INT >= 31) {
          setInteger(MediaFormat.KEY_VIDEO_QP_MIN, MIN_QP)
          setInteger(MediaFormat.KEY_VIDEO_QP_MAX, 51)
        }
        // Constant quality where the encoder has it (qualityRange is API 28+).
        // Not on Google's software encoders: they are the last resort, and
        // the plain bitrate is the mode they handle best.
        val encoder = type.encoderCapabilities
        if (Build.VERSION.SDK_INT >= 28 && !isSoftware(name) &&
          encoder.isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ)
        ) {
          val range = encoder.qualityRange
          setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CQ)
          setInteger(MediaFormat.KEY_QUALITY, range.lower + ((range.upper - range.lower) * quality).toInt())
        }
      }
      codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
      codec.start()
      muxer = MediaMuxer(file.path, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
      val drain = Drain(codec, muxer)
      val pixels = IntArray(width * height)
      val options = BitmapFactory.Options().apply { inMutable = true }
      var previous = -1L
      var first: Luma? = null
      var firstUs = 0L
      var last: Luma? = null
      for ((index, jpeg) in frames.withIndex()) {
        val ms = times[index]
        if (ms <= previous) continue
        options.inBitmap = bitmap
        val decoded = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size, options) ?: continue
        bitmap = decoded
        if (decoded.width < width || decoded.height < height) continue
        // Sides were rounded down to 16: the frame keeps its top-left part.
        decoded.getPixels(pixels, 0, width, 0, 0, width, height)
        val input = drain.inputBuffer()
        val image = codec.getInputImage(input) ?: error("no input image")
        writeYuv(image, pixels, width, height)
        if (first == null) {
          first = Luma.of(pixels, width, height)
          firstUs = ms * 1000
        } else if (index == frames.lastIndex) {
          last = Luma.of(pixels, width, height)
        }
        // The real time goes to the encoder, so its rate control knows a
        // second passes between pictures even though they arrive at once.
        codec.queueInputBuffer(input, 0, width * height * 3 / 2, ms * 1000, 0)
        previous = ms
        drain.run(endOfStream = false)
      }
      codec.queueInputBuffer(drain.inputBuffer(), 0, 0, (previous + 1) * 1000, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
      drain.run(endOfStream = true)
      check(drain.samples > 0) { "no samples" }
      muxer.stop()
      // Some encoders take every frame and still write a black or garbled
      // video without any error. The first picture is decoded back and
      // compared with what went in; a mismatch tries the next encoder.
      first?.let { verify(file, firstUs, it) }
      last?.let { verify(file, previous * 1000, it) }
      return file.readBytes()
    } finally {
      // Each step on its own, so one failure still frees the rest.
      try { codec.stop() } catch (_: Throwable) {}
      try { codec.release() } catch (_: Throwable) {}
      try { muxer?.release() } catch (_: Throwable) {}
      bitmap?.recycle()
      file.delete()
    }
  }

  /** Throws if the video's first picture does not look like [expected]. */
  private fun verify(file: File, atUs: Long, expected: Luma) {
    val retriever = MediaMetadataRetriever()
    var frame: Bitmap? = null
    try {
      retriever.setDataSource(file.path)
      frame = retriever.getFrameAtTime(atUs, MediaMetadataRetriever.OPTION_CLOSEST)
        ?: error("video unreadable")
      val pixels = IntArray(frame.width * frame.height)
      frame.getPixels(pixels, 0, frame.width, 0, 0, frame.width, frame.height)
      val got = Luma.of(pixels, frame.width, frame.height)
      check(expected.matches(got)) { "video does not match its frames ($expected vs $got)" }
    } finally {
      frame?.recycle()
      try { retriever.release() } catch (_: Throwable) {}
    }
  }

  /** Moves encoded samples into the muxer. */
  private class Drain(private val codec: MediaCodec, private val muxer: MediaMuxer) {
    var samples = 0
    private var started = false
    private var track = -1
    private var lastUs = -1L
    private val info = MediaCodec.BufferInfo()

    /** A free input buffer, draining output while the encoder is full. */
    fun inputBuffer(): Int {
      repeat(300) {
        val index = codec.dequeueInputBuffer(10_000)
        if (index >= 0) return index
        run(endOfStream = false)
      }
      error("encoder stalled")
    }

    fun run(endOfStream: Boolean) {
      // Some hardware encoders never send the end of the stream: give up
      // after about three seconds without output instead of hanging.
      var idle = 0
      while (true) {
        val index = codec.dequeueOutputBuffer(info, if (endOfStream) 10_000 else 0)
        when {
          index == MediaCodec.INFO_TRY_AGAIN_LATER -> {
            if (!endOfStream || ++idle > 300) return
          }
          index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
            check(!started) { "format changed twice" }
            track = muxer.addTrack(codec.outputFormat)
            muxer.start()
            started = true
          }
          index >= 0 -> {
            idle = 0
            val data = codec.getOutputBuffer(index)
            val config = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
            if (data != null && !config && info.size > 0 && started) {
              // The muxer rejects times that do not increase.
              info.presentationTimeUs = maxOf(info.presentationTimeUs, lastUs + 1)
              lastUs = info.presentationTimeUs
              data.position(info.offset)
              data.limit(info.offset + info.size)
              muxer.writeSampleData(track, data, info)
              samples++
            }
            codec.releaseOutputBuffer(index, false)
            if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
          }
        }
      }
    }
  }

  companion object {
    /** Android 8: older phones are under 1% of use and their encoders crash. */
    const val MIN_SDK = 26

    /** Lowest quantizer allowed (0 is lossless, 51 the coarsest). */
    private const val MIN_QP = 32

    private const val YUV420_FLEXIBLE = MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible

    /**
     * RGB to BT.601 limited-range YUV 4:2:0 into the encoder's own planes,
     * honoring their strides (each vendor lays them out differently). Chroma
     * is the average of each 2x2 block, so thin colored text stays clean.
     */
    fun writeYuv(image: android.media.Image, argb: IntArray, width: Int, height: Int) {
      val planes = image.planes
      val y = planes[0]
      val yBuf = y.buffer
      for (row in 0 until height) {
        val base = row * y.rowStride
        for (col in 0 until width) {
          val p = argb[row * width + col]
          val r = (p shr 16) and 0xff
          val g = (p shr 8) and 0xff
          val b = p and 0xff
          yBuf.put(base + col * y.pixelStride, (((66 * r + 129 * g + 25 * b + 128) shr 8) + 16).toByte())
        }
      }
      val u = planes[1]
      val v = planes[2]
      val uBuf = u.buffer
      val vBuf = v.buffer
      for (row in 0 until height / 2) {
        for (col in 0 until width / 2) {
          var r = 0
          var g = 0
          var b = 0
          for (dy in 0..1) for (dx in 0..1) {
            val p = argb[(row * 2 + dy) * width + col * 2 + dx]
            r += (p shr 16) and 0xff
            g += (p shr 8) and 0xff
            b += p and 0xff
          }
          r = r shr 2
          g = g shr 2
          b = b shr 2
          uBuf.put(row * u.rowStride + col * u.pixelStride, (((-38 * r - 74 * g + 112 * b + 128) shr 8) + 128).toByte())
          vBuf.put(row * v.rowStride + col * v.pixelStride, (((112 * r - 94 * g - 18 * b + 128) shr 8) + 128).toByte())
        }
      }
    }

    fun isSoftware(name: String) = name.startsWith("OMX.google.") || name.startsWith("c2.android.")

    /** H.264 encoders to try in order: hardware first, then software. */
    fun avcEncoders(): List<String> {
      val all = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { info ->
        info.isEncoder && info.supportedTypes.any { it.equals(MediaFormat.MIMETYPE_VIDEO_AVC, true) }
      }.map { it.name }
      // The Exynos C2 encoder produces broken videos (Pixel and Samsung).
      val hardware = all.filter { !isSoftware(it) && !it.lowercase(Locale.ROOT).startsWith("c2.exynos") }
      // Google's software encoder is the last resort. On Android 7 it
      // crashes the system media process, which is why replay starts at
      // Android 8. Where it writes a broken video, the check after encoding
      // catches it and the report carries the frames.
      val software = all.filter(::isSoftware)
      return (hardware.take(2) + software).distinct()
    }

    /**
     * Sides that are multiples of 16 (some encoders take nothing else) and
     * that the encoder supports, scaled down keeping the aspect ratio.
     */
    fun fitSize(caps: MediaCodecInfo.VideoCapabilities, width: Int, height: Int): Pair<Int, Int> {
      var scale = 1.0
      repeat(20) {
        val w = maxOf(16, (width * scale).toInt() / 16 * 16)
        val h = maxOf(16, (height * scale).toInt() / 16 * 16)
        if (caps.isSizeSupported(w, h)) return w to h
        scale *= 0.9
      }
      throw IllegalArgumentException("size ${width}x$height not supported")
    }
  }
}

/**
 * Mean and spread of the brightness of a picture, on a coarse grid. Enough
 * to tell a real screen from a black, grey or garbled one, cheap enough to
 * run on every video.
 */
internal data class Luma(val mean: Double, val spread: Double) {
  fun matches(other: Luma): Boolean {
    // A flat picture that came out flat is fine; a busy screen that came
    // out flat (all black, all grey) is not.
    if (spread > 12 && other.spread < spread * 0.25) return false
    return kotlin.math.abs(mean - other.mean) <= 40
  }

  override fun toString() = "mean %.0f spread %.0f".format(Locale.ROOT, mean, spread)

  companion object {
    fun of(argb: IntArray, width: Int, height: Int): Luma {
      var sum = 0.0
      var squares = 0.0
      var count = 0
      val step = maxOf(1, minOf(width, height) / 48)
      var y = 0
      while (y < height) {
        var x = 0
        while (x < width) {
          val p = argb[y * width + x]
          val l = 0.299 * ((p shr 16) and 0xff) + 0.587 * ((p shr 8) and 0xff) + 0.114 * (p and 0xff)
          sum += l
          squares += l * l
          count++
          x += step
        }
        y += step
      }
      val mean = sum / count
      return Luma(mean, kotlin.math.sqrt(maxOf(0.0, squares / count - mean * mean)))
    }
  }
}
