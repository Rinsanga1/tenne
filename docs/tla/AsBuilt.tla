----------------------------- MODULE AsBuilt -----------------------------
(***************************************************************************)
(* A specification of the two places in TenneCRM where one user action      *)
(* moves several records at once, and where a check can go stale between    *)
(* reading and writing:                                                     *)
(*                                                                          *)
(*   1. The member ledger - joining fee, monthly dues, deactivation,        *)
(*      deletion (which cascades payments away), and CSV import.            *)
(*   2. The shop - a sale takes units off the shelf, deleting or editing    *)
(*      a sale must put exactly those units back.                           *)
(*                                                                          *)
(* Deliberately out of scope, because no invariant here mentions them:      *)
(* names, phones, notes, currency, themes, expenses, recurring expense      *)
(* templates, backups, and restocking. A sale carries one line; a second    *)
(* line exhibits no behaviour the first does not.                           *)
(***************************************************************************)
EXTENDS Integers, FiniteSets

CONSTANTS
    Member,    \* member identities
    Product,   \* product identities
    SaleId,    \* how many sales may be on the books at once
    MaxMonth,  \* how many months the model runs for
    Capacity,  \* units of each product on the shelf when the model starts
    MaxQty     \* the largest quantity one sale may carry

Month == 1..MaxMonth

Absent == 0  \* the value of joined[m] when no such member row exists

\* A sale slot holds one line. qty = 0 means the slot is empty - there is no
\* sales row there. Keeping the empty slot the same shape as a full one lets
\* TLC enumerate the type without comparing across kinds.

(***************************************************************************)
(* The state.                                                               *)
(*                                                                          *)
(* joined  Member -> Absent, or the month this member joined.               *)
(*         Table members, column join_date (month precision).               *)
(* active  Member -> is this a current member?  members.active.             *)
(* paid    Member -> the set of months whose dues are settled. A set, not   *)
(*         a count, because the app counts DISTINCT period_month - paying   *)
(*         the same month twice settles one month, not two.                 *)
(* fees    Member -> how many joining-fee payments are on record.           *)
(*         payments rows with category = 'registration'. Should never be    *)
(*         more than one.                                                   *)
(* stock   Product -> units on the shelf.  products.stock.                  *)
(* line    SaleId  -> NoSale, or the one line of that sale.                 *)
(*         Tables sales + sale_items.                                       *)
(* clock   the month the app believes it is.  dates::current_month().       *)
(***************************************************************************)
VARIABLES joined, active, paid, fees, stock, line, clock

vars == << joined, active, paid, fees, stock, line, clock >>

SaleLine == [prod : Product, qty : 0..MaxQty]

NoSale == [prod |-> CHOOSE p \in Product : TRUE, qty |-> 0]

Open(s) == line[s].qty > 0

TypeOK ==
    /\ joined \in [Member -> {Absent} \cup Month]
    /\ active \in [Member -> BOOLEAN]
    /\ paid   \in [Member -> SUBSET Month]
    /\ fees   \in [Member -> Nat]
    /\ stock  \in [Product -> Int]
    /\ line   \in [SaleId -> SaleLine]
    /\ clock  \in Month

-----------------------------------------------------------------------------
(***************************************************************************)
(* Derived quantities - the numbers the screens actually show.              *)
(***************************************************************************)

RECURSIVE UnitsIn(_, _)
UnitsIn(p, S) ==
    IF S = {}
    THEN 0
    ELSE LET s == CHOOSE x \in S : TRUE
             here == IF line[s].prod = p THEN line[s].qty ELSE 0
         IN  here + UnitsIn(p, S \ {s})

\* Units of p that have left the shelf and are sitting inside sales still on
\* the books.
Committed(p) == UnitsIn(p, SaleId)

\* The months this member owes: every month from the one they joined up to
\* the current one that has no membership payment against it. Mirrors
\* Repository::arrears_all - the window starts at the member's own join month
\* and joining-fee payments are not in `paid`, so they never settle a month.
Owed(m) ==
    IF joined[m] = Absent
    THEN {}
    ELSE { mo \in joined[m]..clock : mo \notin paid[m] }

Behind(m) == Cardinality(Owed(m))

\* Who the dashboard counts under "Members due".
IsDue(m) == active[m] /\ joined[m] # Absent /\ Behind(m) > 0

