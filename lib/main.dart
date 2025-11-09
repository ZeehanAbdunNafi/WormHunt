import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

enum _WormPhase { traveling, emerging, surfaced, submerging }

class _Explosion {
  _Explosion({required this.position, this.sizeMultiplier = 1});

  final Offset position;
  final double sizeMultiplier;
  double elapsed = 0;
}

class _TntCrate {
  _TntCrate({required this.position});

  final Offset position;
}

void main() {
  runApp(const WormHuntApp());
}

class WormHuntApp extends StatelessWidget {
  const WormHuntApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Worm Hunt',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
      ),
      home: const TankGamePage(),
    );
  }
}

class TankGamePage extends StatefulWidget {
  const TankGamePage({super.key});

  @override
  State<TankGamePage> createState() => _TankGamePageState();
}

class _TankGamePageState extends State<TankGamePage>
    with SingleTickerProviderStateMixin {
  static const double _zoomFactor = 0.85;
  static const double _tankBaseWidth = 160;
  static const double _tankGroundBaseOffset = 0;
  static const double _movementSpeed = 260; // pixels per second
  static const double _aimCursorBaseSize = 68;
  static const double _explosionBaseSize = 220;
  static const double _explosionLifetime = 0.6;
  static const double _shotCooldownSeconds = 3.0;
  static const double _tntBaseSize = 110;
  static const double _bigExplosionMultiplier = 3.0;
  static const double _shotTimeoutSeconds = 18.0;

  static const double _wormBaseWidth = 220;
  static const double _wormSpeed = 160;
  static const double _attackTriggerBaseDistance = 70;
  static const double _wormEmergenceBaseHeight = 240;
  static const double _wormEmergenceDuration = 0.4;
  static const double _wormSurfaceHoldDuration = 0.3;
  static const double _wormSubmergeDuration = 0.5;

  late final FocusNode _focusNode;
  late final Ticker _ticker;
  final math.Random _random = math.Random();

  bool _moveLeft = false;
  bool _moveRight = false;
  bool _isFacingRight = true;

  double _stageWidth = 0;
  double _stageHeight = 0;
  double _tankX = 0;
  double _wormX = 0;
  int _wormDirection = 1;
  double _proximity = 0;
  Duration? _lastTick;

  _WormPhase _wormPhase = _WormPhase.emerging;
  double _wormPhaseTimer = 0;
  double _wormVisibleHeight = 0;
  double _nextEmergenceX = 0;
  double _lastSeenTankCenter = 0;
  Offset? _aimPosition;
  bool _showAimCursor = false;
  final List<_Explosion> _explosions = [];
  double _shotCooldownRemaining = 0;
  _TntCrate? _activeTnt;
  int _lives = 3;
  bool _gameOver = false;
  double _timeSinceLastShot = 0;
  String? _statusMessage;
  bool _wormContactInflicted = false;
  int _killCount = 0;

  double get _tankWidth => _tankBaseWidth * _zoomFactor;
  double get _tankGroundOffset => _tankGroundBaseOffset * _zoomFactor;
  double get _wormWidth => _wormBaseWidth * _zoomFactor;
  double get _wormEmergenceHeight => _wormEmergenceBaseHeight * _zoomFactor;
  double get _attackTriggerDistance => _attackTriggerBaseDistance * _zoomFactor;
  double get _aimCursorSize => _aimCursorBaseSize * _zoomFactor;
  double get _explosionBaseVisualSize => _explosionBaseSize * _zoomFactor;
  double get _tntSize => _tntBaseSize * _zoomFactor;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _focusNode.requestFocus();
          }
        });
      }
    });
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _ticker.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTick(Duration elapsed) {
    if (_stageWidth == 0) {
      _lastTick = elapsed;
      return;
    }

    final previous = _lastTick;
    _lastTick = elapsed;
    if (previous == null) {
      return;
    }
    if (_gameOver) {
      return;
    }

    final deltaMicros = (elapsed - previous).inMicroseconds;
    if (deltaMicros <= 0) {
      return;
    }

    final deltaSeconds =
        (deltaMicros / 1000000).clamp(0.0, 0.4); // clamp to avoid huge steps
    final tankMaxX =
        (_stageWidth - _tankWidth).clamp(0.0, double.infinity).toDouble();
    final wormMaxX =
        (_stageWidth - _wormWidth).clamp(0.0, double.infinity).toDouble();

    double tankX = _tankX;
    final direction = _horizontalDirection();
    if (direction != 0) {
      tankX = (tankX + direction * _movementSpeed * deltaSeconds)
          .clamp(0.0, tankMaxX)
          .toDouble();
    }

    double wormX = _wormX;
    int wormDirection = _wormDirection;
    final tankCenter = tankX + _tankWidth / 2;

    var wormPhase = _wormPhase;
    double phaseTimer = _wormPhaseTimer;
    double visibleHeight = _wormVisibleHeight;
    double nextEmergenceX = _nextEmergenceX;
    double lastSeenTankCenter = _lastSeenTankCenter;
    const double alignmentTolerance = 1.0;
    double targetX = nextEmergenceX.clamp(0.0, wormMaxX);

    switch (wormPhase) {
      case _WormPhase.traveling:
        final deltaToTarget = targetX - wormX;
        final distanceToTarget = deltaToTarget.abs();
        if (distanceToTarget <= alignmentTolerance) {
          wormX = targetX;
          wormPhase = _WormPhase.emerging;
          phaseTimer = 0;
          visibleHeight = 0;
          _wormContactInflicted = false;
        } else {
          final travelStep = _wormSpeed * deltaSeconds;
          if (travelStep >= distanceToTarget) {
            wormX = targetX;
            wormPhase = _WormPhase.emerging;
            phaseTimer = 0;
            visibleHeight = 0;
            wormDirection = deltaToTarget >= 0 ? 1 : -1;
            _wormContactInflicted = false;
          } else {
            final move = deltaToTarget.sign * travelStep;
            wormX = (wormX + move).clamp(0.0, wormMaxX);
            if (move != 0) {
              wormDirection = move > 0 ? 1 : -1;
            }
            visibleHeight = 0;
          }
        }
        break;
      case _WormPhase.emerging:
        wormX = targetX;
        phaseTimer += deltaSeconds;
        final emergenceProgress = _wormEmergenceDuration <= 0
            ? 1.0
            : (phaseTimer / _wormEmergenceDuration).clamp(0.0, 1.0);
        visibleHeight = _wormEmergenceHeight * emergenceProgress;
        if (emergenceProgress >= 1.0) {
          wormPhase = _WormPhase.surfaced;
          phaseTimer = 0;
          visibleHeight = _wormEmergenceHeight;
          lastSeenTankCenter = tankCenter;
        }
        break;
      case _WormPhase.surfaced:
        phaseTimer += deltaSeconds;
        visibleHeight = _wormEmergenceHeight;
        if (phaseTimer >= _wormSurfaceHoldDuration) {
          wormPhase = _WormPhase.submerging;
          phaseTimer = 0;
        }
        break;
      case _WormPhase.submerging:
        phaseTimer += deltaSeconds;
        final submergeProgress = _wormSubmergeDuration <= 0
            ? 1.0
            : (phaseTimer / _wormSubmergeDuration).clamp(0.0, 1.0);
        visibleHeight = _wormEmergenceHeight * (1 - submergeProgress);
        if (submergeProgress >= 1.0) {
          wormPhase = _WormPhase.traveling;
          phaseTimer = 0;
          visibleHeight = 0;
          final targetCenter = lastSeenTankCenter;
          nextEmergenceX =
              (targetCenter - _wormWidth / 2).clamp(0.0, wormMaxX);
          targetX = nextEmergenceX;
          _wormContactInflicted = false;
        }
        break;
    }

    visibleHeight =
        visibleHeight.clamp(0.0, _wormEmergenceHeight.toDouble());
    wormX = wormX.clamp(0.0, wormMaxX);
    if (_shotCooldownRemaining > 0) {
      _shotCooldownRemaining =
          math.max(0.0, _shotCooldownRemaining - deltaSeconds);
    }

    if (_explosions.isNotEmpty) {
      for (final explosion in _explosions) {
        explosion.elapsed += deltaSeconds;
      }
      _explosions.removeWhere((explosion) => explosion.elapsed >= _explosionLifetime);
    }

    if (!_gameOver) {
      _timeSinceLastShot += deltaSeconds;
      if (_timeSinceLastShot >= _shotTimeoutSeconds) {
        _triggerTimeoutFailure();
      }
    }

    if (!_gameOver && _stageWidth > 0 && _stageHeight > 0) {
      _activeTnt ??= _makeRandomTnt();
    } else if (_gameOver) {
      _activeTnt = null;
    }
    if (!_wormContactInflicted &&
        !_gameOver &&
        _stageHeight > 0 &&
        _wormVisibleHeight > _wormEmergenceHeight * 0.4 &&
        (wormPhase == _WormPhase.surfaced ||
            (wormPhase == _WormPhase.emerging &&
                visibleHeight >= _wormEmergenceHeight * 0.6))) {
      final wormCenterX = wormX + _wormWidth / 2;
      final horizontalThreshold = (_wormWidth + _tankWidth) * 0.35;
      if ((tankCenter - wormCenterX).abs() <= horizontalThreshold) {
        _wormContactInflicted = true;
        _lives = math.max(0, _lives - 1);
        if (_lives <= 0) {
          _triggerGameOver('The worm devoured your tank.');
          return;
        } else {
          _statusMessage = 'The worm struck! Lives left: $_lives';
          final bool spawnLeft = tankCenter > _stageWidth / 2;
          wormX = spawnLeft ? 0.0 : wormMaxX;
          wormDirection = spawnLeft ? 1 : -1;
          wormPhase = _WormPhase.traveling;
          phaseTimer = 0;
          visibleHeight = 0;
          lastSeenTankCenter = tankCenter;
          nextEmergenceX =
              (lastSeenTankCenter - _wormWidth / 2).clamp(0.0, wormMaxX);
          _activeTnt ??= _makeRandomTnt();
        }
      }
    }

    final wormCenter = wormX + _wormWidth / 2;
    final distance = (tankCenter - wormCenter).abs();

    final detectionRange = math.max(_stageWidth * 0.5, _attackTriggerDistance);
    final proximity =
        (1 - distance / detectionRange).clamp(0.0, 1.0).toDouble();

    if (!mounted) return;

    setState(() {
      _tankX = tankX;
      _wormX = wormX;
      _wormDirection = wormDirection;
      _proximity = proximity;
      _wormPhase = wormPhase;
      _wormPhaseTimer = phaseTimer;
      _wormVisibleHeight = visibleHeight;
      _nextEmergenceX = nextEmergenceX;
      _lastSeenTankCenter = lastSeenTankCenter;
    });
  }

  int _horizontalDirection() {
    if (_moveLeft == _moveRight) {
      return 0;
    }
    return _moveRight ? 1 : -1;
  }

  void _handleKey(RawKeyEvent event) {
    final key = event.logicalKey;

    if (event is RawKeyDownEvent && !event.repeat) {
      if (key == LogicalKeyboardKey.keyA) {
        final shouldFlip = _isFacingRight;
        _moveRight = false;
        _moveLeft = true;
        if (shouldFlip) {
          setState(() {
            _isFacingRight = false;
          });
        }
      } else if (key == LogicalKeyboardKey.keyD) {
        final shouldFlip = !_isFacingRight;
        _moveLeft = false;
        _moveRight = true;
        if (shouldFlip) {
          setState(() {
            _isFacingRight = true;
          });
        }
      }
    } else if (event is RawKeyUpEvent) {
      if (key == LogicalKeyboardKey.keyA) {
        _moveLeft = false;
      } else if (key == LogicalKeyboardKey.keyD) {
        _moveRight = false;
      }
    }
  }

  void _updateAimPosition(Offset localPosition, Size stageSize) {
    final clamped = Offset(
      localPosition.dx.clamp(0.0, stageSize.width),
      localPosition.dy.clamp(0.0, stageSize.height),
    );

    if (_aimPosition == clamped && _showAimCursor) {
      return;
    }

    setState(() {
      _aimPosition = clamped;
      _showAimCursor = true;
    });
  }

  void _handleAimExit() {
    if (!_showAimCursor) {
      return;
    }

    setState(() {
      _showAimCursor = false;
    });
  }

  void _registerShot(Offset localPosition, Size stageSize) {
    if (_gameOver || _shotCooldownRemaining > 0) {
      return;
    }

    final clamped = Offset(
      localPosition.dx.clamp(0.0, stageSize.width),
      localPosition.dy.clamp(0.0, stageSize.height),
    );

    setState(() {
      _aimPosition = clamped;
      _showAimCursor = true;
      _handleShotAt(clamped, stageSize);
    });
  }

  void _handleShotAt(Offset impact, Size stageSize) {
    final crate = _activeTnt;
    final bool hitTnt = crate != null &&
        (impact - crate.position).distance <= _tntSize * 0.5;

    _shotCooldownRemaining = _shotCooldownSeconds;
    _timeSinceLastShot = 0;

    if (hitTnt && crate != null) {
      _resolveTntExplosion(crate, stageSize);
    } else {
      _addExplosion(_Explosion(position: impact));
      _statusMessage = null;
    }
  }

  void _addExplosion(_Explosion explosion) {
    _explosions.add(explosion);
    const int maxExplosions = 48;
    if (_explosions.length > maxExplosions) {
      _explosions.removeRange(0, _explosions.length - maxExplosions);
    }
  }

  void _resolveTntExplosion(_TntCrate crate, Size stageSize) {
    final explosionCenter = crate.position;
    _activeTnt = null;
    _addExplosion(_Explosion(
      position: explosionCenter,
      sizeMultiplier: _bigExplosionMultiplier,
    ));

    final double explosionRadius =
        (_explosionBaseVisualSize * _bigExplosionMultiplier) * 0.5;
    final wormCenter = Offset(
      _wormX + _wormWidth / 2,
      stageSize.height - _wormEmergenceHeight / 2,
    );
    final tankCenter = Offset(
      _tankX + _tankWidth / 2,
      stageSize.height - _tankWidth * 0.5,
    );

    final bool wormHit =
        _distance(wormCenter, explosionCenter) <= explosionRadius;
    final bool tankHit =
        _distance(tankCenter, explosionCenter) <= explosionRadius;

    if (tankHit) {
      _triggerGameOver('You were caught in the TNT blast!');
      return;
    }

    if (wormHit) {
      _killCount += 1;
      _statusMessage = 'Direct hit! Kills: $_killCount';
      _spawnWormAwayFromTank();
    } else {
      _lives = math.max(0, _lives - 1);
      if (_lives == 0) {
        _triggerGameOver('You wasted the TNT and ran out of lives.');
        return;
      } else {
        _statusMessage = 'Missed the worm! Lives left: $_lives';
      }
    }

    if (!_gameOver) {
      _activeTnt = _makeRandomTnt();
    }
  }

  void _spawnWormAwayFromTank() {
    final wormMaxX =
        (_stageWidth - _wormWidth).clamp(0.0, double.infinity).toDouble();
    final tankCenter = _tankX + _tankWidth / 2;
    final bool spawnLeft = tankCenter > _stageWidth / 2;
    _wormX = spawnLeft ? 0.0 : wormMaxX;
    _wormDirection = spawnLeft ? 1 : -1;
    _wormPhase = _WormPhase.traveling;
    _wormPhaseTimer = 0;
    _wormVisibleHeight = 0;
    _lastSeenTankCenter = tankCenter;
    _nextEmergenceX =
        (_lastSeenTankCenter - _wormWidth / 2).clamp(0.0, wormMaxX);
    _wormContactInflicted = false;
  }

