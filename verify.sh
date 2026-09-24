#!/usr/bin/env bash
# Everything that can fail, in one command. Rerunnable from a clean shell.
set -e
cd "$(dirname "$0")"
fail=0
mkdir -p out
taskkill //F //IM tenne.exe >/dev/null 2>&1 || true

echo "=== model checking ==="
cd docs/tla
# TLC dumps a state directory per run; 168 of them reached 3.3GB before anyone
# noticed. They are scratch, regenerated every time.
rm -rf states
for cfg in ImmediateMode Durability; do
  out=$(java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto \
        -config $cfg.cfg $cfg.tla 2>&1 | grep -E "No error|Error:" | head -1)
  echo "  $cfg: $out"
  echo "$out" | grep -q "No error" || fail=1
done
# the guards must still have teeth: these two are REQUIRED to fail
for cfg in ImmediateModeFireAnywhere ImmediateModeKeepVanishedCapture ImmediateModeKeepVanishedFocus ImmediateModeMouseThenKeys; do
  out=$(java -XX:+UseParallelGC -cp tla2tools.jar tlc2.TLC -workers auto \
        -config $cfg.cfg ImmediateMode.tla 2>&1 | grep -E "is violated" | head -1)
  echo "  $cfg: ${out:-NO VIOLATION - invariant has gone vacuous!}"
  [ -n "$out" ] || fail=1
done
cd ../..

# A suite must print ALL PASS, exit 0, AND not trip the allocator. That last
# check matters: a double free showed up only as a message on stderr while the
# exit code stayed 0, and `|| true` hid it for an entire iteration.
run() {
  echo "=== $1 ==="
  TARGET=src/$2.kk OUT=$2.exe ./build.sh >/dev/null 2>&1
  set +e; ./$2.exe > out/$2.log 2>&1; rc=$?; set -e
  tail -1 out/$2.log
  grep -q "ALL PASS" out/$2.log || { echo "  ^^ $1: no ALL PASS"; fail=1; }
  [ $rc -eq 0 ] || { echo "  ^^ $1: exit $rc"; fail=1; }
  grep -qi "mimalloc\|Segmentation\|corrupted" out/$2.log && { echo "  ^^ $1: allocator complained"; fail=1; } || true
}

run "immediate-mode protocol (ImmediateMode.tla)" uitest
run "dates"                                        datestest
run "sqlite layer"                                 sqltest
run "schema + migrations"                          dbtest
run "repository (TenneCRM.tla actions)"            repotest
run "shop + ledger (StockConserved, StockNeverNegative)" repo2test
run "durability (Durability.tla)"                  backuptest
run "Members dialogs (AtMostOneJoiningFee through the UI)" dlgtest
run "dashboard + ledger views"                     dashtest
run "shop (StockNeverNegative through the counter)" shoptest
run "CSV round trip (AtMostOneJoiningFee)"         csvtest
run "licensing: the key, and the cap it enforces"  lictest
run "settings + restore by clicking"               settingstest
run "caret + selection"                            texttest
# after dashtest, which seeds out/dash.db that this one renders from
run "every view at every window size"              resizetest
run "navigation between views"                     navtest

echo "=== conformance: the port against TenneCRM.tla ==="
TARGET=src/conform.kk OUT=conform.exe ./build.sh >/dev/null 2>&1
set +e; ./conform.exe > out/conform.log 2>&1; rc=$?; set -e
tail -3 out/conform.log
grep -q "ALL PASS" out/conform.log || { echo "  ^^ conformance FAILED"; fail=1; }
[ $rc -eq 0 ] || { echo "  ^^ conformance exit $rc"; fail=1; }
grep -qi "mimalloc|corrupted" out/conform.log && { echo "  ^^ allocator complained"; fail=1; } || true
# and the same walk with the joining-fee guard removed, which MUST fail
TARGET=src/conformbroken.kk OUT=conformbroken.exe ./build.sh >/dev/null 2>&1
./conformbroken.exe > out/conformbroken.log 2>&1 || true
tail -1 out/conformbroken.log
grep -q "BROKEN RUN FAILED AS EXPECTED" out/conformbroken.log || { echo "  ^^ conformance has gone vacuous!"; fail=1; }

