// The licence check, which is the one piece of this program a customer has a
// motive to defeat. Two halves are tested: that a key we minted verifies, and
// that anything else does not -- the second half is the one that matters, and
// the one a broken FFI would quietly turn into "everything passes".
module lictest

import sql
import db
import repo
import repo2
import license
import models
import win32

fun check( f : ref<global,int>, name : string, got : string, want : string ) : io ()
  val ok = got == want
  if !ok then f := !f + 1
  println((if ok then "  ok   " else "  FAIL ") ++ name.pad-right(44) ++ got.pad-right(24) ++
          (if ok then "" else "want " ++ want))

// Minted by ./mintkey.sh against license-private.pem. The licensee name says
// what it is on purpose: this key does unlock a build, so if it ever escapes,
// the copy it unlocks announces itself in Settings and on every report.
val fixture = "AEAATF2U-MVXG4ZKD-KJGSAVDF-ON2CARTJ-PB2HK4TF-ZM63EPUA-2Y3WAE3L-6MKMTBEF-" ++
              "IHRFT5FG-MJGBX2JF-6LQBDXBZ-FAU5IF2M-PP52ZWYI-IN3KPQ5L-ZHXM5NIR-DQPFJPV4-" ++
              "VK3C2VUZ-T6C65AI"

// A second licensee, bought on the epoch date, so the name and date that come
// back are demonstrably read from the signed payload and not from anywhere else.
val ada = "AEAAAACB-MRQX7ZTP-EPAOB426-FUOOKIZQ-KLY6ADIO-RSIANG4K-PUWXOHD6-KOZNRIFB-" ++
          "M3VPDQW4-KGJJHIBJ-PBGKCA3M-VH73YWJZ-ALPNG6JN-T2466EYC-QQ"

// Same key with one base32 digit changed, inside the region that encodes the
// licensee name. A key whose name can be edited is a key that licenses anyone.
fun flip( key : string, at : int ) : string
  val cs = key.list
  cs.take(at).string ++ (if cs.drop(at).head.default('A') == 'A' then "B" else "A") ++
    cs.drop(at + 1).string

pub fun main() : io ()
  sql/unbuffer()
  val f = ref(0)

  // --- the signature, with no database in sight
  check(f, "a minted key names its licensee", license/check(fixture), "TenneCRM Test Fixture")
  check(f, "a second key names its own",      license/check(ada), "Ada")
  check(f, "the purchase date survives",      license/purchase-date(fixture), "2026-09-21")
  check(f, "day zero is 2020-01-01",          license/purchase-date(ada), "2020-01-01")

  // Dashes are decoration and the field may be pasted with either case or
  // stray spaces; none of that is the signature's business.
  check(f, "dashes are optional",             license/check(fixture.replace-all("-", "")), "TenneCRM Test Fixture")
  check(f, "lowercase is accepted",           license/check(fixture.to-lower), "TenneCRM Test Fixture")
  check(f, "surrounding space is accepted",   license/check("  " ++ fixture ++ "  "), "TenneCRM Test Fixture")

  // --- everything that is not a key we issued
  check(f, "empty is not a key",              license/check(""), "")
  check(f, "gibberish is not a key",          license/check("not-a-licence-key-at-all"), "")
  check(f, "a flipped digit in the name",     license/check(flip(fixture, 10)), "")
  check(f, "a flipped digit in the signature", license/check(flip(fixture, 60)), "")
  check(f, "a truncated key",                 license/check(fixture.list.take(100).string), "")
  check(f, "a key with a digit appended",     license/check(fixture ++ "A"), "")
  check(f, "one key's name, another's sig",   license/check(ada.list.take(12).string ++ fixture.list.drop(12).string), "")
  check(f, "a date with no signature",        license/purchase-date(flip(fixture, 60)), "")

  // --- storage and the cap, which need a database
  win32/mkdir("out").ignore
  val path = "out/lic.db"
  sql/close().ignore
  win32/rename(path, path ++ ".old").ignore
  if !db/open-db(path) then println("  FAIL cannot open " ++ path)

  check(f, "a fresh install is unlicensed",   license/licensee(), "")
  check(f, "a bad key does not activate",     license/activate("rubbish"), "")
  check(f, "and is not stored",               license/stored-key(), "")
  check(f, "a good key activates",            license/activate(fixture), "TenneCRM Test Fixture")
  check(f, "and survives a reload",           license/licensee(), "TenneCRM Test Fixture")
  // A typo arriving after a real activation must not unlicense a paying gym.
  check(f, "a later typo is refused",         license/activate("rubbish"), "")
  check(f, "the good key is still there",     license/licensee(), "TenneCRM Test Fixture")

  // The settings table is not trusted: it is the signature that licenses, not
  // the presence of a row. Hand-editing the database gets you nothing.
  repo/set-setting("license_key", "MADE-UP-KEY").ignore
  check(f, "a hand-written row licenses nobody", license/licensee(), "")

  // --- the cap itself
  list(1, license/free-members - 1).foreach fn(i)
    repo/insert-member(Member(0, "M" ++ i.show, Nothing, Nothing, "2025-01-01", True, Nothing)).ignore
  check(f, "under the cap, unlicensed",       license/can-add-member(False).show, "True")
  repo/insert-member(Member(0, "M10", Nothing, Nothing, "2025-01-01", True, Nothing)).ignore
  check(f, "at the cap, unlicensed",          license/can-add-member(False).show, "False")
  check(f, "at the cap, licensed",            license/can-add-member(True).show, "True")
  // Inactive members still count: leaving the gym does not free a slot, or the
  // cap is lifted by ticking a checkbox eleven times.
  repo/set-member-active(1, False).ignore
  check(f, "an inactive member still counts", license/can-add-member(False).show, "False")

  // The shelf and the till are capped on the same terms as the roster.
  list(1, license/free-products - 1).foreach fn(i)
    repo2/insert-product(Product(0, "P" ++ i.show, 10.0, 5, True)).ignore
  check(f, "under the product cap",         license/can-add-product(False).show, "True")
  repo2/insert-product(Product(0, "P-last", 10.0, 5, True)).ignore
  check(f, "at the product cap",            license/can-add-product(False).show, "False")
  check(f, "at the product cap, licensed",  license/can-add-product(True).show, "True")
  // Taking a product off sale must not free its slot.
  repo2/update-product(Product(1, "P1", 10.0, 5, False)).ignore
  check(f, "an inactive product still counts", license/can-add-product(False).show, "False")

  list(1, license/free-sales - 1).foreach fn(i)
    repo2/import-sale("2025-01-0" ++ (i % 9 + 1).show, 50.0, []).ignore
  check(f, "under the sale cap",            license/can-add-sale(False).show, "True")
  repo2/import-sale("2025-02-01", 50.0, []).ignore
  check(f, "at the sale cap",               license/can-add-sale(False).show, "False")
  check(f, "at the sale cap, licensed",     license/can-add-sale(True).show, "True")

  sql/close().ignore
  println("")
  println(if !f == 0 then "ALL PASS" else "FAILED: " ++ (!f).show)