_TntCrate? _makeRandomTnt() {
  if (_stageWidth <= 0 || _stageHeight <= 0) {
    return null;
  }
  final double maxX =
      (_stageWidth - _tntSize).clamp(0.0, double.infinity).toDouble();
  final double x = (_random.nextDouble() * (maxX == 0 ? 1 : maxX));
  final center = Offset(x + _tntSize / 2, _stageHeight - _tntSize / 2);
  return _TntCrate(position: center);
}

  void _triggerGameOver(String message) {
    if (_gameOver) return;
    _gameOver = true;
    _statusMessage = message;
    _lives = 0;
    _shotCooldownRemaining = 0;
    _activeTnt = null;
    final double giantMultiplier =
        (_stageWidth <= 0 || _stageHeight <= 0) ? 6.0 : 6.0;
    _addExplosion(_Explosion(
      position: Offset(_stageWidth / 2, _stageHeight / 2),
      sizeMultiplier: giantMultiplier,
    ));
  }

  void _triggerTimeoutFailure() {
    _triggerGameOver('You hesitated too long. The worm strikes first.');
  }

  double _distance(Offset a, Offset b) => (a - b).distance;

  void _updateStageSize(double width, double height) {
    if (width == _stageWidth && height == _stageHeight) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
    setState(() {
        final previousWidth = _stageWidth;
        _stageWidth = width;
        _stageHeight = height;
        final tankMaxX =
            (_stageWidth - _tankWidth).clamp(0.0, double.infinity).toDouble();
        final wormMaxX =
            (_stageWidth - _wormWidth).clamp(0.0, double.infinity).toDouble();

        if (previousWidth == 0) {
          // Spawn tank on the left and worm on the right on first layout.
          _tankX = 0;
          _wormX = wormMaxX;
          _wormDirection = -1;
          _wormPhase = _WormPhase.emerging;
          _wormPhaseTimer = 0;
          _wormVisibleHeight = 0;
          final initialWormCenter =
              (_wormX + _wormWidth / 2).clamp(0.0, _stageWidth);
          _lastSeenTankCenter = initialWormCenter;
          _nextEmergenceX =
              (initialWormCenter - _wormWidth / 2).clamp(0.0, wormMaxX);
        } else {
          _tankX = _tankX.clamp(0.0, tankMaxX).toDouble();
          _wormX = _wormX.clamp(0.0, wormMaxX).toDouble();
        }
        _nextEmergenceX = _nextEmergenceX.clamp(0.0, wormMaxX).toDouble();
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF512C1E),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.biggest.width.isFinite
              ? constraints.biggest.width
              : MediaQuery.sizeOf(context).width;

          final parentHeight = constraints.biggest.height.isFinite
              ? constraints.biggest.height
              : MediaQuery.sizeOf(context).height;
          final stageWidth = width * _zoomFactor;
          final stageHeight = parentHeight * _zoomFactor;
          _updateStageSize(stageWidth, stageHeight);
          final barWidth = 260.0 * _zoomFactor;
          final barHeight = 18.0 * _zoomFactor;
          final fillWidth = barWidth * _proximity.clamp(0.0, 1.0);
          final barColor = Color.lerp(
            Colors.deepOrangeAccent,
            Colors.redAccent,
            _proximity,
          )!;
          final proximityPercent =
              (_proximity * 100).clamp(0, 100).round();
          final wormBottomOffset =
              (-_wormEmergenceHeight + _wormVisibleHeight)
                  .clamp(-_wormEmergenceHeight, 0.0)
                  .toDouble();
          final bool wormFacingRight = _wormDirection >= 0;
          final remainingSeconds =
              (_shotTimeoutSeconds - _timeSinceLastShot).clamp(0.0, _shotTimeoutSeconds);
          final timerLabel = remainingSeconds.toStringAsFixed(1);

          final stageSize = Size(stageWidth, stageHeight);
          final aimCursorSize = _aimCursorSize;
          final explosionBaseSize = _explosionBaseVisualSize;

          return GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _focusNode.requestFocus,
            child: RawKeyboardListener(
              focusNode: _focusNode,
              autofocus: true,
              onKey: _handleKey,
              child: Align(
                child: FractionallySizedBox(
                  widthFactor: _zoomFactor,
                  heightFactor: _zoomFactor,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.none,
                    onHover: (event) => _updateAimPosition(
                      event.localPosition,
                      stageSize,
                    ),
                    onExit: (_) => _handleAimExit(),
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerHover: (event) => _updateAimPosition(
                        event.localPosition,
                        stageSize,
                      ),
                      onPointerMove: (event) => _updateAimPosition(
                        event.localPosition,
                        stageSize,
                      ),
                      onPointerDown: (event) {
                        _focusNode.requestFocus();
                        _updateAimPosition(event.localPosition, stageSize);
                        final isMouse = event.kind == PointerDeviceKind.mouse;
                        final isPrimaryClick =
                            (event.buttons & kPrimaryMouseButton) != 0;
                        if (!isMouse || isPrimaryClick) {
                          _registerShot(event.localPosition, stageSize);
                        }
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        clipBehavior: Clip.none,
                        children: [
                          Image.asset(
                            'assets/images/background.jpg',
                            fit: BoxFit.cover,
                          ),
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 24 * _zoomFactor,
                            child: IgnorePointer(
                              ignoring: true,
                              child: AnimatedOpacity(
                                duration: const Duration(milliseconds: 180),
                                opacity: _stageWidth > 0 ? 1.0 : 0.0,
                                curve: Curves.easeOut,
                                child: Container(
                                  width: barWidth + 48 * _zoomFactor,
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16 * _zoomFactor,
                                    vertical: 12 * _zoomFactor,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.45),
                                    borderRadius:
                                        BorderRadius.circular(14 * _zoomFactor),
                                    border: Border.all(
                                      width: 1.2,
                                      color: barColor.withOpacity(
                                        0.55 + 0.35 * _proximity,
                                      ),
                                    ),
                                  ),
        child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Worm proximity',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.92),
                                          fontSize: 13 * _zoomFactor,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                      SizedBox(height: 8 * _zoomFactor),
                                      ClipRRect(
                                        borderRadius: BorderRadius.circular(
                                          8 * _zoomFactor,
                                        ),
                                        child: SizedBox(
                                          width: barWidth,
                                          height: barHeight,
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              Container(
                                                color: Colors.white
                                                    .withOpacity(0.08),
                                              ),
                                              Align(
                                                alignment: Alignment.centerLeft,
                                                child: AnimatedContainer(
                                                  duration: const Duration(
                                                    milliseconds: 120,
                                                  ),
                                                  width: fillWidth,
                                                  decoration: BoxDecoration(
                                                    gradient: LinearGradient(
                                                      colors: [
                                                        barColor.withOpacity(
                                                          0.35 + 0.35 * _proximity,
                                                        ),
                                                        barColor,
                                                      ],
                                                    ),
                                                  ),
                                                ),
                                              ),
                                              Center(
                                                child: Text(
                                                  '$proximityPercent%',
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withOpacity(0.95),
                                                    fontSize: 12 * _zoomFactor,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_activeTnt != null)
                            Positioned(
                              left: _activeTnt!.position.dx - _tntSize / 2,
                              bottom: _tankGroundOffset,
                              child: Image.asset(
                                'assets/images/tntImage-Picsart-BackgroundRemover.jpg',
                                width: _tntSize,
                                height: _tntSize,
                                fit: BoxFit.contain,
                              ),
                            ),
                          if (_wormVisibleHeight > 0)
                            Positioned(
                              left: _wormX,
                              bottom: wormBottomOffset,
                              child: Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..scale(wormFacingRight ? 1.0 : -1.0, 1.0),
                                child: Image.asset(
                                  'assets/images/deathWorm.png',
                                  width: _wormWidth,
                                  height: _wormEmergenceHeight,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          ..._explosions.map((explosion) {
                            final progress =
                                (explosion.elapsed / _explosionLifetime)
                                    .clamp(0.0, 1.0);
                            final baseSize =
                                explosionBaseSize * explosion.sizeMultiplier;
                            final size =
                                baseSize * (0.65 + 0.45 * (1 - progress));
                            final opacity = (1 - progress).clamp(0.0, 1.0);

                            return Positioned(
                              left: explosion.position.dx - size / 2,
                              top: explosion.position.dy - size / 2,
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: opacity,
                                  child: Image.asset(
                                    'assets/images/explosion.jpg',
                                    width: size,
                                    height: size,
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            );
                          }),
                          if (_showAimCursor && _aimPosition != null)
                            Positioned(
                              left: _aimPosition!.dx - aimCursorSize / 2,
                              top: _aimPosition!.dy - aimCursorSize / 2,
                              child: IgnorePointer(
                                child: Image.asset(
                                  'assets/images/aimCursor.jpg',
                                  width: aimCursorSize,
                                  height: aimCursorSize,
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          Positioned(
                            left: _tankX,
                            bottom: _tankGroundOffset,
                            child: Transform(
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..scale(_isFacingRight ? 1.0 : -1.0, 1.0),
                              child: Image.asset(
                                'assets/images/blackTank-Picsart-BackgroundRemover.jpg',
                                width: _tankWidth,
                                fit: BoxFit.contain,
                              ),
                            ),
                          ),
                          Positioned(
                            left: 24 * _zoomFactor,
                            top: 24 * _zoomFactor,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.45),
                                borderRadius: BorderRadius.circular(12 * _zoomFactor),
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16 * _zoomFactor,
                                  vertical: 12 * _zoomFactor,
                                ),
                                child: Text(
                                  'Press A / D to move the tank',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16 * _zoomFactor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Positioned(
                            right: 24 * _zoomFactor,
                            top: 24 * _zoomFactor,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.45),
                                borderRadius: BorderRadius.circular(12 * _zoomFactor),
                              ),
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 16 * _zoomFactor,
                                  vertical: 12 * _zoomFactor,
                                ),
        child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Lives: $_lives',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16 * _zoomFactor,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    SizedBox(height: 8 * _zoomFactor),
                                    Text(
                                      'Kills: $_killCount',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 14 * _zoomFactor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    SizedBox(height: 8 * _zoomFactor),
            Text(
                                      'Shot timer: ${timerLabel}s',
                                      style: TextStyle(
                                        color: Colors.white.withOpacity(0.9),
                                        fontSize: 14 * _zoomFactor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (_statusMessage != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: _zoomFactor * 90,
                              child: Center(
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.55),
                                    borderRadius: BorderRadius.circular(16 * _zoomFactor),
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 20 * _zoomFactor,
                                      vertical: 14 * _zoomFactor,
                                    ),
                                    child: Text(
                                      _statusMessage!,
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 16 * _zoomFactor,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          if (_gameOver)
                            Positioned.fill(
                              child: Container(
                                color: Colors.black.withOpacity(0.35),
                                alignment: Alignment.center,
                                child: Text(
                                  'Game Over',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 42 * _zoomFactor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
            ),
          ],
        ),
      ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
