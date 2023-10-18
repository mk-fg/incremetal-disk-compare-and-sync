#!/bin/bash
set -eEo pipefail
umask 077
trap 'echo >&2 "----- FAILURE at line $LINENO :: $BASH_COMMAND"' ERR


## Auto-build/update binaries, if old or missing
nim='nim c --verbosity:0 -d:release --opt:speed'

[[ -e idcas.nim ]] || { p=$(realpath "$0"); cd "${p%/*}"; }
[[ -e idcas.nim && -e sparse_patch.nim ]] || {
	echo >&2 'ERROR: must be run from the repository dir'; exit 1; }
[[ idcas -nt idcas.nim ]] || $nim idcas.nim
idcas=$(readlink -f idcas)

[[ sparse_patch -nt sparse_patch.nim ]] || $nim sparse_patch.nim
sp=$(readlink -f sparse_patch)

b2sum=$(command -v b2sum)
[[ -n "$b2sum" ]] || { echo >&2 'ERROR: b2sum command not found'; exit 1; }
b2chk="$b2sum --quiet -c"

urfs=$(command -v unreliablefs)
[[ -n "$urfs" ]] || { echo >&2 'ERROR: unreliablefs command not found'; exit 1; }


mkdir -pm700 /tmp/idcas
cd /tmp/idcas

[[ -e test.bin && $(stat -c%s test.bin) -eq 105906176 ]] || \
	dd if=/dev/urandom of=test.bin bs=1M count=101 status=none

dd_patch() {
	bs=$1 c=$2 seek=$3 src=${4:-/dev/urandom} dst=${5:-test.bin}
	[[ -z "$6" ]] || false - extra arguments to dd_patch
	dd if="$src" of=test.bin bs="$bs" count="$c" \
		oseek="$seek" conv=notrunc status=none
}


## Basic change detection and syncing

test_basics() {
rm -f test.map

dd_patch 32K 1 1000 /dev/zero
dd_patch 32K 1 1005 /dev/urandom

csum=$("$idcas" --print-file-hash -m test.map test.bin)
$b2chk <<< "$csum  test.bin"
"$idcas" -vC -m test.map test.bin >/dev/null
cp -a test.bin{,.orig}

# Test: zero src/dst blocks aren't treated as special in any way
dd_patch 32K 1 1000 /dev/urandom
dd_patch 32K 1 1005 /dev/zero

# Test: changes get detected
if "$idcas" -c -m test.map test.bin ; then false - changes not detected ; fi

# Test: other random changes
dd_patch 32K 3 37
dd_patch 32K 1 2029
dd_patch 1K 1 22247
dd_patch 1K 1 56249
dd_patch 80K 5 101
upd_sbs=21 upd_kib=672

# Test: changes get copied
"$idcas" -v -m test.map test.bin test.patch | grep -q "SBs checked, $upd_sbs updated"
[[ $(du -BK test.patch | cut -f1) = ${upd_kib}K ]]
"$idcas" -c -m test.map test.bin
cp -a test.map{,.after-dd}

# Test: sparse_patch copies chunks correctly
rm -f test.patch.chk
$sp -nv test.patch | grep -q "copied $upd_kib KiB"
$sp -n test.patch test.patch.chk && [[ ! -e test.patch.chk ]]
truncate -s $(stat -c%s test.patch) test.patch.chk
$sp test.patch test.patch.chk
b2=$($b2sum test.patch.chk); $b2chk <<< "${b2%%.chk}"
[[ $(du -BK test.patch.chk | cut -f1) = $(du -BK test.patch | cut -f1) ]]
rm -f test.patch.chk
$sp -v test.patch test.patch.chk >/dev/null
truncate -s $(stat -c%s test.patch.chk) test.patch
b2=$($b2sum test.patch.chk); $b2chk <<< "${b2%%.chk}"
[[ $(du -BK test.patch.chk | cut -f1) = $(du -BK test.patch | cut -f1) ]]

# Test: reverting changes is perfectly symmetrical
"$idcas" -v -m test.map test.bin.orig test.bin | grep -q "SBs checked, $upd_sbs updated"
$b2chk <<< "$csum  test.bin"

# Test: reusing old .map works same, still copies blocks, doesn't break anything
cp -a test.map{.after-dd,}
"$idcas" -v -m test.map test.bin.orig test.bin | grep -q "SBs checked, $upd_sbs updated"
$b2chk <<< "$csum  test.bin"

# Randomize /dev/zero blocks for other tests to not match them weirdly
dd_patch 32K 1 1005

}


