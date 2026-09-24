// The tracer bullet, made checkable: a real database, through the real
// repository, through the real Members view, onto real pixels -- with no
// window and no human.
module viewshot

import std/num/float64
import win32
import sql
import db
import ui
import theme
import widgets
import models
import repo
import dates
import app
import view-members

fun seed( path : string ) : io ()
  if sql/file-exists(path) then sql/remove-file(path).ignore
  db/open-db(path).ignore
  repo/set-setting("gym_name", "Bright Star Gym").ignore

  // A gym part-way through the year: some paid up, some behind, one lapsed.
  [("Priya Lalthanmawii", "9862011234", "2025-01-15", True,  6),
   ("Zonunsanga",         "9436152200", "2025-02-17", True,  0),
   ("Lalrinpuia",         "",           "2024-07-21", False, 2),
   ("Vanlalruati Chhangte","9612440099","2025-03-02", True,  4),
   ("Lalhmingliana Ralte","9856120044", "2025-01-08", True,  6),
   ("Zothansangi",        "9774005512", "2025-04-30", True,  1),
   ("Malsawmtluanga",     "9615003388", "2025-05-14", True,  2),
   ("Rosangliani",        "9862774411", "2025-06-19", True,  1)]
    .foreach fn(row)
      val (name, phone, joined, active, months) = row
      val ph = if phone == "" then Nothing else Just(phone)
      val id = repo/create-member(Member(0, name, ph, Nothing, joined, active, Nothing),
                                  500.0, Nothing, joined.list.take(7).string, joined)
      // pay `months` consecutive months from the join month
      match dates/parse-month(joined.list.take(7).string)
        Just((y, m)) -> list(0, months - 1).foreach fn(k)
          val (yy, mm) = dates/add-months-ym(y, m, k)
          repo/insert-payment(Payment(0, id, dates/fmt-month(yy, mm), 1500.0,
                                      dates/fmt-date(yy, mm, 5), Nothing,
                                      models/cat-membership)).ignore
        Nothing -> ()

pub fun main() : io ()
  sql/unbuffer()
  val path = "out/view.db"
  seed(path)

  win32/offscreen(1180, 720)
  win32/font-file("assets/fonts/Geist-Regular.ttf").ignore
  win32/font-file("assets/fonts/Geist-SemiBold.ttf").ignore
  val r = ref(ui/new-ui(win32/font("Geist", 14, 400), win32/font("Geist SemiBold", 15, 600), win32/font("Geist", 12, 400), win32/font("Geist SemiBold", 30, 600)))

  val s0 = app/new-state(theme/palette-of("dark"), repo/gym-name(),
                         repo/currency(), "out", "2025-08", "1500", "500")

  println("members in database: " ++ repo/count-members(False).show)
  println("active: " ++ repo/count-members(True).show)
  println("owing in 2025-08: " ++ repo/due-members-with-arrears("2025-08").length.show)

  // Frame 1: the list as it opens.
  val s1 = frame(r, s0, [win32/Event(win32/ev-mouse-move, 600, 300, 0)])
  println(if win32/save-bmp("out/members.bmp") then "wrote out/members.bmp" else "FAILED")

  // Frame 2: searching narrows it, live, with no cache to invalidate.
  val s2 = frame(r, s1(search = "lal"), [])
  println("search 'lal' shows: " ++
          repo/search-members("lal", True).map(fn(m : models/member) { m.name }).join(", "))
  println(if win32/save-bmp("out/members-search.bmp") then "wrote out/members-search.bmp" else "FAILED")

  // Frame 3: a search that matches nobody must say so, not show an empty grid.
  frame(r, s1(search = "zzzz"), [])
  println(if win32/save-bmp("out/members-empty.bmp") then "wrote out/members-empty.bmp" else "FAILED")
  sql/close().ignore

fun frame( r : ref<global,ui/ui>, s : app/state,
           evs : list<win32/event> ) : io app/state
  ui/frame-begin(r, evs)
  win32/clip-all()
  win32/fill(0, 0, win32/width(), win32/height(), s.palette.main)
  app/sidebar(r, s).ignore
  val next = view-members/show(r, s)
  ui/frame-end(r)
  next
