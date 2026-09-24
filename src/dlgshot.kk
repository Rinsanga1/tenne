module dlgshot
import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import app
import view-members
import dlg-members

pub fun main() : io ()
  sql/unbuffer()
  sql/open("out/view.db").ignore
  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600), win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))
  val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(), "Rs", "out", "2025-08", "1500", "500")
  val id = repo/list-members(True).drop(5).map(fn(m : models/member) { models/member/id(m) }).head.default(1)
  shot(r, s0(selected = id), "out/dlg-card.bmp")
  shot(r, s0(confirm-delete = id), "out/dlg-delete.bmp")
  shot(r, s0(form = Just(app/blank-form("2025-08-20", "500", "1500"))), "out/dlg-add.bmp")
  sql/close().ignore

fun shot( r : ref<global,ui/ui>, s : app/state, path : string ) : io ()
  ui/frame-begin(r, [])
  win32/clip-all()
  win32/fill(0, 0, 1180, 720, s.palette.main)
  ui/begin-inert(r)
  app/sidebar(r, s).ignore
  view-members/show(r, s).ignore
  ui/end-inert(r)
  val next = if s.confirm-delete != 0 then dlg-members/confirm-delete(r, s, s.confirm-delete)
             else match s.form
               Just(f) -> dlg-members/member-dialog(r, s, f)
               Nothing -> dlg-members/member-card(r, s, s.selected)
  ui/frame-end(r)
  println(if win32/save-bmp(path) then "wrote " ++ path else "FAILED " ++ path)
