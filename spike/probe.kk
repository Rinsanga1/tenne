extern import
  c file "probe-inline.c"

extern msgbox( s : string ) : int
  c "kk_win32_msgbox"

pub fun main()
  val r = msgbox("hello from koka -> Win32")
  println("MessageBox returned: " ++ r.show)
