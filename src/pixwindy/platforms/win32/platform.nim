import times, unicode, utils
import pixie except Rect
import pixie/images, pixie/fileformats/png, vmath, flatty/hashy
import ../../common, ../../internal
import windefs

const
  windowClassName = "WINDY0"
  trayIconId = 2022
  defaultScreenDpi = 96
  wheelDelta = 120
  decoratedWindowStyle = WS_OVERLAPPEDWINDOW
  undecoratedWindowStyle = WS_POPUP

  WGL_DRAW_TO_WINDOW_ARB = 0x2001
  WGL_ACCELERATION_ARB = 0x2003
  WGL_SUPPORT_OPENGL_ARB = 0x2010
  WGL_DOUBLE_BUFFER_ARB = 0x2011
  WGL_PIXEL_TYPE_ARB = 0x2013
  WGL_COLOR_BITS_ARB = 0x2014
  WGL_ALPHA_BITS_ARB = 0x201B
  WGL_DEPTH_BITS_ARB = 0x2022
  WGL_STENCIL_BITS_ARB = 0x2023
  WGL_FULL_ACCELERATION_ARB = 0x2027
  WGL_TYPE_RGBA_ARB = 0x202B
  WGL_SAMPLES_ARB = 0x2042

  WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091
  WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092
  WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001
  # WGL_CONTEXT_COMPATIBILITY_PROFILE_BIT_ARB = 0x00000002
  WGL_CONTEXT_FLAGS_ARB = 0x2094
  # WGL_CONTEXT_DEBUG_BIT_ARB = 0x0001
  WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB = 0x0002

  WM_TRAY_ICON = WM_APP + 0

type
  Window* = ref object
    onCloseRequest*: Callback
    onMove*: Callback
    onResize*: Callback
    onFocusChange*: Callback
    onMouseMove*: Callback
    onScroll*: Callback
    onButtonPress*: ButtonCallback
    onButtonRelease*: ButtonCallback
    onRune*: RuneCallback
    onImeChange*: Callback
    imePos*: IVec2

    state: State
    trackMouseEventRegistered: bool
    exitFullscreenInfo: ExitFullscreenInfo

    hWnd: HWND
    hdc: HDC
    buffer: tuple[
      w, h: int;
      bitmap: HBitmap,
      hdc: Hdc,
      pixels: ptr UncheckedArray[tuple[b, g, r, _: uint8]]
    ]

  ExitFullscreenInfo = ref object
    maximized: bool
    style: LONG
    rect: RECT

  TrayMenyEntryKind* = enum
    TrayMenuOption, TrayMenuSeparator

  TrayMenuEntry* = object
    case kind*: TrayMenyEntryKind
    of TrayMenuOption:
      text*: string
      onClick*: Callback
    of TrayMenuSeparator:
      discard

var
  SetProcessDpiAwarenessContext: SetProcessDpiAwarenessContext
  GetDpiForWindow: GetDpiForWindow
  AdjustWindowRectExForDpi: AdjustWindowRectExForDpi

var
  helperWindow: HWND
  windows: seq[Window]
  iconCache: seq[(Hash, HICON)]
  onTrayIconClick: Callback
  trayMenuHandle: HMENU
  trayMenuEntries: seq[TrayMenuEntry]

proc indexForHandle(windows: seq[Window], hWnd: HWND): int =
  ## Returns the window for this handle, else -1
  for i, window in windows:
    if window.hWnd == hWnd:
      return i
  -1

proc forHandle(windows: seq[Window], hWnd: HWND): Window =
  ## Returns the window for this window handle, else nil
  let index = windows.indexForHandle(hWnd)
  if index == -1:
    return nil
  windows[index]

proc registerWindowClass(windowClassName: string, wndProc: WNDPROC) =
  let wideWindowClassName = windowClassName.wstr()

  var wc: WNDCLASSEXW
  wc.cbSize = sizeof(WNDCLASSEXW).UINT
  wc.style = CS_HREDRAW or CS_VREDRAW
  wc.lpfnWndProc = wndProc
  wc.hInstance = GetModuleHandleW(nil)
  wc.hCursor = LoadCursorW(0, IDC_ARROW)
  wc.lpszClassName = cast[ptr WCHAR](wideWindowClassName[0].unsafeAddr)
  wc.hIcon = LoadImageW(
    0,
    IDI_APPLICATION,
    IMAGE_ICON,
    0,
    0,
    LR_DEFAULTSIZE or LR_SHARED
  )

  if RegisterClassExW(wc.addr) == 0:
    raise newException(WindyError, "Error registering window class")

