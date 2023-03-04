Incremetal Disk (or VM-image/big-file) Compare And Sync tool (idcas)
======================================================================

**Not Usable**: this project is under development, do not use it yet.

Tool to build/maintain a hash-map of source file/dev/image blocks,
to later update those blocks in-place in a destination copy efficiently.

This is somewhat similar to how common rsync_ and rdiff_ tools work,
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

Instead, this tool only updates changed blocks in destination file-alike in-place,
updates hash-map file in-place alongside destination, and does not do anything more
fancy than that.

Intended use-cases include:

- Synchronizing two devices (or VM-images, any large files) with as little
  read/write operations or extra work as possible.

  For example, if 1T-sized ``/dev/sda`` SSD is backed-up to a slow ``/mnt/backup/sda.img``,
  and only minor part of it is updated during day-to-day use, there is no need to
  either (A) overwrite whole 1T of data on slow sda.img, (B) read whole sda.img file,
  if it is just an unchanged old copy, or (C) make a copy of sda.img dst-file.

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

- Any kind of permissions and file metadata - only file contents are synchronized.

- Anything to do with multiple files/directories on a filesystem - works between
  one explicitly-specified src/dst paths directly, and that's it.

  casync_ and various incremental backup solutions are usually good for that.

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
  devices/images/filesystems (e.g. LUKS volumes), with no time wasted on finding
  similar or relocated data (impossible with any half-decent encryption system)
  or trying to compress uniformly-random encrypted blocks.

- Syncing deltas from files with immutable source instead of immutable destination.

  That's more into zsync_ and bittorrent_ territory, i.e. file-sharing tools.


.. _rsync: https://rsync.samba.org/
.. _rdiff: https://librsync.github.io/page_rdiff.html
.. _btrfs: https://btrfs.wiki.kernel.org/index.php/Main_Page
.. _bmaptool: https://github.com/intel/bmap-tools
.. _bmap-tools: https://manpages.debian.org/testing/bmap-tools/bmaptool.1.en.html
.. _casync: https://github.com/systemd/casync
.. _xdelta3: http://xdelta.org/
.. _zsync: http://zsync.moria.org.uk/
.. _bittorrent: https://en.wikipedia.org/wiki/BitTorrent
