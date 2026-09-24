// The conformance walk with the joining-fee guard removed. This run is
// REQUIRED to fail: if it ever passes, conform.kk has gone vacuous and is
// checking nothing. Same discipline as the TLA broken runs.
module conformbroken
import conform
pub fun main() : io ()
  val bad = conform/run(False)
  if bad > 0 then println("BROKEN RUN FAILED AS EXPECTED (" ++ bad.show ++ " violations)")
  else println("NO VIOLATION - the conformance suite has gone vacuous!")