proc createWindow(windowClassName, title: string, size: IVec2): HWND =
  let
    wideWindowClassName = windowClassName.wstr()
    wideTitle = title.wstr()

  var size = size
  if size != ivec2(CW_USEDEFAULT, CW_USEDEFAULT):
    # Adjust the window creation size for window styles (border, etc)
    var rect = Rect(top: 0, left: 0, right: size.x, bottom: size.y)
    discard AdjustWindowRectExForDpi(
      rect.addr,
      decoratedWindowStyle,
      0,
      WS_EX_APPWINDOW,
      defaultScreenDpi
    )
    size.x = rect.right - rect.left
    size.y = rect.bottom - rect.top

  result = CreateWindowExW(
    WS_EX_APPWINDOW,
    cast[ptr WCHAR](wideWindowClassName[0].unsafeAddr),
    cast[ptr WCHAR](wideTitle[0].unsafeAddr),
    decoratedWindowStyle,
    CW_USEDEFAULT,
    CW_USEDEFAULT,
    size.x,
    size.y,
    0,
    0,
    GetModuleHandleW(nil),
    nil
  )
  if result == 0:
    raise newException(WindyError, "Creating native window failed")

  let key = "Windy".wstr()
  discard SetPropW(result, cast[ptr WCHAR](key[0].unsafeAddr), 1)

proc destroy(window: Window) =
  window.onCloseRequest = nil
  window.onMove = nil
  window.onResize = nil
  window.onFocusChange = nil
  window.onMouseMove = nil
  window.onScroll = nil
  window.onButtonPress = nil
  window.onButtonRelease = nil
  window.onRune = nil
  window.onImeChange = nil

  if window.buffer.pixels != nil:
    discard DeleteDC window.buffer.hdc
    discard DeleteObject window.buffer.bitmap
  
  if window.hdc != 0:
    discard ReleaseDC(window.hWnd, window.hdc)
    window.hdc = 0
  
  if window.hWnd != 0:
    let key = "Windy".wstr()
    discard RemovePropW(window.hWnd, cast[ptr WCHAR](key[0].unsafeAddr))
    discard DestroyWindow(window.hWnd)
    let index = windows.indexForHandle(window.hWnd)
    if index != -1:
      windows.delete(index)
    window.hWnd = 0

proc getDC(hWnd: HWND): HDC =
  result = GetDC(hWnd)
  if result == 0:
    raise newException(WindyError, "Error getting window DC")

proc getWindowStyle(hWnd: HWND): LONG =
  GetWindowLongW(hWnd, GWL_STYLE)

proc updateWindowStyle(hWnd: HWND, style: LONG) =
  var rect: RECT
  discard GetClientRect(hWnd, rect.addr)
  discard AdjustWindowRectExForDpi(
    rect.addr,
    style,
    0,
    WS_EX_APPWINDOW,
    GetDpiForWindow(hWnd)
  )

  discard ClientToScreen(hWnd, cast[ptr POINT](rect.left.addr))
  discard ClientToScreen(hWnd, cast[ptr POINT](rect.right.addr))

  discard SetWindowLongW(hWnd, GWL_STYLE, style)

  discard SetWindowPos(
    hWnd,
    HWND_TOP,
    rect.left,
    rect.top,
    rect.right - rect.left,
    rect.bottom - rect.top,
    SWP_FRAMECHANGED or SWP_NOACTIVATE or SWP_NOZORDER
  )

proc monitorInfo(window: Window): MONITORINFO =
  result.cbSize = sizeof(MONITORINFO).DWORD
  discard GetMonitorInfoW(
    MonitorFromWindow(window.hWnd, MONITOR_DEFAULTTONEAREST),
    result.addr
  )

proc visible*(window: Window): bool =
  IsWindowVisible(window.hWnd) != 0

proc style*(window: Window): WindowStyle =
  let style = getWindowStyle(window.hWnd)
  if (style and WS_THICKFRAME) != 0:
    return DecoratedResizable
  if (style and WS_BORDER) != 0:
    return Decorated
  Undecorated

