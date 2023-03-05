Incremetal Disk (or VM-image/big-file) Compare And Sync tool (idcas)
======================================================================

Tool to build/maintain hash-map of source file/dev/img blocks, to later detect changed
ones, and copy those to destination using as few read/write operations as possible.

It is useful when source is fast (e.g. local SSD), but destination is
either slow (like network or USB-HDD), or has limited write endurance
(cloning large partitions between SSDs, for example), as well as some
other more specialized use-cases - see below.

.. contents::
  :backlinks: none


Build and usage
---------------

This tool is written in Nim_ C-adjacent language, linked against OpenSSL_ (libcrypto).

Build it with: ``nim c -d:production -o=idcas idcas.nim && strip idcas``

Test and usage info: ``./idcas -h``

Installation: copy to anywhere you can/intend-to run it from.

Usage example::

  # Make full initial backup-copy of some virtual machine image file
  # Same thing as "cp" does, but also auto-generates hash-map-file (vm.img.idcas)
  % idcas vm.img /mnt/usb-hdd/vm.img.bak

  ## ...VM runs and stuff changes in vm.img after this...

  # Fancy: make date/time-suffixed btrfs copy-on-write snapshot of vm.img backup
  % cp --reflink /mnt/usb-hdd/vm.img.bak{,.$(date -Is)}

  # Efficiently update vm.img.bak file, overwriting only changed blocks in-place
  % idcas -v vm.img /mnt/usb-hdd/vm.img.bak
  Stats: 50 GiB file + 50.0 MiB hash-map ::
    12800 LBs, 7 updated :: 889 SBs compared, 19 copied :: 608 KiB written

  # Repeat right after that - vm.img checked against hash-map, but nothing to update
  % idcas -v vm.img /mnt/usb-hdd/vm.img.bak
  Stats: 50 GiB file + 50.0 MiB hash-map ::
    12800 LBs, 0 updated :: 0 SBs compared, 0 copied :: 0 B written

  ## Run with -h/--help for more info on various options and their defaults.

See below for more information on how it works and what it can be suitable for.

.. _Nim: https://nim-lang.org/
.. _OpenSSL: https://www.openssl.org/


Description
-----------

This tool always reads over all data in the source arg in one pass, comparing it
block-by-block to existing hash-map-file info (if any), copying small changed
blocks to destination on mismatches there, and updating hash-map with new hash(-es).

It's somewhat similar to how common rsync_ and rdiff_ tools work,
but much simplier, side-stepping following limitations imposed by those:

- rsync always reads whole source file, and cannot use block device destination.

  One reason for latter limitation is due to how its delta-xfer algorithm
  works - it support moving data around, which can only be done efficiently
  when creating a new file copy.

- rdiff can also create "signature" (hash-map) of the file, but does not allow
  updating destination in-place, always has to reconstruct full copy of it,
  even if it's 1B difference in a 100 GiB file.

  Likely reason for that is same as with rsync - can't easily move/clone/dedup
  data blocks without copy, which it's kinda intended to do efficiently.

- rdiff file "signatures" are unnecessarily large, because all blocks in those
  have to be uniquely identified without any hash collisions, which is not useful
  for simply comparing src-dst blocks in pairs.

- rdiff cannot update its "signature" files, only make new ones from scratch.

Instead, as mentioned, this tool only updates changed blocks in destination path
(must be seekable, but otherwise anything goes) in-place, updates hash-map file
in-place alongside destination, and does not do anything more fancy than that.

Intended use-cases include:

- Synchronizing two devices (or VM-images, any large files) with as little
  read/write operations or extra work as possible.

  For example, if 1T-sized ``/dev/sda`` SSD is backed-up to a slow ``/mnt/backup/sda.img``,
  and only minor part of it is updated during day-to-day use, there is no need to
  either (A) overwrite whole 1T of data on slow sda.img, (B) read whole sda.img dst-file,
  if it is just an unchanged old copy, or (C) do a copy-replace of sda.img destination,
  instead of only overwriting changed bits.

  rsync/rdiff do some of those, this tool does neither.

- Efficient backups utilizing btrfs_ reflinks and its copy-on-write design.

  ``cp --reflink vm.img vm.img.old.$(date -Id)`` instantly creates a
  copy-on-write clone of a file on btrfs, after which, applying small update to
  ``vm.img`` (as this tool does) results in a very efficient fs-level data deduplication.

- Making sparse binary-delta files, which are easy to copy/apply using bmap-tools_.

  Running this tool with a hash-map to detect changes, but to an empty destination
  file, will result in "sparse" file, where only changed blocks are "mapped".

  Such sparse files can be stored/compressed efficiently, even without
  copy-on-write filesystem/tricks, and bmaptool_ can easily copy only mapped
  blocks to a non-sparse destination (i.e. "apply patch/delta" that way),
  or convert those to/from non-sparse files as-needed.

