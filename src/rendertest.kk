module rendertest

import win32

pub fun main() : io ()
  win32/offscreen(640, 260)
  val ok1 = win32/font-file("assets/fonts/Geist-Regular.ttf")
  val ok2 = win32/font-file("assets/fonts/Geist-SemiBold.ttf")
  println("font files loaded: " ++ ok1.show ++ " " ++ ok2.show)

  val body = win32/font("Geist", 14, 400)
  val head = win32/font("Geist SemiBold", 20, 600)
  println("body face = '" ++ win32/font-face(body) ++ "' ascent=" ++ win32/font-ascent(body).show)
  println("head face = '" ++ win32/font-face(head) ++ "' ascent=" ++ win32/font-ascent(head).show)

  win32/clip-all()
  win32/fill(0, 0, 640, 260, 0xFF15191E)
  win32/fill(0, 0, 210, 260, 0xFF1B2027)

  win32/text(head, 16, 34, "TenneCRM", 0xFFF2F4F7)
  win32/text(body, 16, 56, "Bright Star Gym", 0xFF8A94A6)

  win32/text(body, 16, 96,  "Dashboard", 0xFF8A94A6)
  win32/fill(0, 106, 210, 28, 0xFF2A3341)
  win32/text(body, 16, 125, "Members", 0xFFF2F4F7)
  win32/text(body, 16, 154, "Shop", 0xFF8A94A6)

  win32/text(head, 240, 40, "Members", 0xFFF2F4F7)
  win32/text(body, 240, 72, "Priya Lalthanmawii", 0xFFE4E8EF)
  win32/text(body, 240, 96, "Paid  Rs 1,500  -  joined 2024-11", 0xFF8A94A6)
  win32/text(body, 240, 126, "Zonunsanga", 0xFFE4E8EF)
  win32/text(body, 240, 150, "Due   Rs 3,000  -  2 months", 0xFFE06C75)

  // measurement must agree with what was drawn
  val s = "Rs 1,500"
  val w = win32/text-width(body, s)
  win32/fill(240, 186, w, 22, 0xFF2A3341)
  win32/text(body, 240, 202, s, 0xFF9CCC65)
  win32/fill(240 + w, 186, 2, 22, 0xFFE06C75)
  println("measured '" ++ s ++ "' = " ++ w.show ++ "px")

  println(if win32/save-bmp("out/text.bmp") then "wrote out/text.bmp" else "FAILED")