proc fullscreen*(window: Window): bool =
  window.exitFullscreenInfo != nil

proc size*(window: Window): IVec2 =
  var rect: RECT
  discard GetClientRect(window.hWnd, rect.addr)
  ivec2(rect.right, rect.bottom)

proc pos*(window: Window): IVec2 =
  var pos: POINT
  discard ClientToScreen(window.hWnd, pos.addr)
  ivec2(pos.x, pos.y)

proc minimized*(window: Window): bool =
  IsIconic(window.hWnd) != 0

proc maximized*(window: Window): bool =
  IsZoomed(window.hWnd) != 0

proc framebufferSize*(window: Window): IVec2 =
  window.size

proc contentScale*(window: Window): float32 =
  let dpi = GetDpiForWindow(window.hWnd)
  result = dpi.float32 / defaultScreenDpi

proc focused*(window: Window): bool =
  window.hWnd == GetActiveWindow()

proc `title=`*(window: Window, title: string) =
  window.state.title = title
  var wideTitle = title.wstr()
  discard SetWindowTextW(window.hWnd, cast[ptr WCHAR](wideTitle[0].addr))

proc `visible=`*(window: Window, visible: bool) =
  if visible:
    discard ShowWindow(window.hWnd, SW_SHOW)
  else:
    discard ShowWindow(window.hWnd, SW_HIDE)

proc `style=`*(window: Window, windowStyle: WindowStyle) =
  if window.fullscreen:
    return

  var style: Long

  case windowStyle:
  of DecoratedResizable:
    style = decoratedWindowStyle or (WS_MAXIMIZEBOX or WS_THICKFRAME)
  of Decorated:
    style = decoratedWindowStyle and not (WS_MAXIMIZEBOX or WS_THICKFRAME)
  of Undecorated:
    style = undecoratedWindowStyle

  if window.visible:
    style = style or WS_VISIBLE

  updateWindowStyle(window.hWnd, style)

proc `fullscreen=`*(window: Window, fullscreen: bool) =
  if window.fullscreen == fullscreen:
    return

  if fullscreen:
    # Save some window info for restoring when exiting fullscreen
    window.exitFullscreenInfo = ExitFullscreenInfo()
    window.exitFullscreenInfo.maximized = window.maximized
    if window.maximized:
      discard SendMessageW(window.hWnd, WM_SYSCOMMAND, SC_RESTORE, 0)
    window.exitFullscreenInfo.style = getWindowStyle(window.hWnd)
    discard GetWindowRect(window.hWnd, window.exitFullscreenInfo.rect.addr)

    var style = undecoratedWindowStyle

    if window.visible:
      style = style or WS_VISIBLE

    discard SetWindowLongW(window.hWnd, GWL_STYLE, style)

    let mi = window.monitorInfo
    discard SetWindowPos(
      window.hWnd,
      HWND_TOPMOST,
      mi.rcMonitor.left,
      mi.rcMonitor.top,
      mi.rcMonitor.right - mi.rcMonitor.left,
      mi.rcMonitor.bottom - mi.rcMonitor.top,
      SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED
    )
  else:
    var style = window.exitFullscreenInfo.style

    if window.visible:
      style = style or WS_VISIBLE
    else:
      style = style and (not WS_VISIBLE)

    discard SetWindowLongW(window.hWnd, GWL_STYLE, style)

    let
      maximized = window.exitFullscreenInfo.maximized
      rect = window.exitFullscreenInfo.rect

    # Make sure window.fullscreen returns false in the resize callbacks
    # that get triggered after this.
    window.exitFullscreenInfo = nil

    discard SetWindowPos(
      window.hWnd,
      HWND_TOP,
      rect.left,
      rect.top,
      rect.right - rect.left,
      rect.bottom - rect.top,
      SWP_NOZORDER or SWP_NOACTIVATE or SWP_FRAMECHANGED
    )

    if maximized:
      discard SendMessageW(window.hWnd, WM_SYSCOMMAND, SC_MAXIMIZE, 0)