For most other uses, aforementioned rdiff_ and rsync_ tools might be good enough
(see rsync's --partial, --inplace and --append-verify opts in particular) - make
sure to look at those first.

**Non-goals** for this tool:

- Deduplication within files and between chunks of files at different offsets.

  That's what rdiff/rsync/xdelta tools do, and it creates technical requirements
  in direct conflict with how this tool works, as outlined above.

- Atomicity ("all of nothing" operation) wrt any interrupts, power outages,
  crashes, etc - not handled in any special way.

  I'd recommend using modern filesystems' snapshotting and copy-on-write
  functionality for that, but if it's not an option, following process should
  avoid any such potential issues:

  - Before sync, copy current hash-map-file to e.g. ``hash-map-file.new``.
  - Run the tool with ``--hash-map hash-map-file.new``, updating that and dst-file.
  - After completion, run ``sync`` or such to flush pending writes to disk, and rename
    ``hash-map-file.new`` to persistent place after that, atomically replacing earlier file.

  Any interruption during this will at worst redo some copying from the old hash-map.

- Anything to do with multiple files/directories on a filesystem - works between
  single explicitly-specified src/dst paths directly, and that's it.

  casync_ and various incremental backup solutions are good for recursive stuff.

- Making smallest-possible separate binary patches - see xdelta3_ and
  compression tools.

- Network transmission/protocols or related optimizations.

  It's possible to ``rsync -S`` a sparse file delta, or use path on a network
  filesystem as a sync destination, but there's nothing beyond that.

- Compression - nothing is compressed/decompressed by the tool itself.

- Data integrity/secrecy in adversarial contexts and such security stuff.

  Malicious tampering with the inputs/outputs is not considered here,
  use separate auth/encryption to prevent that as necessary.

  Simple "compare blocks" design makes it optimal for syncing encrypted
  devices/imgs/filesystems (e.g. LUKS volumes), with no time wasted on finding
  similar or relocated data (impossible with any half-decent encryption system)
  or trying to compress uniformly-random encrypted blocks.

- Syncing deltas from files with immutable source instead of immutable destination.

  That's more into zsync_ and bittorrent_ territory, i.e. file-sharing tools.

- Any kind of permissions and file metadata - only file contents are synchronized.

.. _rsync: https://rsync.samba.org/
.. _rdiff: https://librsync.github.io/page_rdiff.html
.. _btrfs: https://btrfs.wiki.kernel.org/index.php/Main_Page
.. _bmaptool: https://github.com/intel/bmap-tools
.. _bmap-tools: https://manpages.debian.org/testing/bmap-tools/bmaptool.1.en.html
.. _casync: https://github.com/systemd/casync
.. _xdelta3: http://xdelta.org/
.. _zsync: http://zsync.moria.org.uk/
.. _bittorrent: https://en.wikipedia.org/wiki/BitTorrent


More technical and usage info
-----------------------------

Whole operation is broken into following steps:

- Large Blocks (LBs, ~4 MiB by default) are read sequentially from source into memory.

- For each such block, corresponding hash-map-file block is read (4 KiB by default).

- First 32B BLAKE2s_ hash in hash-block is for LB, and it's checked to see if whole
  LB can be skipped, in which case it's back to step-1 with next LB until file ends.

- Rest of the (4K by default) hash-map block is composed of small-block hashes -
  SBs, 32K bytes by default, with same 32B BLAKE2s hash for each - which are
  checked against these SBs in order, detecting ones that changed and writing
  those out to destination at the same offset(s) as in source.

- hash-map-file (4K) block gets replaced with the one computed from updated src data.

- Back to step-1 for reading the next LB, and so on until the end of source file.

- Once source file ends, destination file and hash-map-file get truncated to
  relevant sizes (= source for dst, and up to what was processed for hash-map),
  if source got smaller, or otherwise will naturally grow as well, as changes
  against "nothing" get appended there.

In special modes like building hash-map-file or checking one file, process is
simplified to remove updating destination/hash-map steps that aren't relevant.

Hash-map file has a header with LB/SB block sizes, and if those don't match exactly,
hash-map-file is truncated and gets rebuilt from scratch, copying all data too.

Default (as on 2023-03-05) LB/SB block sizes correspond to following rules:

- ~4 MiB large block (LB) creates/updates/corresponds-to exactly 4 KiB block of
  hashes (32B LB hash + 127 \* 32B SB hashes).

- So 1 GiB file will have about 1 MiB of hash-map metadata, ~7 GiB hash-map for
  a 7 TiB file, and so on - very easy to estimate with ~1024x diff in block sizes
  like that.

These sizes can be set at compile-time, using ``-d`` define-options for
nim-compile command, for example::

  nim c -d:IDCAS_LBS=4161536 -d:IDCAS_SBS=32768 ...

Can also be overidden using ``-B/--block-large`` and ``-b/--block-small``
command-line options at runtime.

When changing those, it might be a good idea to run the tool only on dst-file
first, without src-file argument, to read it and rebuild hash-map from scratch,
so that subsequent run with same parameters can use that, instead of doing full
copy (and a lot of writes intead of reads).

While using the tool from scripts, ``-M/--hash-map-update`` option can be added
to treat missing or invalid hash-map-file as an error, as it should probably always
be there for routine runs, and should never be rebuilt anew with a complete resync
by such scripts.

.. _BLAKE2s: https://en.wikipedia.org/wiki/BLAKE_(hash_function)
