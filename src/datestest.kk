module datestest
import dates

fun check( fails : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then fails := !fails + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(28) ++ got.pad-right(26) ++
          (if ok then "" else "want " ++ want))

pub fun main() : io ()
  val f = ref(0)

  check(f, "civil round trip 2026-09-20", dates/civil-from-days(dates/days-from-civil(2026,9,20)).show, "(2026,9,20)")
  check(f, "leap day 2024-02-29",         dates/civil-from-days(dates/days-from-civil(2024,2,29)).show, "(2024,2,29)")
  check(f, "epoch is day 0",              dates/days-from-civil(1970,1,1).show, "0")
  check(f, "2000-03-01 serial",           dates/civil-from-days(dates/days-from-civil(2000,3,1)).show, "(2000,3,1)")

  // 1900 was not a leap year, 2000 was. The rule most hand-rolled date code gets wrong.
  check(f, "1900 not a leap year",        dates/is-valid-date("1900-02-29").show, "False")
  check(f, "2000 was a leap year",        dates/is-valid-date("2000-02-29").show, "True")
  check(f, "2024 leap",                   dates/is-valid-date("2024-02-29").show, "True")
  check(f, "2025 not leap",               dates/is-valid-date("2025-02-29").show, "False")
  check(f, "reject 2025-02-30",           dates/is-valid-date("2025-02-30").show, "False")
  check(f, "reject 2025-13-01",           dates/is-valid-date("2025-13-01").show, "False")
  check(f, "reject short year",           dates/is-valid-date("25-01-01").show, "False")
  check(f, "accept plain date",           dates/is-valid-date("2025-07-08").show, "True")
  check(f, "valid month",                 dates/is-valid-month("2025-07").show, "True")
  check(f, "reject month 13",             dates/is-valid-month("2025-13").show, "False")

  check(f, "days in Feb 2024",            dates/days-in-month(2024,2).show, "29")
  check(f, "days in Feb 2025",            dates/days-in-month(2025,2).show, "28")
  check(f, "days in Dec",                 dates/days-in-month(2025,12).show, "31")

  check(f, "pretty month",                dates/pretty-month("2026-06"), "June 2026")
  check(f, "pretty month passthrough",    dates/pretty-month("nonsense"), "nonsense")
  check(f, "short date",                  dates/short-date("2025-07-08"), "Jul 08")

  check(f, "month-diff forward",          dates/month-diff("2025-01","2025-07").show, "6")
  check(f, "month-diff backward",         dates/month-diff("2025-07","2025-01").show, "-6")
  check(f, "month-diff across years",     dates/month-diff("2024-11","2026-02").show, "15")
  check(f, "month-diff same",             dates/month-diff("2025-07","2025-07").show, "0")
  check(f, "month-diff garbage",          dates/month-diff("x","y").show, "0")

  check(f, "add days over month end",     dates/add-days("2025-01-31", 1), "2025-02-01")
  check(f, "add days over leap",          dates/add-days("2024-02-28", 1), "2024-02-29")
  check(f, "subtract days",               dates/add-days("2025-03-01", -1), "2025-02-28")

  check(f, "months-between",              dates/months-between("2025-11","2026-02").join(","), "2025-11,2025-12,2026-01,2026-02")
  check(f, "months-between reversed",     dates/months-between("2026-02","2025-11").join(","), "")
  check(f, "days-inclusive count",        dates/days-inclusive("2025-02-01","2025-02-28").length.show, "28")
  check(f, "days-inclusive leap count",   dates/days-inclusive("2024-02-01","2024-02-29").length.show, "29")
  check(f, "days-inclusive reversed",     dates/days-inclusive("2025-02-28","2025-02-01").length.show, "0")

  // The filter's SQL range must cover the whole month, last day included.
  val jan = Month-filter(2025, Just(1))
  check(f, "range of January",            jan.range.show, "(\"2025-01-01\",\"2025-01-31\")")
  val feb24 = Month-filter(2024, Just(2))
  check(f, "range of leap February",      feb24.range.show, "(\"2024-02-01\",\"2024-02-29\")")
  val yr = Month-filter(2025, Nothing)
  check(f, "range of whole year",         yr.range.show, "(\"2025-01-01\",\"2025-12-31\")")
  check(f, "previous rolls the year",     jan.previous.label, "December 2024")
  check(f, "previous within a year",      Month-filter(2025, Just(7)).previous.label, "June 2025")
  check(f, "previous of a whole year",    yr.previous.label, "2024")

  println("")
  println("today = " ++ dates/today() ++ "   month = " ++ dates/current-month() ++ "   now = " ++ dates/now())
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
