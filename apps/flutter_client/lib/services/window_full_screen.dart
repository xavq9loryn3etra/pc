import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:ui' as ui show Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show ValueNotifier, kIsWeb;
import 'package:window_manager/window_manager.dart';

/// Full screen for the Windows app's window: what the player turns on as a
/// video opens and off as it closes, as a phone hides its bars and turns
/// sideways. Elsewhere every call does nothing.
///
/// Uses Win32 User32 calls directly rather than `windowManager.setFullScreen`,
/// because `window_manager` 0.5.1's `SetFullScreen(true)` skips
/// `SetAsFrameless()` when the window is already maximized and only strips
/// `WS_THICKFRAME | WS_MAXIMIZEBOX` (leaving `WS_CAPTION` on), which turns a
/// maximized window into a bordered dialog-style window with a title bar and
/// 7px DWM gaps around the edges instead of true borderless fullscreen.
class WindowFullScreen {
  WindowFullScreen._();

  static final bool supported = !kIsWeb && Platform.isWindows;

  /// Reactive full-screen state so player controls can update their icon
  /// whether full screen is toggled by button, double-click, F11, or Esc.
  static final ValueNotifier<bool> state = ValueNotifier<bool>(false);

  static int _hwnd = 0;
  static int _savedStyle = 0;
  static bool _wasMaximized = false;
  // Where the window was before full screen, as Windows keeps it: its
  // restored bounds and whether it was maximized (see _exitWin32). Kept
  // for the app's life — it's a few bytes.
  static final Pointer<_WINDOWPLACEMENT> _savedPlacement =
      calloc<_WINDOWPLACEMENT>();
  static bool _hasSavedPlacement = false;

  /// Whether the window is full screen.
  static bool get isOn => state.value;

  /// The smallest the window can be dragged to: a big phone's screen, where
  /// the app takes its phone layout. Smaller squashed it.
  static const ui.Size minimumWindowSize = ui.Size(480, 600);

  /// Called once at startup, before the window is used.
  static Future<void> init() async {
    if (!supported) return;
    await windowManager.ensureInitialized();
    _hwnd = await windowManager.getId();
    try {
      await windowManager.setMinimumSize(minimumWindowSize);
    } catch (_) {}
  }

  static Future<void> set(bool on) async {
    if (!supported || on == state.value) return;
    if (_hwnd == 0) {
      try {
        _hwnd = await windowManager.getId();
      } catch (_) {
        return;
      }
    }
    if (_hwnd == 0) return;

    state.value = on;
    // Defer the Win32 SetWindowPos / MoveWindow calls by a microtask so the
    // synchronous WM_SIZE message they dispatch never triggers a re-entrant
    // Flutter frame build in the middle of a Navigator pop or widget callback.
    await Future<void>.value();
    try {
      if (state.value) {
        _enterWin32(_hwnd);
      } else {
        _exitWin32(_hwnd);
      }
    } catch (_) {
      state.value = !on;
    }
  }

  static Future<void> enter() => set(true);
  static Future<void> exit() => set(false);
  static Future<void> toggle() => set(!state.value);

  static const int _gwlStyle = -16;
  static const int _wsOverlappedWindow = 0x00CF0000;
  static const int _wsMaximize = 0x01000000;
  static const int _monitorDefaultToNearest = 0x00000002;
  static const int _hwndTop = 0;
  static const int _swpNoZOrder = 0x0004;
  static const int _swpFrameChanged = 0x0020;
  static const int _swpNoOwnerZOrder = 0x0200;
  static const int _swpNoMove = 0x0002;
  static const int _swpNoSize = 0x0001;
  static const int _swShowNormal = 1;
  static const int _swShowMaximized = 3;

  static final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');