proc `size=`*(window: Window, size: IVec2) =
  if window.fullscreen:
    return

  var rect = RECT(top: 0, left: 0, right: size.x, bottom: size.y)
  discard AdjustWindowRectExForDpi(
    rect.addr,
    getWindowStyle(window.hWnd),
    0,
    WS_EX_APPWINDOW,
    GetDpiForWindow(window.hWnd)
  )
  discard SetWindowPos(
    window.hWnd,
    HWND_TOP,
    0,
    0,
    rect.right - rect.left,
    rect.bottom - rect.top,
    SWP_NOACTIVATE or SWP_NOZORDER or SWP_NOMOVE
  )

proc `pos=`*(window: Window, pos: IVec2) =
  if window.fullscreen:
    return

  var rect = RECT(top: pos.y, left: pos.x, bottom: pos.y, right: pos.x)
  discard AdjustWindowRectExForDpi(
    rect.addr,
    getWindowStyle(window.hWnd),
    0,
    WS_EX_APPWINDOW,
    GetDpiForWindow(window.hWnd)
  )
  discard SetWindowPos(
    window.hWnd,
    HWND_TOP,
    rect.left,
    rect.top,
    0,
    0,
    SWP_NOACTIVATE or SWP_NOZORDER or SWP_NOSIZE
  )

proc `minimized=`*(window: Window, minimized: bool) =
  var cmd: int32
  if minimized:
    cmd = SW_MINIMIZE
  else:
    cmd = SW_RESTORE
  discard ShowWindow(window.hWnd, cmd)

proc `maximized=`*(window: Window, maximized: bool) =
  var cmd: int32
  if maximized:
    cmd = SW_MAXIMIZE
  else:
    cmd = SW_RESTORE
  discard ShowWindow(window.hWnd, cmd)

proc `closeRequested=`*(window: Window, closeRequested: bool) =
  window.state.closeRequested = closeRequested
  if closeRequested:
    if window.onCloseRequest != nil:
      window.onCloseRequest()

proc `runeInputEnabled=`*(window: Window, runeInputEnabled: bool) =
  window.state.runeInputEnabled = runeInputEnabled
  if runeInputEnabled:
    discard ImmAssociateContextEx(window.hWnd, 0, IACE_DEFAULT)
  else:
    discard ImmAssociateContextEx(window.hWnd, 0, 0)

proc loadLibraries() =
  let user32 = LoadLibraryA("user32.dll")
  if user32 == 0:
    raise newException(WindyError, "Error loading user32.dll")

  SetProcessDpiAwarenessContext = cast[SetProcessDpiAwarenessContext](
    GetProcAddress(user32, "SetProcessDpiAwarenessContext")
  )
  GetDpiForWindow = cast[GetDpiForWindow](
    GetProcAddress(user32, "GetDpiForWindow")
  )
  AdjustWindowRectExForDpi = cast[AdjustWindowRectExForDpi](
    GetProcAddress(user32, "AdjustWindowRectExForDpi")
  )

proc createHelperWindow(): HWND =
  let helperWindowClassName = "WindyHelper"

  proc helperWndProc(
    hWnd: HWND,
    uMsg: UINT,
    wParam: WPARAM,
    lParam: LPARAM
  ): LRESULT {.stdcall.} =
    case uMsg:
    of WM_APP:
      let innerMsg = LOWORD(lParam)
      case innerMsg:
      of WM_LBUTTONUP:
        if onTrayIconClick != nil:
          onTrayIconClick()
      of WM_RBUTTONUP:
        if trayMenuHandle > 0:
          var pos: POINT
          discard GetCursorPos(pos.addr)
          let clicked = TrackPopupMenu(
            trayMenuHandle,
            TPM_RETURNCMD,
            pos.x,
            pos.y,
            0,
            helperWindow,
            nil
          ).int
          if clicked > 0:
            if trayMenuEntries[clicked - 1].onClick != nil:
              trayMenuEntries[clicked - 1].onClick()
      else:
        discard
      return 0
    else:
      DefWindowProcW(hWnd, uMsg, wParam, lParam)

  registerWindowClass(helperWindowClassName, helperWndProc)

  result = createWindow(
    helperWindowClassName,
    helperWindowClassName,
    ivec2(CW_USEDEFAULT, CW_USEDEFAULT)
  )

proc handleButtonPress(window: Window, button: Button) =
  handleButtonPressTemplate()

proc handleButtonRelease(window: Window, button: Button) =
  handleButtonReleaseTemplate()

