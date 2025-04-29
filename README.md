# Incremetal Disk (or VM-image/big-file) Compare And Sync tool (idcas)

Tool to build/maintain hash-map of source file/blkdev/img blocks, to later
detect changed ones, and copy those to destination using as few read/write
operations as possible.

It is useful when source is fast (e.g. local SSD), but destination is
either slow (like network or USB-HDD), or has limited write endurance
(cloning large partitions/files between SSDs, for example), as well
as some other more specialized use-cases - see below.


**Table of Contents:**

- [Build and usage](#hdr-build_and_usage)
- [Description](#hdr-description)

    - [Intended use-cases](#hdr-intended_use-cases_include_)
    - [Non-goals](#hdr-non-goals_for_this_tool_)

- [More technical and usage info](#hdr-more_technical_and_usage_info)
- [sparse_patch.nim]
- [Known limitations and things to improve later]

[sparse_patch.nim]: #hdr-sparse_patch.nim
[Known limitations and things to improve later]:
  #hdr-known_limitations_and_things_to_improve_later


Alternative repository URLs:

- <https://github.com/mk-fg/incremetal-disk-compare-and-sync>
- <https://codeberg.org/mk-fg/incremetal-disk-compare-and-sync>
- <https://fraggod.net/code/git/incremetal-disk-compare-and-sync>



<a name=hdr-build_and_usage></a><a name=user-content-hdr-build_and_usage></a>
## Build and usage

This tool is written in [Nim] C-adjacent language, linked against [OpenSSL] (libcrypto).

Build with the usual "make": `make`\
... or alternatively: `nim c -d:release -d:strip -d:lto_incremental --opt:speed idcas.nim`\
Smoke-test and usage info: `./idcas -h`

Installation: copy resulting binary to anywhere you can/intend-to run it from.

Usage example:

```
# Make full initial backup-copy of some virtual machine image file
# Same thing as "cp" does, but also auto-generates hash-map-file (vm.img.idcas)
% idcas vm.img /mnt/usb-hdd/vm.img.bak

## ...VM runs and stuff changes in vm.img after this...

# Fancy: make date/time-suffixed btrfs/zfs copy-on-write snapshot of vm.img backup
% cp --reflink /mnt/usb-hdd/vm.img.bak{,.$(date -Is)}

# Efficiently update vm.img.bak file, overwriting only changed blocks in-place
% idcas -v vm.img /mnt/usb-hdd/vm.img.bak
Stats: 50 GiB file + 50.0 MiB hash-map ::
  12_800 LBs, 7 updated :: 889 SBs compared, 19 copied :: 608 KiB written

# Repeat right after that - vm.img checked against hash-map, but nothing to update
% idcas -v vm.img /mnt/usb-hdd/vm.img.bak
Stats: 50 GiB file + 50.0 MiB hash-map ::
  12_800 LBs, 0 updated :: 0 SBs compared, 0 copied :: 0 B written

## Run with -h/--help for more info on various options and their defaults.
```

See below for more information on how it works and what it can be suitable for.

Additional [Dockerfile] in the repository can be used to build normal and static
portable tool binaries, which should work on any same-arch linux distro, without
any library dependencies in case of static one (useful for data-recovery scenarios,
when e.g. booting arbitrary distros like [grml] or [SystemRescue] from a USB stick).

With usable/running docker on the system, following command should produce
"idcas.musl" + "idcas.static" binaries in the current directory:

    docker buildx build --output type=local,dest=. .

Any non-default parameters to compile with can be added on `RUN nim c ...`
lines in the Dockerfile. Unintuitive "don't know about --output" errors likely
mean missing [docker-buildx] plugin (replaces legacy "docker build" command).

`make test` or `./test.sh` can be used to run some basic functional tests on
the produced binary, using tmpfs dir in /tmp, [sparse_patch.nim] and [unreliablefs]
fuse-filesystem (for `--skip-read-errors` option).

[Nim]: https://nim-lang.org/
[OpenSSL]: https://www.openssl.org/
[Dockerfile]: Dockerfile
[grml]: https://grml.org/
[SystemRescue]: https://www.system-rescue.org/
[docker-buildx]: https://docs.docker.com/go/buildx/
[unreliablefs]: https://github.com/ligurio/unreliablefs



<a name=hdr-description></a><a name=user-content-hdr-description></a>
## Description

This tool always reads over all data in the source arg sequentially in a single pass,
comparing it block-by-block to existing hash-map-file info (if any), copying small
changed blocks to destination on mismatches there (in same sequence/order),
and updating hash-map with new hash(-es).

That is somewhat similar to how common [rsync] and [rdiff] tools work,
but much simpler, side-stepping following limitations imposed by those:

- rsync always re-reads whole source/destination files.

- rdiff can also create "signature" (hash-map) of the file, but does not allow
    updating destination in-place, always has to reconstruct full copy of it,
    even if it's 1B difference in a 100 GiB file.

    Likely reason for that is using rsync's algorithm - can't easily move/clone/dedup
    data blocks without copy, which it's kinda intended to do efficiently.

- rdiff file "signatures" are unnecessarily large, because all blocks in those
    have to be uniquely identified without any hash collisions, which is not useful
    for simply comparing src-dst blocks in pairs.

- rdiff cannot update its "signature" files, only make new ones from scratch.

Instead, as mentioned, this tool only updates changed blocks in destination path
(must be seekable, but otherwise anything goes) in-place, updates hash-map file
in-place alongside destination, and does not do anything more fancy than that.

[rsync]: https://rsync.samba.org/
[rdiff]: https://librsync.github.io/page_rdiff.html


<a name=hdr-intended_use-cases_include_></a><a name=user-content-hdr-intended_use-cases_include_></a>
### Intended use-cases include:

- Synchronizing two devices (or VM-images, any large files) with as little
    read/write operations or extra work as possible.

    For example, if 1T-sized `/dev/sda` SSD is backed-up to a slow `/mnt/backup/sda.img`,
    and only minor part of it is updated during day-to-day use, there is no need to
    either (A) overwrite whole 1T of data on slow sda.img, (B) read whole sda.img dst-file,
    if it is just an unchanged old copy, or (C) do a copy-replace of sda.img destination,
    instead of only overwriting changed bits.

    cat/dd/rsync/rdiff tools do some of those, this one does neither.

- Efficient image-file backups utilizing copy-on-write reflinks.

    `cp --reflink vm.img vm.img.old.$(date -Id)` quickly creates a copy-on-write
    clone of a file on [btrfs] and newer [zfs] versions, after which, applying small update
    to `vm.img` (as this tool does) results in an efficient fs-level data deduplication.

    (also `--reflink` should be auto-detected and used by default in modern cp)

- Making sparse binary-delta files, which can be deflated via compression or [bmap-tools].

    Running this tool with a hash-map to detect changes, but to an empty destination file,
    will result in a sparse file, where only changed blocks are mapped.
    Trivial [sparse_patch.nim] tool in this repo can be used to efficiently copy only those
    mapped chunks to a destination file/device, without touching anything else there.

- Resumable/repeatable dumb-copy between two devices, to use instead of dd/[ddrescue].

    Sometimes you just have to tweak minor stuff on source dev and copy it again, or
    copy things back to source device - having hashmap allows to only find/sync changes,
    without another full clone, that is a waste of time and SSD cycles.

- Efficient copy/update/fix for files with read errors in them.

    `--skip-read-errors` option allows to set hashes for unreadable blocks to
    special "invalid" values (and skip them otherwise), which can then be used in
    various ways to copy/replace only those small corrupted blocks from elsewhere
    (some other copy/snapshot maybe).

For most other uses, aforementioned [rdiff] and [rsync] tools might be good enough
(see rsync's `--partial`, `--inplace` and `--append-verify` opts in particular,
as well as `--copy-devices`/`--write-devices` for block devices) - make sure to
look at those first.

[btrfs]: https://btrfs.readthedocs.io/en/latest/
[zfs]: https://zfsonlinux.org/
[bmap-tools]: https://manpages.debian.org/testing/bmap-tools/bmaptool.1.en.html
[ddrescue]: https://www.gnu.org/software/ddrescue/ddrescue.html


<a name=hdr-non-goals_for_this_tool_></a><a name=user-content-hdr-non-goals_for_this_tool_></a>
### Non-goals for this tool:

- Deduplication within files and between chunks of files at different offsets.

    That's what rdiff/rsync/xdelta tools do, and it creates technical requirements
    in direct conflict with how this tool works, as outlined above.

- Atomicity ("all of nothing" operation) wrt any interrupts, power outages,
  crashes, etc - not handled in any special way.

    I'd recommend using modern filesystems' snapshotting and copy-on-write
    functionality for that, but if it's not an option, following process should
    avoid any such potential issues:

    - Before sync, copy current hash-map-file to e.g. `hash-map-file.new`.

    - Run the tool with `--hash-map hash-map-file.new`, updating that and dst-file.

    - After completion, run `sync` or such to flush pending writes to disk,
        and rename `hash-map-file.new` to persistent place after that,
        atomically replacing earlier file.

    Interruption/restart during this will at worst redo some copying using same old hash-map.

- Anything to do with multiple files/directories on a filesystem - tool operates
    on a single explicitly-specified src/dst files directly, and that's it.

    [casync] and various incremental backup solutions ([bup], [borg], [restic], etc)
    are good for recursive stuff.

- Making smallest-possible separate binary patches - see [xdelta3] and compression tools.

- Network transmission/protocols or related optimizations.

    It's possible to `rsync -S` a sparse file delta, or use path on a network
    filesystem as a sync destination, but there's nothing beyond that.

- Compression - nothing is compressed/decompressed by the tool itself.

- Data integrity/secrecy in adversarial contexts and such security stuff.

    Malicious tampering with the inputs/outputs is not considered here,
    use separate auth/encryption to prevent that as necessary.

    Simple "compare blocks at same offset" design makes it optimal for syncing
    encrypted devices/imgs/filesystems though (e.g. LUKS volumes), with no time
    wasted on finding similar or relocated data (impossible with any half-decent
    encryption system) or trying to compress uniformly-random encrypted blocks.

- Syncing deltas from files with immutable source instead of immutable destination.

    That's more into [zsync] and [bittorrent] territory, i.e. file-sharing tools.

- Any kind of permissions and file metadata - only file contents are synchronized.

It is also **not** a good replacement for [btrfs]/[zfs] send/recv replication
functionality, and should work much worse when synchronising underlying devices
for these and other copy-on-write filesystems, because they basically log all
changes made to them, not overwrite same blocks in-place, producing massive
diffs in underlying storage even when actual user-visible delta ends up being
tiny or non-existant.

Which is (partly) why they have much more efficient fs-level incremental
replication built into them - it should be a much better option than a "dumb"
block-level replication of underlying storage for those, aside from potential
issues with copying fs corruption or security implications (i.e. allows for
possibility of destroying filesystem on the receiving end).

[casync]: https://github.com/systemd/casync
[bup]: https://bup.github.io/
[borg]: https://www.borgbackup.org/
[restic]: https://restic.net/
[xdelta3]: http://xdelta.org/
[zsync]: http://zsync.moria.org.uk/
[bittorrent]: https://en.wikipedia.org/wiki/BitTorrent



<a name=hdr-more_technical_and_usage_info></a><a name=user-content-hdr-more_technical_and_usage_info></a>
## More technical and usage info

Whole operation is broken into following steps:

- Large Blocks (LBs, ~4 MiB by default) are read sequentially from source into memory.

    There's an exception with `--skip-read-errors` option when read fails -
    then same LB will be read in SB chunks, mapping which exact SBs fail to read,
    to skip data from those later and write their checksum as all-zeroes reserved value.

- For each such block, corresponding hash-map-file block is read (4 KiB by default).

- First 32B [BLAKE2b] hash in hash-block is for LB, and it's checked to see if whole
    LB can be skipped, in which case it's back to step-1 with next LB until file ends.

- Rest of the (4K by default) hash-map block is composed of small-block hashes -
    SBs, 32K bytes by default, with same 32B BLAKE2b hash for each - which are
    checked against these SBs in order, detecting ones that changed and writing
    those out to destination at the same offset(s) as in source.

- hash-map-file (4K) block gets replaced with the one computed from updated src data.

- Back to step-1 for reading the next LB, and so on until the end of source file.

- Once source file ends, destination file and hash-map-file get truncated to
    relevant sizes (= source for dst, and up to what was processed for hash-map),
    if source got smaller, or otherwise will naturally grow as well, as changes
    against "nothing" get appended there.

In special modes, like building hash-map-file or validation-only, process is
simplified to remove updating destination/hash-map steps that aren't relevant.

`--print-file-hash` and `--print-hm-hash` options, if specified, calculate
their hashes from file reads/writes as they happen during this process.

Hash-map file has a header with LB/SB block sizes, and if those don't match
exactly, it is truncated/discarded as invalid and gets rebuilt from scratch,
copying all data too.

Default (as of 2023-03-05) LB/SB block sizes correspond to following ratios:

- ~4 MiB large block (LB) creates/updates/corresponds-to exactly 4 KiB block of
  hashes (32B LB hash + 127 \* 32B SB hashes).

- So 1 GiB file will have about 1 MiB of hash-map metadata, ~7 GiB hash-map for
  a 7 TiB file, and so on - very easy to estimate with ~1024x diff (2^10) in
  block sizes like that.

These sizes can be set at compile-time, using `-d` define-options for
nim-compile command, for example:

    nim c -d:IDCAS_LBS=4161536 -d:IDCAS_SBS=32768 ...

Can also be overidden using `-B/--block-large` and `-b/--block-small`
command-line options at runtime.

When changing those, it might be a good idea to run the tool only on dst-file
first, without src-file argument, to read it and rebuild its hash-map from scratch,
so that subsequent run with same parameters can use that, instead of doing full
copy (and all-writes in place of mostly-reads).

While using the tool from scripts, `-M/--hash-map-update` option can be added
to treat missing or invalid hash-map-file as an error, as it should probably always
be there for routine runs, and should never be rebuilt anew with a complete resync
by such scripts.

Hash-map file format is not tied to current host's C type sizes or endianness.

[BLAKE2b]: https://en.wikipedia.org/wiki/BLAKE_(hash_function)



<a name=hdr-sparse_patch.nim></a><a name=user-content-hdr-sparse_patch.nim></a>
## sparse_patch.nim

When using a non-existant (or sparse) destination file with pre-existing
hash-map-file, "idcas" tool will create a sparse file there, which only includes
changed blocks at correct offsets - a kind of binary diff or patch file.

sparse_patch binary can then be used to only copy/apply those actually-written
non-sparse parts of such patch-file to somewhere else (e.g. actual destination device),
without touching anything else there.
It's only used for tests here, but might be more useful generally.

It uses [linux-3.1+ lseek() SEEK_DATA/SEEK_HOLE flags] for skipping over
unmapped chunks efficiently, without mapping all blocks or extents via older
ioctl() APIs, and is a very simple "seek/read/write loop" for this one task.

Can be built with: `nim c -d:release -d:strip -d:lto_incremental --opt:size sparse_patch.nim`\
Usage info: `./sparse_patch -h`

Especially if using custom block sizes (e.g. smaller than default 4096), make
sure to test whether sparse files have enough granularity when relying on those.
That is, whether sparse areas can start at smaller block offsets, or must be
aligned to 512 or 4k blocks/pages on the specific OS/filesystem, for example.

Most tools, when working with sparse files, tend to replicate them to destination
(e.g. cp, rsync, bmaptool copy, etc), discarding data there as well, skip
all-zero blocks, or are easy to misuse as such, which this sparse_patch tool
explicitly does not and cannot do.

I.e. they work assuming that destination file is sparse and should be as sparse
as possible, while sparse_patch does kinda opposite - assumes that source file
is meaningfully sparse, and whether destination one is kept sparse is irrelevant.

For example, modern cp tool from [coreutls] can use SEEK_HOLE logic as well
(if built with support for it, otherwise silently falls back to zero-byte-detection),
but is also documented to "create a sparse DEST file whenever the SOURCE file
contains a long enough sequence of zero bytes" when using `--sparse` option,
which is distinct from only copying non-sparse extents from source - zero-bytes
can be in a legitimate non-sparse source data too, and should be written to
destination, never dropped like that.

[linux-3.1+ lseek() SEEK_DATA/SEEK_HOLE flags]:
  https://man.archlinux.org/man/lseek.2#Seeking_file_data_and_holes
[coreutls]: https://www.gnu.org/software/coreutils/



<a name=hdr-known_limitations_and_things_to_improve_later></a><a name=user-content-hdr-known_limitations_and_things_to_improve_later></a>
## Known limitations and things to improve later

- Works in a simple sequential single-threaded way, which will easily bottleneck
    on CPU for computing hashes when using >200 MiB/s SSD/NVMe drives.

    Can be improved rather easily by putting a fixed-size thread-pool between
    sequential reader/writer parts, which will hash/match read data buffers in parallel.

- It'd be nice to discard sequential all-NUL blocks in output - make file sparse
    instead of writing those out needlessly.
