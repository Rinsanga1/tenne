// The records the database holds, as Koka sees them. Field for field the same
// as the Rust build's `models.rs` -- the schema is shared, so the shapes must be.
module models

import std/num/float64

pub struct member
  id        : int
  name      : string
  phone     : maybe<string>
  address   : maybe<string>
  join-date : string
  active    : bool
  notes     : maybe<string>

pub fun blank-member() : member
  Member(0, "", Nothing, Nothing, "", True, Nothing)

// The member's join month, `YYYY-MM`. The arrears query counts from here, and
// uses the same substr(join_date, 1, 7) in SQL, so they must agree.
pub fun join-month( m : member ) : string
  m.join-date.list.take(7).string

pub type member-status
  Paid
  Due
  Inactive

pub fun status-label( s : member-status ) : string
  match s
    Paid -> "Paid"
    Due -> "Due"
    Inactive -> "Inactive"

pub struct payment
  id           : int
  member-id    : int
  period-month : string   // YYYY-MM
  amount       : float64
  date         : string
  note         : maybe<string>
  category     : string   // "membership" | "registration"

pub val cat-membership = "membership"
pub val cat-registration = "registration"

// The word the user reads for a payment category. `membership` dues are a
// "Monthly fee"; the one-time `registration` charge is the "Joining fee" --
// the same words the Record Payment dialog uses. Keep this the one place that
// names them so the ledger, dashboard and member history never disagree.
pub fun category-label( category : string ) : string
  if category == cat-registration then "Joining fee" else "Monthly fee"

pub struct product
  id     : int
  name   : string
  price  : float64
  stock  : int
  active : bool

pub struct sale
  id    : int
  date  : string
  total : float64

pub struct sale-item
  id         : int
  sale-id    : int
  product-id : maybe<int>
  qty        : int
  unit-price : float64

pub struct expense
  id     : int
  name   : string
  amount : float64
  date   : string
  note   : maybe<string>

// A saved expense template (name + amount) the user picks from when adding an
// expense, so recurring bills like rent and salaries aren't retyped. Not
// automatic -- it only prefills the Add-expense form.
pub struct recurring-expense
  id     : int
  name   : string
  amount : float64

pub type txn-kind
  TxnPayment
  TxnSale
  TxnExpense

// A unified money movement for the Transactions history view.
pub struct txn
  kind   : txn-kind
  id     : int
  date   : string
  amount : float64   // positive = money in, negative = money out
  label  : string
  detail : maybe<string>

// `Rs 1,500` -- currency prefix, grouped thousands, no decimals (a rupee gym
// doesn't bill paise). Every figure in the app routes through here so they all
// match and all honour the currency setting.
pub fun money( currency : string, amount : float64 ) : string
  val r = amount.round
  val n = (if r < 0.0 then 0.0 - r else r).int
  val sign = if r < 0.0 then "-" else ""
  sign ++ currency ++ " " ++ group(n.show)

fun group( digits : string ) : string
  val cs = digits.list.reverse
  chunk(cs, 0, []).string

fun chunk( cs : list<char>, n : int, acc : list<char> ) : list<char>
  match cs
    Nil -> acc
    Cons(c, rest) ->
      val acc2 = if n > 0 && n % 3 == 0 then Cons(c, Cons(',', acc)) else Cons(c, acc)
      chunk(rest, n + 1, acc2)

pub fun is-payment( k : txn-kind ) : bool
  match k
    TxnPayment -> True
    _ -> False

pub fun is-sale( k : txn-kind ) : bool
  match k
    TxnSale -> True
    _ -> False

pub fun is-expense( k : txn-kind ) : bool
  match k
    TxnExpense -> True
    _ -> False