  static final _isZoomed = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd), int Function(int hWnd)>('IsZoomed');

  static final _getWindowLongPtr = _user32.lookupFunction<
      IntPtr Function(IntPtr hWnd, Int32 nIndex),
      int Function(int hWnd, int nIndex)>('GetWindowLongPtrW');

  static final _setWindowLongPtr = _user32.lookupFunction<
      IntPtr Function(IntPtr hWnd, Int32 nIndex, IntPtr dwNewLong),
      int Function(int hWnd, int nIndex, int dwNewLong)>('SetWindowLongPtrW');

  static final _getWindowPlacement = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Pointer<_WINDOWPLACEMENT> lpwndpl),
      int Function(
          int hWnd, Pointer<_WINDOWPLACEMENT> lpwndpl)>('GetWindowPlacement');

  static final _setWindowPlacement = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Pointer<_WINDOWPLACEMENT> lpwndpl),
      int Function(
          int hWnd, Pointer<_WINDOWPLACEMENT> lpwndpl)>('SetWindowPlacement');

  static final _monitorFromWindow = _user32.lookupFunction<
      IntPtr Function(IntPtr hwnd, Uint32 dwFlags),
      int Function(int hwnd, int dwFlags)>('MonitorFromWindow');

  static final _getMonitorInfo = _user32.lookupFunction<
      Int32 Function(IntPtr hMonitor, Pointer<_MONITORINFO> lpmi),
      int Function(int hMonitor, Pointer<_MONITORINFO> lpmi)>('GetMonitorInfoW');

  static final _setWindowPos = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, IntPtr hWndInsertAfter, Int32 x, Int32 y,
          Int32 cx, Int32 cy, Uint32 uFlags),
      int Function(int hWnd, int hWndInsertAfter, int x, int y, int cx, int cy,
          int uFlags)>('SetWindowPos');

  static final _showWindow = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Int32 nCmdShow),
      int Function(int hWnd, int nCmdShow)>('ShowWindow');

  static final _getClientRect = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Pointer<_RECT> lpRect),
      int Function(int hWnd, Pointer<_RECT> lpRect)>('GetClientRect');

  static final _findWindowEx = _user32.lookupFunction<
      IntPtr Function(IntPtr hWndParent, IntPtr hWndChildAfter,
          Pointer<Utf16> lpszClass, Pointer<Utf16> lpszWindow),
      int Function(int hWndParent, int hWndChildAfter, Pointer<Utf16> lpszClass,
          Pointer<Utf16> lpszWindow)>('FindWindowExW');

  static final _moveWindow = _user32.lookupFunction<
      Int32 Function(IntPtr hWnd, Int32 x, Int32 y, Int32 nWidth, Int32 nHeight,
          Int32 bRepaint),
      int Function(int hWnd, int x, int y, int nWidth, int nHeight,
          int bRepaint)>('MoveWindow');

  static void _enterWin32(int hwnd) {
    _wasMaximized = _isZoomed(hwnd) != 0;
    _savedStyle = _getWindowLongPtr(hwnd, _gwlStyle);

    final monitorInfo = calloc<_MONITORINFO>();
    try {
      _savedPlacement.ref.length = sizeOf<_WINDOWPLACEMENT>();
      _hasSavedPlacement = _getWindowPlacement(hwnd, _savedPlacement) != 0;

      monitorInfo.ref.cbSize = sizeOf<_MONITORINFO>();
      final monitor = _monitorFromWindow(hwnd, _monitorDefaultToNearest);
      _getMonitorInfo(monitor, monitorInfo);

      final left = monitorInfo.ref.rcMonitor.left;
      final top = monitorInfo.ref.rcMonitor.top;
      final width = monitorInfo.ref.rcMonitor.right - left;
      final height = monitorInfo.ref.rcMonitor.bottom - top;

      _setWindowLongPtr(
        hwnd,
        _gwlStyle,
        _savedStyle & ~(_wsOverlappedWindow | _wsMaximize),
      );
      _setWindowPos(
        hwnd,
        _hwndTop,
        left,
        top,
        width,
        height,
        _swpNoOwnerZOrder | _swpFrameChanged,
      );
      _syncFlutterViewSize(hwnd);
    } finally {
      calloc.free(monitorInfo);
    }
  }

  static void _exitWin32(int hwnd) {
    // The standard window style back, without WS_MAXIMIZE: the window is
    // then a plain one, so maximizing it below has Windows work out the
    // maximized size from the work area — the taskbar and title bar show.
    _setWindowLongPtr(
      hwnd,
      _gwlStyle,
      (_savedStyle | _wsOverlappedWindow) & ~_wsMaximize,
    );
    if (_wasMaximized) {
      // Never through its restored size: moving it there and maximizing
      // from it showed the window at that size for a moment — often the
      // smallest, where the player takes its phone layout (its buttons
      // overflowed). Setting the saved placement does the same. So: the
      // work area first (all but the taskbar, about the maximized size),
      // maximized from there — then, maximized, its restored bounds put
      // back for "Restore down", which a maximized window doesn't show.
      final monitorInfo = calloc<_MONITORINFO>();
      try {
        monitorInfo.ref.cbSize = sizeOf<_MONITORINFO>();
        _getMonitorInfo(
            _monitorFromWindow(hwnd, _monitorDefaultToNearest), monitorInfo);
        final work = monitorInfo.ref.rcWork;
        _setWindowPos(
          hwnd,
          0,
          work.left,
          work.top,
          work.right - work.left,
          work.bottom - work.top,
          _swpNoZOrder | _swpNoOwnerZOrder | _swpFrameChanged,
        );
      } finally {
        calloc.free(monitorInfo);
      }
      _showWindow(hwnd, _swShowMaximized);
      if (_hasSavedPlacement) {
        _savedPlacement.ref
          ..flags = 0
          ..showCmd = _swShowMaximized;
        _setWindowPlacement(hwnd, _savedPlacement);
      }
    } else if (_hasSavedPlacement) {
      // Straight back to its size and place from before.
      _savedPlacement.ref
        ..flags = 0
        ..showCmd = _swShowNormal;
      _setWindowPlacement(hwnd, _savedPlacement);
    }
    // The frame (title bar, borders) redrawn for the style.
    _setWindowPos(
      hwnd,
      0,
      0,
      0,
      0,
      0,
      _swpNoMove |
          _swpNoSize |
          _swpNoZOrder |
          _swpNoOwnerZOrder |
          _swpFrameChanged,
    );
    _syncFlutterViewSize(hwnd);
  }

  static void _syncFlutterViewSize(int hwnd) {
    final className = 'FLUTTERVIEW'.toNativeUtf16();
    final rect = calloc<_RECT>();
    try {
      final flutterView = _findWindowEx(hwnd, 0, className, nullptr);
      if (flutterView != 0 && _getClientRect(hwnd, rect) != 0) {
        _moveWindow(
          flutterView,
          rect.ref.left,
          rect.ref.top,
          rect.ref.right - rect.ref.left,
          rect.ref.bottom - rect.ref.top,
          1,
        );
      }
    } finally {
      calloc.free(className);
      calloc.free(rect);
    }
  }
}

final class _POINT extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _RECT extends Struct {
  @Int32()
  external int left;

  @Int32()
  external int top;

  @Int32()
  external int right;

  @Int32()
  external int bottom;
}

final class _WINDOWPLACEMENT extends Struct {
  @Uint32()
  external int length;

  @Uint32()
  external int flags;

  @Uint32()
  external int showCmd;

  external _POINT ptMinPosition;
  external _POINT ptMaxPosition;
  external _RECT rcNormalPosition;
}

final class _MONITORINFO extends Struct {
  @Uint32()
  external int cbSize;

  external _RECT rcMonitor;
  external _RECT rcWork;

  @Uint32()
  external int dwFlags;
}
