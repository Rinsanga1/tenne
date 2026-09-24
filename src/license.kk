// Licensing. A key is a signed blob the customer pastes in once; there is no
// account, no server and no phone-home, so a gym with no internet is a gym
// that still works. See src/license-inline.c for the format and mintkey.sh
// for how keys are made.
//
// Unlicensed, everything in the CRM runs -- backups, CSV, reports, the whole
// month -- but the roster, the shelf and the till each stop at ten. The limit
// is on *adding*, never on reading: an unlicensed copy can always open, view,
// edit and back up a database it already has, whatever its size. Locking
// someone out of their own member list reads as data loss, and a CRM that
// eats a gym's roster is not a CRM anyone should trust with it.
module license

import sql
import dates
import repo
import repo2

extern import
  c file "license-inline.c"

// The licensee's name, or "" if this is not a key we issued. The name is
// covered by the signature, so what comes back is what was sold, not what is
// sitting in the settings table.
pub extern check( key : string ) : io string
  c "kk_lic_check"

// Days since 2020-01-01, or -1 if the key does not verify.
extern purchase-day( key : string ) : io int
  c "kk_lic_day"

// What an unlicensed copy may build. Enough to carry a real evaluation -- add
// members, take payments, stock the shelf, ring up sales, run the month -- and
// small enough that any actual gym reaches it in an afternoon.
pub val free-members = 10
pub val free-products = 10
pub val free-sales = 10

pub fun stored-key() : io string
  repo/get-setting("license_key").default("")

// Verifying costs an ECDSA check, so this is called at startup and after an
// activation, and the answer is carried in app/state -- never per frame.
pub fun licensee() : io string
  check(stored-key())

pub fun purchase-date( key : string ) : io string
  val d = purchase-day(key)
  if d < 0 then "" else
    val (y, m, dd) = dates/civil-from-days(dates/days-from-civil(2020, 1, 1) + d)
    dates/fmt-date(y, m, dd)

// Stores the key only if it verifies, so a typo cannot displace a good key
// that is already in place.
pub fun activate( key : string ) : io string
  val k = key.trim
  val who = check(k)
  if who == "" then "" else
    repo/set-setting("license_key", k).ignore
    who

// The gates. Every door that creates one of these asks -- the dialog the user
// clicks *and* the CSV importer -- because a cap the spreadsheet walks
// straight through is not a cap.
pub fun can-add-member( licensed : bool ) : io bool
  licensed || repo/count-members(False) < free-members

pub fun can-add-product( licensed : bool ) : io bool
  licensed || repo2/count-products() < free-products

pub fun can-add-sale( licensed : bool ) : io bool
  licensed || repo2/count-sales() < free-sales

fun cap-notice( limit : int, what : string ) : string
  "Unlicensed copy: this stops at " ++ limit.show ++ " " ++ what ++
  ". Enter your licence key in Settings."

pub fun member-cap-notice() : string
  cap-notice(free-members, "members")

pub fun product-cap-notice() : string
  cap-notice(free-products, "products")

pub fun sale-cap-notice() : string
  cap-notice(free-sales, "sales")