proc handleRune(window: Window, rune: Rune) =
  handleRuneTemplate()

proc wndProc(
  hWnd: HWND,
  uMsg: UINT,
  wParam: WPARAM,
  lParam: LPARAM
): LRESULT {.stdcall.} =
  # echo wmEventName(uMsg)
  let
    key = "Windy".wstr()
    data = GetPropW(hWnd, cast[ptr WCHAR](key[0].unsafeAddr))
  if data == 0:
    # This event is for a window being created (CreateWindowExW has not returned)
    return DefWindowProcW(hWnd, uMsg, wParam, lParam)

  let window = windows.forHandle(hWnd)
  if window == nil:
    return

  case uMsg:
  of WM_CLOSE:
    window.closeRequested = true
    return 0
  of WM_MOVE:
    if window.onMove != nil:
      window.onMove()
    return 0
  of WM_SIZE:
    if window.onResize != nil:
      window.onResize()
    return 0
  of WM_SETFOCUS, WM_KILLFOCUS:
    if window.onFocusChange != nil:
      window.onFocusChange()
    return 0
  of WM_DPICHANGED:
    # Resize to the suggested size (this triggers WM_SIZE)
    let suggested = cast[ptr RECT](lParam)
    discard SetWindowPos(
      window.hWnd,
      HWND_TOP,
      suggested.left,
      suggested.top,
      suggested.right - suggested.left,
      suggested.bottom - suggested.top,
      SWP_NOACTIVATE or SWP_NOZORDER
    )
    return 0
  of WM_MOUSEMOVE:
    window.state.perFrame.mousePrevPos = window.state.mousePos
    var pos: POINT
    discard GetCursorPos(pos.addr)
    discard ScreenToClient(window.hWnd, pos.addr)
    window.state.mousePos = ivec2(pos.x, pos.y)
    window.state.perFrame.mouseDelta =
      window.state.mousePos - window.state.perFrame.mousePrevPos
    if window.onMouseMove != nil:
      window.onMouseMove()
    if not window.trackMouseEventRegistered:
      var tme: TRACKMOUSEEVENTSTRUCT
      tme.cbSize = sizeof(TRACKMOUSEEVENTSTRUCT).DWORD
      tme.dwFlags = TME_LEAVE
      tme.hWndTrack = window.hWnd
      discard TrackMouseEvent(tme.addr)
      window.trackMouseEventRegistered = true
    return 0
  of WM_MOUSELEAVE:
    window.trackMouseEventRegistered = false
    return 0
  of WM_MOUSEWHEEL:
    let hiword = HIWORD(wParam)
    window.state.perFrame.scrollDelta = vec2(0, hiword.float32 / wheelDelta)
    if window.onScroll != nil:
      window.onScroll()
    return 0
  of WM_MOUSEHWHEEL:
    let hiword = HIWORD(wParam)
    window.state.perFrame.scrollDelta = vec2(hiword.float32 / wheelDelta, 0)
    if window.onScroll != nil:
      window.onScroll()
    return 0
  of WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN,
    WM_LBUTTONUP, WM_RBUTTONUP, WM_MBUTTONUP, WM_XBUTTONUP:
    let button =
      case uMsg:
      of WM_LBUTTONDOWN, WM_LBUTTONUP:
        MouseLeft
      of WM_RBUTTONDOWN, WM_RBUTTONUP:
        MouseRight
      of WM_XBUTTONDOWN, WM_XBUTTONUP:
        if HIWORD(wParam) == XBUTTON1:
          MouseButton4
        else:
          MouseButton5
      else:
        MouseMiddle
    if uMsg in {WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN}:
      window.handleButtonPress(button)
      if button == MouseLeft:
        discard SetCapture(window.hWnd)
    else:
      window.handleButtonRelease(button)
      if button == MouseLeft:
        discard ReleaseCapture()
    return 0
  of WM_KEYDOWN, WM_SYSKEYDOWN, WM_KEYUP, WM_SYSKEYUP:
    if wParam == VK_PROCESSKEY:
      # IME
      discard
    elif wParam == VK_SNAPSHOT:
      window.handleButtonPress(KeyPrintScreen)
      window.handleButtonRelease(KeyPrintScreen)
    else:
      let
        scancode = (HIWORD(lParam) and (KF_EXTENDED or 0xff))
        button = scancodeToButton[scancode]
      if button != ButtonUnknown:
        if (HIWORD(lParam) and KF_UP) == 0:
          window.handleButtonPress(button)
        else:
          window.handleButtonRelease(button)
      return 0
  of WM_CHAR, WM_SYSCHAR, WM_UNICHAR:
    if uMsg == WM_UNICHAR and wParam == UNICODE_NOCHAR:
      return TRUE
    let codepoint = wParam.uint32
    window.handleRune(Rune(codepoint))
    return 0
  of WM_IME_STARTCOMPOSITION:
    let hIMC = ImmGetContext(window.hWnd)

    var compositionPos: COMPOSITIONFORM
    compositionPos.dwStyle = CFS_POINT
    compositionPos.ptCurrentPos = POINT(x: window.imePos.x, y: window.imePos.y)
    discard ImmSetCompositionWindow(hIMC, compositionPos.addr)

    var candidatePos: CANDIDATEFORM
    candidatePos.dwIndex = 0
    candidatePos.dwStyle = CFS_CANDIDATEPOS
    candidatePos.ptCurrentPos = POINT(x: window.imePos.x, y: window.imePos.y)
    discard ImmSetCandidateWindow(hIMC, candidatePos.addr)

    var exclude: CANDIDATEFORM
    exclude.dwIndex = 0
    exclude.dwStyle = CFS_EXCLUDE
    exclude.ptCurrentPos = POINT(x: window.imePos.x, y: window.imePos.y)
    exclude.rcArea = RECT(
      left: window.imePos.x,
      top: window.imePos.y,
      right: window.imePos.x + 1,
      bottom: window.imePos.x + 1
    )
    discard ImmSetCandidateWindow(hIMC, exclude.addr)

    discard ImmReleaseContext(window.hWnd, hIMC)
    return 0
  of WM_IME_COMPOSITION:
    let hIMC = ImmGetContext(window.hWnd)

    if (lParam and GCS_CURSORPOS) != 0:
      window.state.imeCursorIndex = ImmGetCompositionStringW(
        hIMC, GCS_CURSORPOS, nil, 0
      )

    if (lParam and GCS_COMPSTR) != 0:
      let len = ImmGetCompositionStringW(
        hIMC, GCS_COMPSTR, nil, 0
      )
      if len > 0:
        var buf = newString(len + 1) # Include 1 extra byte for WCHAR null terminator
        discard ImmGetCompositionStringW(
          hIMC, GCS_COMPSTR, buf[0].addr, len
        )
        window.state.imeCompositionString = $cast[ptr WCHAR](buf[0].addr)
      else:
        window.state.imeCompositionString = ""

    if (lParam and GCS_RESULTSTR) != 0:
      # The input runes will come in through WM_CHAR events
      window.state.imeCursorIndex = 0
      window.state.imeCompositionString = ""

    if (lParam and (GCS_CURSORPOS or GCS_COMPSTR or GCS_RESULTSTR)) != 0:
      # If we received a message that updates IME state, trigger the callback
      if window.onImeChange != nil:
        window.onImeChange()

    discard ImmReleaseContext(window.hWnd, hIMC)
    # Do not return 0 here
  else:
    discard

  DefWindowProcW(hWnd, uMsg, wParam, lParam)

