Deprecated. Use [siwin](https://github.com/levovix0/siwin) instead.

# PixWindy

Windy is a windowing library for Nim that uses OS native APIs to manage windows, set up OpenGL and receive mouse and keyboard input.

`nimble install https://github.com/FolxTeam/pixwindy`

PixWindy will work great for simple 2D applications that does't redraw content too often.  
Using this library should feel similar to [Windy](https://github.com/treeform/windy).

Features:
* Multi-platform (Windows, ~~macOS~~, Linux)
* Manage one or many windows
* Customizable windows (resizable, hidden, fullscreen and more)
* DPI and content-scaling aware
* Mouse input (position, clicks, scroll)
* Double-click, triple-click and quadruple-click events
* Keyboard input (key events + unicode)
* Easy polling of keyboard state via `buttonDown[Button]` and more
* IME support (for Chinese, Japanese etc text input)
* System clipboard (copy and paste) support
* Show a system tray icon and menu (Windows only)

### Documentation

API reference: todo

# Examples

### Simple window

```nim
import pixwindy, pixie

let window = newWindow("simple window", ivec2(1280, 800))

var image = newImage(1280, 800)

proc display =
  image.fill color(1, 1, 1, 1)
  window.draw image

window.onResize = proc =
  if window.size.x * window.size.y == 0: return
  image = newImage(window.size.x, window.size.y)
  display()

display()

while not window.closeRequested:
  pollEvents()
```
