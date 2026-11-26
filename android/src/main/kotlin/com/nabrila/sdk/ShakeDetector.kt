package com.nabrila.sdk

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import io.flutter.plugin.common.EventChannel
import kotlin.math.sqrt

/**
 * Tells Dart when the phone is shaken. It reads the accelerometer, which
 * needs no permission, and only while Dart listens (the app is in the
 * foreground): no sensor runs in the background.
 *
 * A shake is most of the readings of the last half second well above
 * gravity, over at least a quarter of a second, the way Square's Seismic
 * does it; a single bump or a walk does not count.
 */
internal class ShakeDetector(context: Context) : EventChannel.StreamHandler, SensorEventListener {
  private val sensors = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
  private var sink: EventChannel.EventSink? = null
  private val times = ArrayDeque<Long>()
  private val strong = ArrayDeque<Boolean>()
  private var lastShake = 0L

  override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
    val accelerometer = sensors?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    if (accelerometer == null) {
      events.endOfStream()
      return
    }
    sink = events
    sensors.registerListener(this, accelerometer, SensorManager.SENSOR_DELAY_GAME)
  }

  override fun onCancel(arguments: Any?) {
    sensors?.unregisterListener(this)
    sink = null
    times.clear()
    strong.clear()
  }

  override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}

  override fun onSensorChanged(event: SensorEvent) {
    val x = event.values[0]
    val y = event.values[1]
    val z = event.values[2]
    if (isShake(event.timestamp / 1_000_000, sqrt(x * x + y * y + z * z))) sink?.success(null)
  }

  /** [magnitude] in m/s² at [nowMs]; true once per shake. */
  fun isShake(nowMs: Long, magnitude: Float): Boolean {
    times.addLast(nowMs)
    strong.addLast(magnitude > THRESHOLD)
    while (times.isNotEmpty() && nowMs - times.first() > WINDOW_MS) {
      times.removeFirst()
      strong.removeFirst()
    }
    if (times.size < 4 || nowMs - times.first() < WINDOW_MS / 2) return false
    if (strong.count { it } * 4 < times.size * 3) return false
    if (nowMs - lastShake < COOLDOWN_MS) return false
    lastShake = nowMs
    times.clear()
    strong.clear()
    return true
  }

  companion object {
    /** About 1.35 g: more than a walk, less than a real shake. */
    const val THRESHOLD = 13f
    const val WINDOW_MS = 500L
    const val COOLDOWN_MS = 1500L
  }
}