proc init() =
  if initialized:
    return
  loadLibraries()
  discard SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)
  helperWindow = createHelperWindow()
  registerWindowClass(windowClassName, wndProc)
  platformDoubleClickInterval = GetDoubleClickTime().float64 / 1000
  initialized = true

proc pollEvents*() =
  # Clear all per-frame data
  for window in windows:
    window.state.perFrame = PerFrame()

  var msg: MSG
  while PeekMessageW(msg.addr, 0, 0, 0, PM_REMOVE) > 0:
    if msg.message == WM_QUIT:
      for window in windows:
        discard wndProc(window.hwnd, WM_CLOSE, 0, 0)
    else:
      discard TranslateMessage(msg.addr)
      discard DispatchMessageW(msg.addr)

  let activeWindow = windows.forHandle(GetActiveWindow())
  if activeWindow != nil:
    # When both shift keys are down the first one released does not trigger a
    # key up event so we fake it here.
    if KeyLeftShift in activeWindow.state.buttonDown:
      if (GetKeyState(VK_LSHIFT) and KF_UP) == 0:
        activeWindow.handleButtonRelease(KeyLeftShift)
    if KeyRightShift in activeWindow.state.buttonDown:
      if (GetKeyState(VK_RSHIFT) and KF_UP) == 0:
        activeWindow.handleButtonRelease(KeyRightShift)

