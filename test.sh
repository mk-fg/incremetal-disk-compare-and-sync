#!/bin/bash
set -eEo pipefail
umask 077
trap 'echo "----- FAILURE at line $LINENO :: $BASH_COMMAND"' ERR

# [[ ! -e idcas.nim ]] || nim c -w=on --hints=on idcas.nim
[[ ! -e idcas.nim ]] || nim c --hints=off idcas.nim
idcas=$(readlink -f idcas)
[[ -e "$idcas" ]] || idcas=$(command -v idcas)
[[ -n "$idcas" ]] || { echo >&2 'ERROR: idcas command not found'; exit 1; }
b2sum='b2sum --quiet'

mkdir -pm700 /tmp/idcas
cd /tmp/idcas

[[ -e test.bin && $(stat -c%s test.bin) -eq 105906176 ]] || \
	dd if=/dev/urandom of=test.bin bs=1M count=101

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
$b2sum -c <<< "$csum  test.bin"
"$idcas" -vC -m test.map test.bin
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

# Test: changes get copied
"$idcas" -v -m test.map test.bin test.patch | grep -q 'SBs checked, 8 updated'
[[ $(du -BK test.patch | cut -f1) = 256K ]]
"$idcas" -c -m test.map test.bin
cp -a test.map{,.after-dd}

# Test: reverting changes is perfectly symmetrical
"$idcas" -v -m test.map test.bin.orig test.bin | grep -q 'SBs checked, 8 updated'
$b2sum -c <<< "$csum  test.bin"

# Test: reusing old .map works same, still copies blocks, doesn't break anything
cp -a test.map{.after-dd,}
"$idcas" -v -m test.map test.bin.orig test.bin | grep -q 'SBs checked, 8 updated'
$b2sum -c <<< "$csum  test.bin"

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
	trap : term
	kill 0
	mountpoint -q /tmp/urfs && umount -l /tmp/urfs
	wait
}
trap exit_cleanup EXIT

mkdir -p urfs urfs.base
[[ -e urfs.base/test.bin ]] || ln test.bin urfs.base/test.bin

$b2sum -c <<< "$("$idcas" --print-file-hash -m test.map test.bin)  urfs.base/test.bin"
mv test.map{,.pure}

# probability=0 seem to be =1%, as in "random(0, 100) <= n"
cat <<EOF >urfs.base/unreliablefs.conf
[errinj_errno]
op_regexp = ^read$
path_regexp = .*
probability = 4
EOF

# prob=4 seed=13 :: File LB#10 [3.9 MiB] read failed at 41615360 B offset [39.6 MiB]
unreliablefs urfs -f -basedir=urfs.base -seed=13 &>/dev/null & urfs_pid=$!
for n in {1..20}; do [[ ! -e urfs/test.bin ]] || break; read -rt 0.1 <> <(:) ||:; done
# dd if=urfs/test.bin of=/dev/null bs=4161536

rm -f test.map
"$idcas" -vm test.map --skip-read-errors urfs/test.bin test.bin.corrupt
cp -a test.map{,.corrupt}

umount urfs
kill $urfs_pid &>/dev/null ||:

# Test: skipped (unreadable) blocks in HM should always be replaced with something meaningful
if cmp -s test.bin{.corrupt,} ; then false - corrupt file ended up same as the original ; fi
cp -a test.map{.corrupt,}
if "$idcas" -vC -m test.map test.bin ; then false - corrupt map not updated from clean src ; fi
if "$idcas" -c -m test.map test.bin.corrupt ; then false - corrupt map not updated from 0000-block src ; fi

# Test: corrupted blocks get fixed
cp -a test.bin.{corrupt,fix} && cp -a test.map{.corrupt,}
$b2sum -c <<< "$("$idcas" --print-file-hash -m test.map test.bin test.bin.fix)  test.bin"
mv test.map{,.fix}

# Test: create sparse patch-file
rm -f test.patch
cp -a test.map{.corrupt,}
$b2sum -c <<< "$("$idcas" --print-file-hash -m test.map test.bin test.patch)  test.bin"
mv test.map{,.bmap}
[[ $(du -BK test.patch | cut -f1) = 32K ]]
[[ $(du --apparent-size -BK test.patch | cut -f1) != 32K ]]

# Test: XXX - need to find tool or add mode for that
# cp -a test.bin{,.patched-1}
# cp -a test.bin.{corrupt,patched-2}
# cp-sparse-only test.patch test.bin.patched-1
# cp-sparse-only test.patch test.bin.patched-2
# $b2sum test.bin test.bin.patched-{1,2}

}


### Run all test blocks from above
# Split into blocks to make it easy to re-run only specific block of linked tests

test_basics
test_flakey

rm -rf /tmp/idcas
err=0 # success for all tests above
