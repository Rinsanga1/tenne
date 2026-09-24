#!/usr/bin/env bash
# One command to build TenneCRM. Handmade Hero style: no build system, just
# the compiler and the flags it actually needs.
set -e
cd "$(dirname "$0")"

CL="c:/Program Files/LLVM/bin/clang-cl.exe"

# SQLite is 9.5MB of C that never changes. Compile it once.
if [ ! -f build/sqlite3.obj ] || [ src/sqlite3.c -nt build/sqlite3.obj ]; then
  echo "compile : sqlite3 amalgamation (once)"
  mkdir -p build
  "$CL" -nologo -Wno-everything -MDd -O1 \
    -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_DQS=0 \
    -c -Fobuild/sqlite3.obj src/sqlite3.c
fi

# Koka keys its build cache on the .kk file, so a changed inline .c is not
# noticed and you silently keep running the old C. Touch the module whenever
# its sibling C file is newer. Cost an hour once; never again.
for c in src/*-inline.c; do
  [ -e "$c" ] || continue
  kk="${c%-inline.c}.kk"
  [ -e "$kk" ] && [ "$c" -nt "$kk" ] && touch "$kk"
done

# Adding a field to a record changes the arity of its generated copy-constructor,
# but Koka does not recompile the modules that call it. The link then fails with
# an undefined `kk_app_state_fs__copy` listing twenty `optional` parameters, which
# says nothing about why.
#
# Watch the shape of every record in the tree, not file timestamps: a rebuild
# refreshes the timestamps and the staleness is invisible again by the next run.
mkdir -p build
shape=$(grep -h -A40 '^pub struct' src/*.kk 2>/dev/null | md5sum | cut -d' ' -f1)
if [ ! -f build/record-shape ] || [ "$shape" != "$(cat build/record-shape)" ]; then
  echo "touch   : a record definition changed, rebuilding dependents"
  touch src/*.kk
  echo "$shape" > build/record-shape
fi

TARGET="${TARGET:-src/main.kk}"
OUT="${OUT:-tenne.exe}"

if [ "${RELEASE:-}" = "1" ]; then
  # The shippable build.
  #
  # Koka defaults to the DEBUG CRT (-MDd), which links ucrtbased.dll and
  # VCRUNTIME140D.dll. Neither is redistributable, so the default build simply
  # does not start on a machine without Visual Studio installed -- it is fine
  # for tests and useless for shipping. Our --ccopts land after Koka's own
  # flags, so -MD wins and the exe links the redistributable MSVCP140/
  # VCRUNTIME140 instead.
  #
  # A fully static CRT (-MT) is not available: Koka ships its std library
  # precompiled against -MD, and mixing the two is a /failifmismatch link error.
  # Hence dist/, which carries those two DLLs beside the exe.
  #
  # -subsystem:windows is what stops a console window appearing behind the app.
  # It normally demands a WinMain entry point, so -entry keeps Koka's ordinary
  # main. --cclinkopts lands after clang-cl's -link, so these are lld-link
  # flags -- -Wl, forwarding is silently ignored there. Anything written to
  # stdout on this build goes nowhere.
  #
  # Tests deliberately stay on the debug build: its allocator is what catches
  # the Koka miscompilations, and that is worth more than the speed.
  if [ ! -f build/sqlite3-rel.obj ]; then
    echo "compile : sqlite3 amalgamation (release CRT)"
    mkdir -p build
    "$CL" -nologo -Wno-everything -MD -O2 \
      -DSQLITE_THREADSAFE=0 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_DQS=0 \
      -c -Fobuild/sqlite3-rel.obj src/sqlite3.c
  fi
  koka -i=src --cclib="user32;gdi32;bcrypt" --ccincdir="src" \
       --cclinkopts="build/sqlite3-rel.obj -subsystem:windows -entry:mainCRTStartup" \
       --ccopts="-MD" \
       --no-debug -O2 --buildtag=rel -o "$OUT" "$@" "$TARGET"

  # What actually gets handed to someone: the exe cannot travel alone. It reads
  # its fonts from assets/ beside itself, and it imports the VC++ runtime, which
  # is not on every Windows machine. Copy dist/ whole and it runs; the database
  # is created inside it on first start.
  if [ "${DIST:-1}" = "1" ]; then
    CRT=$(ls -d "/c/Program Files/Microsoft Visual Studio"/*/*/VC/Redist/MSVC/*/x64/Microsoft.VC*.CRT 2>/dev/null | tail -1)
    rm -rf dist && mkdir -p dist
    cp "$OUT" dist/TenneCRM.exe
    cp -r assets dist/
    if [ -n "$CRT" ]; then
      cp "$CRT/msvcp140.dll" "$CRT/vcruntime140.dll" "$CRT/vcruntime140_1.dll" dist/
    else
      echo "warning : no VC++ redist found, dist/ needs the runtime installed"
    fi
    echo "dist    : dist/ ($(du -sh dist | cut -f1))"
  fi
else
  koka -i=src --cclib="user32;gdi32;bcrypt" --ccincdir="src" \
       --cclinkopts="build/sqlite3.obj" -o "$OUT" "$@" "$TARGET"
fi