proc draw*(window: Window, image: Image) =
  var ps: PaintStruct
  discard window.hwnd.BeginPaint(ps.addr)
  defer: discard window.hwnd.EndPaint(ps.addr)

  if image.width * image.height == 0: return
  # assert image.width == window.size.x and image.height == window.size.y
  
  if image.width != window.buffer.w or image.height != window.buffer.h:
    if window.buffer.pixels != nil:
      discard DeleteDC window.buffer.hdc
      discard DeleteObject window.buffer.bitmap
    
    window.buffer.w = image.width
    window.buffer.h = image.height
  
    var bmi = BitmapInfo(
      header: BitmapInfoHeader(
        size: BitmapInfoHeader.sizeof.int32, w: image.width.Long, h: -image.height.Long,
        planes: 1, bitCount: 32, compression: Bi_rgb
      )
    )
    window.buffer.bitmap = CreateDibSection(0, bmi.addr, Dib_rgb_colors, cast[ptr pointer](window.buffer.pixels.addr), 0, 0)
    window.buffer.hdc = CreateCompatibleDC(0)
    discard window.buffer.hdc.SelectObject window.buffer.bitmap
  
  var rect: Rect
  discard window.hwnd.GetClientRect(rect.addr)
  for i, c in image.data:
    let px = window.buffer.pixels[i].addr
    px[].b = c.b
    px[].g = c.g
    px[].r = c.r
    
  discard window.hdc.BitBlt(0, 0, rect.right, rect.bottom, window.buffer.hdc, 0, 0, SrcCopy)

proc close*(window: Window) =
  destroy window
  window.state.closed = true
  window.state.closeRequested = true

proc closeIme*(window: Window) =
  let hIMC = ImmGetContext(window.hWnd)
  if hIMC != 0:
    discard ImmNotifyIME(hIMC, NI_COMPOSITIONSTR, CPS_CANCEL, 0)
    discard ImmReleaseContext(window.hWnd, hIMC)
    window.state.imeCursorIndex = 0
    window.state.imeCompositionString = ""
    if window.onImeChange != nil:
      window.onImeChange()

proc newWindow*(
  title: string,
  size: IVec2,
  visible = true,
  vsync = true,
  openglMajorVersion = 4,
  openglMinorVersion = 1,
  msaa = msaaDisabled,
  depthBits = 24,
  stencilBits = 8
): Window =
  init()

  result = Window()
  result.title = title
  result.hWnd = createWindow(
    windowClassName,
    title,
    size
  )

  try:
    result.hdc = getDC(result.hWnd)

    # The first call to ShowWindow may ignore the parameter so do an initial
    # call to clear that behavior.
    discard ShowWindow(result.hWnd, SW_HIDE)

    windows.add(result)

    result.visible = visible
  except WindyError as e:
    destroy result
    raise e

proc title*(window: Window): string =
  window.state.title

proc mousePos*(window: Window): IVec2 =
  window.state.mousePos

proc mousePrevPos*(window: Window): IVec2 =
  window.state.perFrame.mousePrevPos

proc mouseDelta*(window: Window): IVec2 =
  window.state.perFrame.mouseDelta

proc scrollDelta*(window: Window): Vec2 =
  window.state.perFrame.scrollDelta

proc runeInputEnabled*(window: Window): bool =
  window.state.runeInputEnabled

proc imeCursorIndex*(window: Window): int =
  window.state.imeCursorIndex

proc imeCompositionString*(window: Window): string =
  window.state.imeCompositionString

proc closeRequested*(window: Window): bool =
  window.state.closeRequested

proc closed*(window: Window): bool =
  window.state.closed

proc buttonDown*(window: Window): ButtonView =
  window.state.buttonDown.ButtonView

proc buttonPressed*(window: Window): ButtonView =
  window.state.perFrame.buttonPressed.ButtonView

proc buttonReleased*(window: Window): ButtonView =
  window.state.perFrame.buttonReleased.ButtonView