## Test read errors and handling/operations around those

test_flakey() {
# Note: test.bin size is important here - affects bad blocks' count/distribution
rm -f test.map

exit_cleanup() {
	set +e
	cd /
	mountpoint -q /tmp/urfs && umount /tmp/urfs
	trap '' TERM EXIT
	kill 0
	mountpoint -q /tmp/urfs && umount -l /tmp/urfs
	wait
}
trap exit_cleanup EXIT

mkdir -p urfs urfs.base
[[ -e urfs.base/test.bin ]] || ln test.bin urfs.base/test.bin

$b2chk <<< "$("$idcas" --print-file-hash -m test.map test.bin)  urfs.base/test.bin"
mv test.map{,.pure}

# probability=0 seem to be =1%, as in "random(0, 100) <= n"
cat <<EOF >urfs.base/unreliablefs.conf
[errinj_errno]
op_regexp = ^read$
path_regexp = .*
probability = 4
EOF

# prob=4 seed=13 :: File LB#10 [3.9 MiB] read failed at 41615360 B offset [39.6 MiB]
$urfs urfs -f -basedir=urfs.base -seed=13 &>/dev/null & urfs_pid=$!
for n in {1..20}; do [[ ! -e urfs/test.bin ]] || break; read -rt 0.1 <> <(:) ||:; done
# dd if=urfs/test.bin of=/dev/null bs=4161536

rm -f test.map
"$idcas" -vm test.map --skip-read-errors urfs/test.bin test.bin.corrupt &>/dev/null
cp -a test.map{,.corrupt}

umount urfs
kill $urfs_pid &>/dev/null ||:

# Test: skipped (unreadable) blocks in HM should always be replaced with something meaningful
if cmp -s test.bin{.corrupt,} ; then false - corrupt file ended up same as the original ; fi
cp -a test.map{.corrupt,}
if "$idcas" -vC -m test.map test.bin >/dev/null ; then false - corrupt map not updated from clean src ; fi
if "$idcas" -c -m test.map test.bin.corrupt ; then false - corrupt map not updated from 0000-block src ; fi

# Test: corrupted blocks get fixed
cp -a test.bin.{corrupt,fix} && cp -a test.map{.corrupt,}
$b2chk <<< "$("$idcas" --print-file-hash -m test.map test.bin test.bin.fix)  test.bin"
mv test.map{,.fix}

# Test: create sparse patch-file
rm -f test.patch
cp -a test.map{.corrupt,}
$b2chk <<< "$("$idcas" --print-file-hash -m test.map test.bin test.patch)  test.bin"
mv test.map{,.bmap}
[[ $(du -BK test.patch | cut -f1) = 32K ]]
[[ $(du --apparent-size -BK test.patch | cut -f1) != 32K ]]

# Test: patch fixes unreadable block(s) w/o breaking anything else
cp -a test.bin{,.chk}
$sp test.patch test.bin.chk
b2=$($b2sum test.bin.chk); $b2chk <<< "${b2%%.chk}"
cp -a test.bin.{corrupt,chk}
$sp test.patch test.bin.chk
b2=$($b2sum test.bin.chk); $b2chk <<< "${b2%%.chk}"

}


### Run all test blocks from above
# Split into blocks to make it easy to re-run only specific block of linked tests

test_basics
test_flakey

rm -rf /tmp/idcas
