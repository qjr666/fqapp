package com.fqapp.fqapp

import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import java.util.concurrent.CopyOnWriteArraySet

/**
 * 听书音频与其他应用音频的混播策略（对齐 Dart 侧 `lib/services/audio_mix_policy.dart`）。
 *
 * 默认独占（[mixWithOthers] = false）：听书出声时向系统申请 AUDIOFOCUS_GAIN，
 * 其他应用的音乐会被自动暂停；用户在「播放设置」里打开「允许与其他应用同时播放」
 * 后不再参与焦点竞争，两路声音叠加播放。
 *
 * 三个音频出口都读这里的同一份状态：
 * - 听书播放器（NativePlayerPlugin 里的 audioOnly ExoPlayer）；
 * - 系统朗读（SystemTtsPlugin）；
 * - 浮窗视频（NativePlayerPlugin 的 floating focus）。
 */
internal object AudioMixPolicy {
    /** true = 允许与其他应用同时播放（不抢音频焦点）。 */
    @Volatile
    var mixWithOthers: Boolean = false
        private set

    /** 策略变更回调，用于把新策略立刻应用到已经在播的播放器。 */
    private val listeners = CopyOnWriteArraySet<() -> Unit>()

    /** 独占模式（默认）：本应用出声时其他应用自动让路。 */
    val exclusive: Boolean
        get() = !mixWithOthers

    /**
     * 应用新的混播策略。取值没变时不做任何事，避免重复下发焦点请求。
     */
    fun apply(value: Boolean) {
        if (mixWithOthers == value) return
        mixWithOthers = value
        listeners.forEach { listener ->
            try {
                listener()
            } catch (_: Throwable) {
                // 单个监听器失败不能影响其他监听器与策略本身的生效。
            }
        }
    }

    fun addListener(listener: () -> Unit) {
        listeners.add(listener)
    }

    fun removeListener(listener: () -> Unit) {
        listeners.remove(listener)
    }

    /**
     * 听书播放器的音频属性（Media3 版）。ContentType 用 SPEECH：听书是人声
     * 口播，与系统朗读的 `android.media` CONTENT_TYPE_SPEECH 保持一致。
     */
    fun listenAudioAttributes(): AudioAttributes = AudioAttributes.Builder()
        .setUsage(C.USAGE_MEDIA)
        .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
        .build()
}

/**
 * 把当前混播策略落到一个听书播放器上。
 *
 * handleAudioFocus = true（独占）时 Media3 自己管理 AUDIOFOCUS_GAIN：出声时
 * 抢焦点、别人出声时把自己暂停；handleAudioFocus = false（允许混播）时
 * Media3 完全不碰焦点，本应用与别的应用各播各的。
 *
 * Media3 允许在播放过程中改这两个参数，所以开关中途切换也能立刻生效。
 */
internal fun applyListenAudioMixPolicy(player: ExoPlayer) {
    try {
        player.setAudioAttributes(
            AudioMixPolicy.listenAudioAttributes(),
            AudioMixPolicy.exclusive,
        )
    } catch (_: Throwable) {
        // 焦点策略失败不影响播放本身，忽略即可。
    }
}