proc buttonToggle*(window: Window): ButtonView =
  window.state.buttonToggle.ButtonView

proc getClipboardString*(): string =
  init()

  if IsClipboardFormatAvailable(CF_UNICODETEXT) == FALSE:
    return ""

  if OpenClipboard(helperWindow) == 0:
    return ""

  let dataHandle = GetClipboardData(CF_UNICODETEXT)
  if dataHandle != 0:
    let p = cast[ptr WCHAR](GlobalLock(dataHandle))
    if p != nil:
      result = $p
      discard GlobalUnlock(dataHandle)

  discard CloseClipboard()

proc setClipboardString*(value: string) =
  init()

  var wideValue = value.wstr()

  let dataHandle = GlobalAlloc(
    GMEM_MOVEABLE,
    wideValue.len + 2 # Include uint16 null terminator
  )
  if dataHandle == 0:
    return

  let p = GlobalLock(dataHandle)
  if p == nil:
    discard GlobalFree(dataHandle)
    return

  copyMem(p, wideValue[0].addr, wideValue.len)

  discard GlobalUnlock(dataHandle)

  if OpenClipboard(helperWindow) == 0:
    discard GlobalFree(dataHandle)
    return

  discard EmptyClipboard()
  discard SetClipboardData(CF_UNICODETEXT, dataHandle)
  discard CloseClipboard()

proc createIconHandle(image: Image): HICON =
  let iconHash = hashy(image.data[0].addr, image.data.len * 4)

  for (hash, handle) in iconCache:
    if iconHash == hash:
      result = handle
      break

  if result == 0:
    let encoded = image.encodePng()
    result = CreateIconFromResourceEx(
      cast[PBYTE](encoded[0].unsafeAddr),
      encoded.len.DWORD,
      TRUE,
      0x00030000,
      0,
      0,
      0
    )

    if result != 0:
      iconCache.add((iconHash, result))
    else:
      raise newException(WindyError, "Error creating tray icon")

proc showTrayIcon*(
  icon: Image,
  tooltip: string,
  onClick: Callback,
  menu: seq[TrayMenuEntry] = @[]
) =
  if trayMenuHandle != 0:
    discard DestroyMenu(trayMenuHandle)
    trayMenuHandle = 0
    trayMenuEntries = @[]

  if menu.len > 0:
    trayMenuEntries = menu
    trayMenuHandle = CreatePopupMenu()
    for i, entry in menu:
      case entry.kind:
      of TrayMenuOption:
        let wstr = entry.text.wstr()
        discard AppendMenuW(
          trayMenuHandle,
          MF_STRING,
          (i + 1).UINT_PTR,
          cast[ptr WCHAR](wstr[0].unsafeAddr)
        )
      of TrayMenuSeparator:
        discard AppendMenuW(trayMenuHandle, MF_SEPARATOR, 0, nil)

  onTrayIconClick = onClick

  var nid: NOTIFYICONDATAW
  nid.cbSize = sizeof(NOTIFYICONDATAW).DWORD
  nid.hWnd = helperWindow
  nid.uID = trayIconId
  nid.uFlags = NIF_MESSAGE or NIF_ICON
  nid.uCallbackMessage = WM_TRAY_ICON
  nid.hIcon = icon.createIconHandle()
  nid.union1.uVersion = NOTIFYICON_VERSION_4

  if tooltip != "":
    nid.uFlags = nid.uFlags or NIF_TIP or NIF_SHOWTIP

    let wstr = tooltip.wstr()
    copyMem(
      nid.szTip[0].addr,
      wstr[0].unsafeAddr,
      min(nid.szTip.high, wstr.high) * 2 # Leave room for null terminator
    )

  discard Shell_NotifyIconW(NIM_ADD, nid.addr)

proc hideTrayIcon*() =
  var nid: NOTIFYICONDATAW
  nid.cbSize = sizeof(NOTIFYICONDATAW).DWORD
  nid.hWnd = helperWindow
  nid.uID = trayIconId

  discard Shell_NotifyIconW(NIM_DELETE, nid.addr)

  onTrayIconClick = nil

  if trayMenuHandle != 0:
    discard DestroyMenu(trayMenuHandle)
    trayMenuHandle = 0
    trayMenuEntries = @[]