echo "=== soak: 696 frames of the real loop, every view and dialog ==="
TARGET=src/soak.kk OUT=soak.exe ./build.sh >/dev/null 2>&1
set +e; ./soak.exe > out/soak.log 2>&1; rc=$?; set -e
tail -2 out/soak.log
grep -q "ALL PASS" out/soak.log || { echo "  ^^ soak FAILED"; fail=1; }
[ $rc -eq 0 ] || { echo "  ^^ soak exit $rc"; fail=1; }
grep -qi "mimalloc|corrupted|Segmentation" out/soak.log && { echo "  ^^ allocator complained"; fail=1; } || true

echo "=== reads a database written by the Rust build ==="
TARGET=src/dbinfo.kk OUT=dbinfo.exe ./build.sh >/dev/null 2>&1
./dbinfo.exe | head -3
./dbinfo.exe | grep -q "^tables: expenses, members, payments" || {
  echo "  ^^ out/real.db missing or unreadable. It is a preserved artifact:"
  echo "     cp <tenne_rust>/tmp_crmtest/roche.db out/real.db"
  fail=1
}

echo "=== Members view, real database to pixels ==="
TARGET=src/viewshot.kk OUT=viewshot.exe ./build.sh >/dev/null 2>&1
./viewshot.exe > out/viewshot.log 2>&1 || fail=1
cat out/viewshot.log
# the arrears arithmetic, asserted rather than eyeballed:
# Zonunsanga joined 2025-02 and paid nothing, so by 2025-08 he is 7 months
# behind at Rs 1,500 = Rs 10,500; the gym total is Rs 31,500.
grep -q "^members in database: 8"  out/viewshot.log || { echo "  ^^ wrong member count"; fail=1; }
grep -q "^owing in 2025-08: 7"     out/viewshot.log || { echo "  ^^ wrong arrears count"; fail=1; }
grep -q "Lalhmingliana Ralte, Priya Lalthanmawii, Vanlalruati Chhangte" out/viewshot.log || { echo "  ^^ search is wrong"; fail=1; }
for f in members members-search members-empty; do [ -f out/$f.bmp ] || { echo "  ^^ missing out/$f.bmp"; fail=1; }; done

echo "=== renderer pixels, dialogs and shop ==="
for m in rendertest dlgshot shopshot; do
  TARGET=src/$m.kk OUT=$m.exe ./build.sh >/dev/null 2>&1
  set +e; ./$m.exe > out/$m.log 2>&1; rc=$?; set -e
  tail -1 out/$m.log
  [ $rc -eq 0 ] || { echo "  ^^ $m exit $rc"; fail=1; }
  grep -qi "FAILED" out/$m.log && { echo "  ^^ $m reported a failure"; fail=1; } || true
done

echo "=== renders a frame of the real UI ==="
TARGET=src/uishot.kk OUT=uishot.exe ./build.sh >/dev/null 2>&1
./uishot.exe
[ -f out/ui.bmp ] || fail=1

echo "=== the app itself builds ==="
./build.sh >/dev/null 2>&1 && echo "  tenne.exe built" || { echo "  BUILD FAILED"; fail=1; }

echo "=== the shippable build links the redistributable CRT ==="
# The default build links the DEBUG CRT (ucrtbased.dll, VCRUNTIME140D.dll),
# which Microsoft does not redistribute -- it will not start on a machine
# without Visual Studio. Ship RELEASE=1 or ship nothing.
DUMPBIN="c:/Program Files/Microsoft Visual Studio/18/Insiders/VC/Tools/MSVC/14.50.35717/bin/Hostx64/x64/dumpbin.exe"
if [ -x "$DUMPBIN" ]; then
  RELEASE=1 OUT=tenne-rel.exe ./build.sh >/dev/null 2>&1
  deps=$("$DUMPBIN" //DEPENDENTS tenne-rel.exe 2>/dev/null | grep -ciE "ucrtbased|VCRUNTIME140D|MSVCP140D" || true)
  echo "  debug-CRT dependencies in the release exe: $deps"
  [ "$deps" = "0" ] || { echo "  ^^ the release build links the non-redistributable debug CRT"; fail=1; }
else
  echo "  SKIP: dumpbin not found"
fi

echo
if [ $fail -eq 0 ]; then echo "VERIFY OK"; else echo "VERIFY FAILED"; exit 1; fi
