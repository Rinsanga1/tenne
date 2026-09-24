module shopshot
import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import repo2
import app
import view-shop
import dlg-shop

pub fun main() : io ()
  sql/unbuffer()
  sql/open("out/dash.db").ignore
  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600),
                        win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(), "Rs", "out", "2025-08", "1500", "500")
  shot(r, s0(view = Shop), "out/shop.bmp", False)
  shot(r, s0(view = Shop, sale = Just(app/blank-sale("2025-08-20"))), "out/shop-sale.bmp", True)
  sql/close().ignore

fun shot( r : ref<global,ui/ui>, s : app/state, path : string, modal : bool ) : io ()
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  if modal then ui/begin-inert(r)
  app/sidebar(r, s).ignore
  view-shop/show(r, s).ignore
  if modal then ui/end-inert(r)
  if modal then dlg-shop/sale-dialog(r, s, s.sale.default(app/blank-sale(""))).ignore
  ui/frame-end(r)
  println(if win32/save-bmp(path) then "wrote " ++ path else "FAILED " ++ path)
