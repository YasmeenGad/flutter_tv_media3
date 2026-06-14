import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tv_media3/src/app_theme/app_theme.dart';

import 'widgets/clock_widget.dart';
import '../../../entity/playback_state.dart';
import '../../../entity/player_state.dart';
import '../../../utils/string_utils.dart';
import '../../media_ui_service/media3_ui_controller.dart';
import 'widgets/custom_info_text_widget.dart';

class TimeLinePanel extends StatefulWidget {
  final Media3UiController controller;
  const TimeLinePanel({super.key, required this.controller});

  @override
  State<TimeLinePanel> createState() => _TimeLinePanelState();
}

class _TimeLinePanelState extends State<TimeLinePanel> {
  double? _sliderPositionOnDrag;
  final _sliderFocus = FocusNode(debugLabel: 'progressSlider');
  bool _sliderHasFocus = false;
  LogicalKeyboardKey? _heldKey;
  DateTime? _holdStartTime;
  DateTime? _lastLongSeekTime;

  static const _shortSeekSeconds = 10;
  static const _longSeekSeconds = 30;
  static const _longPressThreshold = Duration(seconds: 3);
  static const _longRepeatInterval = Duration(milliseconds: 600);

  final style = const TextStyle(
    color: Colors.white,
    fontWeight: FontWeight.w600,
    fontSize: 18,
  );

  @override
  void initState() {
    super.initState();
    _sliderFocus.addListener(_onSliderFocusChange);
  }

  @override
  void dispose() {
    _sliderFocus.removeListener(_onSliderFocusChange);
    _sliderFocus.dispose();
    _cancelLongPress();
    super.dispose();
  }

  void _onSliderFocusChange() {
    if (!mounted) return;
    final hasFocus = _sliderFocus.hasFocus;
    if (hasFocus != _sliderHasFocus) {
      setState(() => _sliderHasFocus = hasFocus);
    }
    if (!hasFocus) _cancelLongPress();
  }

  void _cancelLongPress() {
    _heldKey = null;
    _holdStartTime = null;
    _lastLongSeekTime = null;
  }

  void _seekBySeconds(int seconds) {
    final duration = widget.controller.playbackState.duration;
    final position = widget.controller.playbackState.position;
    final newPosition = (position + seconds).clamp(0, duration);
    widget.controller.seekTo(positionSeconds: newPosition);
  }

