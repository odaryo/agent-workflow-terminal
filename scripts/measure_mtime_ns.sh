#!/usr/bin/env bash
# Issue #859 の計測用の一時スクリプト (マージ前に消す)。
# swift-driver / llbuild がソースの mtime のナノ秒まで比べるかを、小さなパッケージで確かめる。
# ソースは checkout と同じく別 inode に書き直してから mtime を与える。
set -euo pipefail

work="$(mktemp -d)"
cleanup() {
  local status=$?
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
cd "$work"
mkdir -p Sources/Probe
cat > Package.swift <<'EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "Probe", targets: [.executableTarget(name: "Probe")])
EOF
printf 'print(value)\n' > Sources/Probe/main.swift

S=1000000000
build_flags=("$@")

put() { # put <value> <seconds> <nanoseconds>
  printf 'let value = %s\n' "$1" > Sources/Probe/Value.swift.tmp
  mv Sources/Probe/Value.swift.tmp Sources/Probe/Value.swift
  python3 -c 'import os,sys; t=int(sys.argv[2])*10**9+int(sys.argv[3]); os.utime(sys.argv[1], ns=(t,t))' \
    Sources/Probe/Value.swift "$2" "$3"
  python3 -c 'import os,sys; t=int(sys.argv[2])*10**9; os.utime(sys.argv[1], ns=(t,t))' \
    Sources/Probe/main.swift "$S"
}

obj_mtime() {
  local o
  o=""
  if [ -d .build ]; then
    o="$(find .build -name 'Value.swift.o' -path '*debug*' | head -1)"
  fi
  if [ -n "$o" ]; then
    stat -f '%Fm' "$o"
  else
    echo none
  fi
}

step() { # step <label> <value> <seconds> <nanoseconds> <expect-if-recompiled>
  put "$2" "$3" "$4"
  local before after out
  before="$(obj_mtime)"
  sleep 1
  swift build ${build_flags[@]+"${build_flags[@]}"} >build.log 2>&1 || { cat build.log; exit 1; }
  after="$(obj_mtime)"
  out="$(swift run ${build_flags[@]+"${build_flags[@]}"} --skip-build Probe)"
  echo "$1: source mtime=$(stat -f '%Fm' Sources/Probe/Value.swift) printed=$out (recompiled would print $5) obj_before=$before obj_after=$after"
}

swift --version 2>&1 | head -1
echo "build flags: ${build_flags[*]+${build_flags[*]}}"
step "0 initial          (S, 0)          " 1 "$S" 0 1
step "A same s, same ns  (S, 0)          " 2 "$S" 0 2
step "B same s, other ns (S, 123456789)  " 3 "$S" 123456789 3
step "C no change, new inode (S, 123456789)" 3 "$S" 123456789 3
step "D same s, ns +1    (S, 123456790)  " 4 "$S" 123456790 4
step "E same s, same ns  (S, 123456790)  " 5 "$S" 123456790 5
step "F other s          (S+1, 123456790)" 6 "$((S + 1))" 123456790 6