-----------------------------------------------------------------------------
(***************************************************************************)
(* The invariants. Written before the actions, in the gym owner's terms.    *)
(***************************************************************************)

\* The joining fee is a one-time charge. A second one on the same member is
\* money they never owed, quietly inflating the dashboard's income.
AtMostOneJoiningFee ==
    \A m \in Member : fees[m] <= 1

\* Deleting a member takes their whole ledger with them. A payment belonging
\* to nobody still lands in the monthly totals.
NoOrphanPayments ==
    \A m \in Member : joined[m] = Absent => (paid[m] = {} /\ fees[m] = 0)

\* Every unit is either on the shelf or inside a sale that is still on the
\* books. Recording, editing or deleting a sale moves units - it never mints
\* or destroys them.
StockConserved ==
    \A p \in Product : stock[p] + Committed(p) = Capacity

\* You cannot sell what you do not have.
StockNeverNegative ==
    \A p \in Product : stock[p] >= 0

\* Nobody reads "all paid up" without having paid for the month they are
\* looking at. Catches an arrears window that stops short of today.
PaidUpMeansPaidThisMonth ==
    \A m \in Member :
        (joined[m] # Absent /\ Behind(m) = 0) => clock \in paid[m]

\* Someone who joins today and pays today is not chased for dues today.
\* Catches an off-by-one in month_diff(join, current) + 1.
NewMemberWhoPaidIsNotDue ==
    \A m \in Member :
        (joined[m] = clock /\ clock \in paid[m]) => ~IsDue(m)

-----------------------------------------------------------------------------
(***************************************************************************)
(* The actions. Each is guard, then update. Every action constrains every   *)
(* variable.                                                                *)
(***************************************************************************)

\* Repository::create_member - one transaction inserting the member, the
\* mandatory joining fee, and optionally their first month's dues.
AddMember(m, withFirstMonth) ==
    /\ joined[m] = Absent
    /\ joined' = [joined EXCEPT ![m] = clock]
    /\ active' = [active EXCEPT ![m] = TRUE]
    /\ fees'   = [fees   EXCEPT ![m] = 1]
    /\ paid'   = [paid   EXCEPT ![m] = IF withFirstMonth THEN {clock} ELSE {}]
    /\ UNCHANGED << stock, line, clock >>

\* Repository::ensure_registration_payment - idempotent by design: it counts
\* the member's registration rows first and does nothing if one exists.
RecordJoiningFee(m) ==
    /\ joined[m] # Absent
    /\ fees[m] = 0
    /\ fees' = [fees EXCEPT ![m] = 1]
    /\ UNCHANGED << joined, active, paid, stock, line, clock >>

\* Repository::remove_registration_payment - un-ticking the joining fee box.
RemoveJoiningFee(m) ==
    /\ joined[m] # Absent
    /\ fees[m] > 0
    /\ fees' = [fees EXCEPT ![m] = 0]
    /\ UNCHANGED << joined, active, paid, stock, line, clock >>

\* Repository::insert_payment with category 'membership'.
RecordDues(m, mo) ==
    /\ joined[m] # Absent
    /\ mo \notin paid[m]
    /\ paid' = [paid EXCEPT ![m] = @ \cup {mo}]
    /\ UNCHANGED << joined, active, fees, stock, line, clock >>

\* Repository::delete_payment from the member's payment history editor.
DeleteDues(m, mo) ==
    /\ mo \in paid[m]
    /\ paid' = [paid EXCEPT ![m] = @ \ {mo}]
    /\ UNCHANGED << joined, active, fees, stock, line, clock >>

\* Repository::set_member_active - the Active toggle on the members table.
SetActive(m, b) ==
    /\ joined[m] # Absent
    /\ active[m] # b
    /\ active' = [active EXCEPT ![m] = b]
    /\ UNCHANGED << joined, paid, fees, stock, line, clock >>

\* Repository::delete_member. payments.member_id is declared ON DELETE
\* CASCADE, so the member's whole ledger goes with them.
DeleteMember(m) ==
    /\ joined[m] # Absent
    /\ joined' = [joined EXCEPT ![m] = Absent]
    /\ active' = [active EXCEPT ![m] = FALSE]
    /\ paid'   = [paid   EXCEPT ![m] = {}]
    /\ fees'   = [fees   EXCEPT ![m] = 0]
    /\ UNCHANGED << stock, line, clock >>

\* settings.rs import_all_csv, payment rows. The file's Category cell is
\* written straight into payments.category, and the row attaches to an
\* existing member matched by name. The guard on fees[m] mirrors the check
\* added to the importer; without it, importing a file that carries a
\* joining-fee row for a member who already has one charges them twice.
ImportPayment(m, mo, isJoiningFee) ==
    /\ joined[m] # Absent
    /\ IF isJoiningFee
       THEN /\ fees' = [fees EXCEPT ![m] = @ + 1]  \* AS-BUILT: no check for an existing joining fee
            /\ UNCHANGED paid
       ELSE /\ paid' = [paid EXCEPT ![m] = @ \cup {mo}]
            /\ UNCHANGED fees
    /\ UNCHANGED << joined, active, stock, line, clock >>

\* Repository::record_sale - insert the sale and its items, decrement stock,
\* one transaction. The stock guard mirrors the check added to the sale
\* dialog; without it a typo'd quantity drives stock below zero.
RecordSale(s, p, q) ==
    /\ ~Open(s)
    \* AS-BUILT: record_sale does not check stock
    /\ line'  = [line  EXCEPT ![s] = [prod |-> p, qty |-> q]]
    /\ stock' = [stock EXCEPT ![p] = @ - q]
    /\ UNCHANGED << joined, active, paid, fees, clock >>

\* Repository::delete_sale - restores stock for each line, then deletes.
DeleteSale(s) ==
    /\ Open(s)
    /\ stock' = [stock EXCEPT ![line[s].prod] = @ + line[s].qty]
    /\ line'  = [line  EXCEPT ![s] = NoSale]
    /\ UNCHANGED << joined, active, paid, fees, clock >>

\* Repository::update_sale - put the old line's units back, then take the new
\* line's units. The two EXCEPT clauses apply left to right, so a sale edited
\* from one product to another settles correctly even when p is the old one.
EditSale(s, p, q) ==
    /\ Open(s)
    /\ ~(line[s].prod = p /\ line[s].qty = q)
    \* AS-BUILT: update_sale does not check stock
    /\ stock' = [stock EXCEPT ![line[s].prod] = @ + line[s].qty,
                              ![p]            = @ - q]
    /\ line'  = [line  EXCEPT ![s] = [prod |-> p, qty |-> q]]
    /\ UNCHANGED << joined, active, paid, fees, clock >>

\* The calendar. The only action here the system takes on its own - every
\* other action is a person clicking something.
Tick ==
    /\ clock < MaxMonth
    /\ clock' = clock + 1
    /\ UNCHANGED << joined, active, paid, fees, stock, line >>

-----------------------------------------------------------------------------

Init ==
    /\ joined = [m \in Member  |-> Absent]
    /\ active = [m \in Member  |-> FALSE]
    /\ paid   = [m \in Member  |-> {}]
    /\ fees   = [m \in Member  |-> 0]
    /\ stock  = [p \in Product |-> Capacity]
    /\ line   = [s \in SaleId  |-> NoSale]
    /\ clock  = 1

Next ==
    \/ \E m \in Member : \E b \in BOOLEAN : AddMember(m, b)
    \/ \E m \in Member : RecordJoiningFee(m)
    \/ \E m \in Member : RemoveJoiningFee(m)
    \/ \E m \in Member, mo \in Month : RecordDues(m, mo)
    \/ \E m \in Member, mo \in Month : DeleteDues(m, mo)
    \/ \E m \in Member, b \in BOOLEAN : SetActive(m, b)
    \/ \E m \in Member : DeleteMember(m)
    \/ \E m \in Member, mo \in Month, b \in BOOLEAN : ImportPayment(m, mo, b)
    \/ \E s \in SaleId, p \in Product, q \in 1..MaxQty : RecordSale(s, p, q)
    \/ \E s \in SaleId : DeleteSale(s)
    \/ \E s \in SaleId, p \in Product, q \in 1..MaxQty : EditSale(s, p, q)
    \/ Tick

\* Fairness on Tick only. Time passes whether or not the gym owner opens the
\* app; no amount of weak fairness makes a person click "Record payment".
Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)

-----------------------------------------------------------------------------
(***************************************************************************)
(* Liveness.                                                                *)
(***************************************************************************)

\* Nothing the user can do freezes the calendar - no sequence of edits leaves
\* the app stuck in a month.
TimeMovesOn == <>(clock = MaxMonth)

=============================================================================