  int _directionFor(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.arrowRight ? 1 : -1;

  bool _handleHoldRepeat(LogicalKeyboardKey key) {
    if (_heldKey != key || _holdStartTime == null) return false;
    final now = DateTime.now();
    final heldFor = now.difference(_holdStartTime!);
    if (heldFor < _longPressThreshold) return true;
    if (_lastLongSeekTime != null &&
        now.difference(_lastLongSeekTime!) < _longRepeatInterval) {
      return true;
    }
    _seekBySeconds(_longSeekSeconds * _directionFor(key));
    _lastLongSeekTime = now;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final bool isLive = widget.controller.playerState.isLive;

    return Material(
      color: Colors.transparent,
      child: Row(
        spacing: 8,
        children: [
          StreamBuilder<PlayerState>(
            stream: widget.controller.playerStateStream,
            initialData: widget.controller.playerState,
            builder: (context, snapshot) {
              final playerState = snapshot.data;
              if (playerState == null) return const SizedBox(width: 40);

              return playerState.stateValue == StateValue.paused
                  ? const Icon(Icons.pause, color: Colors.white, size: 40)
                  : const Icon(Icons.play_arrow, color: Colors.white, size: 40);
            },
          ),
          StreamBuilder<PlaybackState>(
            stream: widget.controller.playbackStateStream,
            initialData: widget.controller.playbackState,
            builder: (context, snapshot) {
              final data = snapshot.data;
              if (data == null || data.duration <= 0) {
                return const Expanded(child: SizedBox.shrink());
              }

              final positionPercentage = StringUtils.getPercentage(
                duration: data.duration,
                position: data.position,
              );
              final bufferedPercentage = StringUtils.getPercentage(
                duration: data.duration,
                position: data.bufferedPosition,
              );

              final timeLeft = StringUtils.getTimeLeft(
                position: data.position,
                duration: data.duration,
              );
              final currentPosition = StringUtils.formatDuration(
                seconds: data.position,
              );
              final totalDuration = StringUtils.formatDuration(
                seconds: data.duration,
              );

              return Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: const CustomInfoTextWidget()),
                            const ClockWidget(),
                          ],
                        ),
                        Focus(
                          focusNode: _sliderFocus,
                          canRequestFocus: true,
                          onKeyEvent: (node, event) {
                            final key = event.logicalKey;

                            if (event is KeyUpEvent) {
                              if (_heldKey == key) _cancelLongPress();
                              return KeyEventResult.ignored;
                            }

                            if (event is KeyDownEvent) {
                              if (key == LogicalKeyboardKey.arrowUp) {
                                _cancelLongPress();
                                node.focusInDirection(TraversalDirection.up);
                                return KeyEventResult.handled;
                              }
                              if (key == LogicalKeyboardKey.arrowDown) {
                                _cancelLongPress();
                                node.focusInDirection(TraversalDirection.down);
                                return KeyEventResult.handled;
                              }
                              if (key == LogicalKeyboardKey.arrowRight ||
                                  key == LogicalKeyboardKey.arrowLeft) {
                                if (_heldKey == key) {
                                  _handleHoldRepeat(key);
                                } else {
                                  _seekBySeconds(
                                    _shortSeekSeconds * _directionFor(key),
                                  );
                                  _heldKey = key;
                                  _holdStartTime = DateTime.now();
                                  _lastLongSeekTime = null;
                                }
                                return KeyEventResult.handled;
                              }
                            }

                            if (event is KeyRepeatEvent) {
                              if (key == LogicalKeyboardKey.arrowRight ||
                                  key == LogicalKeyboardKey.arrowLeft) {
                                _handleHoldRepeat(key);
                                return KeyEventResult.handled;
                              }
                            }

                            return KeyEventResult.ignored;
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            curve: Curves.easeOut,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: _sliderHasFocus
                                    ? Colors.white.withValues(alpha: 0.85)
                                    : Colors.transparent,
                                width: 1,
                              ),
                            ),
                            child: ExcludeFocus(
                              child: SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 10.0,
                                thumbShape: const CustomThumbShape(
                                  thumbRadius: 8.0,
                                  borderWidth: 3.0,
                                  cornerRadius: 4.0,
                                ),
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 16.0,
                                ),
                                trackShape:
                                    const RectangularSliderTrackShape(),
                              ),
                              child: Slider(
                                value:
                                    _sliderPositionOnDrag ??
                                    positionPercentage,
                                secondaryTrackValue: bufferedPercentage,
                                min: 0.0,
                                max: 1.0,

                                activeColor: AppTheme.fullFocusColor,
                                secondaryActiveColor: AppTheme.colorMuted,
                                inactiveColor: AppTheme.colorPrimary,
                                thumbColor: AppTheme.fullFocusColor,

                                onChangeEnd: (newValue) {
                                  final newPosition =
                                      data.duration * newValue;
                                  widget.controller.seekTo(
                                    positionSeconds: newPosition.toInt(),
                                  );
                                  setState(() {
                                    _sliderPositionOnDrag = null;
                                  });
                                },
                                onChanged: (newValue) {
                                  setState(() {
                                    _sliderPositionOnDrag = newValue;
                                  });
                                },
                              ),
                            ),
                          ),
                          ),
                        ),
                        isLive
                            ? const SizedBox.shrink()
                            : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(timeLeft, style: style),
                                RichText(
                                  text: TextSpan(
                                    text: currentPosition,
                                    style: style,
                                    children: [
                                      const TextSpan(text: ' / '),
                                      TextSpan(text: totalDuration),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                      ],
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class CustomThumbShape extends SliderComponentShape {
  final double thumbRadius;
  final double borderWidth;
  final double cornerRadius;

  const CustomThumbShape({
    this.thumbRadius = 10.0,
    this.borderWidth = 3.0,
    this.cornerRadius = 4.0,
  });

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size.fromRadius(thumbRadius);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;

    final outerPaint =
        Paint()
          ..color = AppTheme.fullFocusColor
          ..style = PaintingStyle.fill;

    final innerPaint =
        Paint()
          ..color = AppTheme.colorPrimary
          ..style = PaintingStyle.fill;

    final outerRect = Rect.fromCenter(
      center: center,
      width: thumbRadius * 2,
      height: thumbRadius * 2,
    );
    final outerRRect = RRect.fromRectAndRadius(
      outerRect,
      Radius.circular(cornerRadius),
    );

    final innerRect = outerRect.deflate(borderWidth);

    final innerCornerRadius = max(0.0, cornerRadius - borderWidth);
    final innerRRect = RRect.fromRectAndRadius(
      innerRect,
      Radius.circular(innerCornerRadius),
    );

    canvas.drawRRect(outerRRect, outerPaint);
    canvas.drawRRect(innerRRect, innerPaint);
  }
}
