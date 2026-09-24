// Odds and ends Koka's standard library does not carry.
module util

import std/num/float64

// Koka's std/core has no sort of any kind, so here is one. Merge sort: stable,
// which matters because several lists here sort on one key and rely on the
// previous ordering to break ties.
//
// `before(a, b)` means "a comes first". A strict predicate, not an ordering,
// because every call site here is naturally written that way.
pub fun sort-by( xs : list<a>, before : (a, a) -> <div|e> bool ) : <div|e> list<a>
  match xs
    Nil -> Nil
    Cons(_, Nil) -> xs
    _ ->
      val n = xs.length / 2
      merge(sort-by(xs.take(n), before), sort-by(xs.drop(n), before), before)

fun merge( xs : list<a>, ys : list<a>, before : (a, a) -> <div|e> bool ) : <div|e> list<a>
  match xs
    Nil -> ys
    Cons(x, xr) -> match ys
      Nil -> xs
      Cons(y, yr) ->
        // take from the left unless the right is strictly earlier, so equal
        // elements keep their original order
        if before(y, x) then Cons(y, merge(xs, yr, before))
        else Cons(x, merge(xr, ys, before))

pub fun sum-floats( xs : list<float64> ) : float64
  xs.foldl(0.0, fn(a, b) { a + b })

// Sum of a list under a projection -- the shape most totals take.
pub fun total( xs : list<a>, f : (a) -> e float64 ) : e float64
  xs.foldl(0.0) fn(acc, x) { acc + f(x) }

pub fun clamp( v : int, lo : int, hi : int ) : int
  if v < lo then lo elif v > hi then hi else v

// --- parsing ------------------------------------------------------------

pub fun parse-nat( s : string ) : maybe<int>
  val cs = s.list
  if cs.is-nil then Nothing
  elif cs.all(fn(c) { c.is-digit }) then
    Just(cs.foldl(0, fn(a, c) { a * 10 + (c.int - '0'.int) }))
  else Nothing

// A money amount as the user types it: "1500", "1500.50", "-200". Returns
// Nothing for anything else, so a typo cannot be read as zero and silently
// waive a fee.
pub fun parse-money( s : string ) : maybe<float64>
  val t = s.trim
  val neg = t.starts-with("-").bool
  val body = if neg then t.list.drop(1).string else t
  val v = match body.split(".")
    [whole] -> parse-nat(whole).map(fn(n) { n.float64 })
    [whole, frac] -> match (parse-nat(whole), parse-nat(frac))
      (Just(w), Just(f)) -> Just(w.float64 + f.float64 / pow(10.0, frac.count.float64))
      _ -> Nothing
    _ -> Nothing
  if neg then v.map(fn(x) { 0.0 - x }) else v

// Amounts are shown in the form the way they will be stored: no decimals
// unless the number actually has them.
pub fun show-money( v : float64 ) : string
  val r = v.round
  if r == v then r.int.show else v.show
