#? replace(sub = "\t", by = "  ")
#
# Debug build/run: nim c -w=on --hints=on -r idcas.nim -h
# Final build: nim c -d:release --opt:speed idcas.nim && strip idcas
# Usage info: ./idcas -h

import std/[ strformat, strutils, parseopt, os, posix, re ]


const IDCAS_MAGIC {.strdefine.} = "idcas-hash-map-2"
const IDCAS_HM_EXT {.strdefine.} = ".idcas" # default hashmap-file suffix
const IDCAS_LBS {.intdefine.} = 4161536 # <4M - large blocks to check for initial mismatches
const IDCAS_SBS {.intdefine.} = 32768 # 32K - blocks to compare/copy on LBS mismatch
# hash-map-file block = 32B lb-hash + 32B * (lbs / sbs) = neat 4K (w/ sbs=32K lbs=127*32K)

when IDCAS_LBS <= IDCAS_SBS or IDCAS_LBS %% IDCAS_SBS != 0:
	{.emit: "#error Compiled-in LB/SB size values mismatch - LBS must be larger and divisible by SBS".}


{.passl: "-lcrypto"}

type
	EVP_MD = distinct pointer
	EVP_MD_CTX = distinct pointer
	OSSL_PARAM = distinct pointer

proc EVP_MD_fetch( lib_ctx: pointer,
	algo: cstring, params: cstring ): EVP_MD {.importc, header: "<openssl/evp.h>".}
proc EVP_MD_CTX_new: EVP_MD_CTX {.importc, header: "<openssl/evp.h>".}
proc EVP_MD_CTX_free(md_ctx: EVP_MD_CTX) {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestInit( md_ctx: EVP_MD_CTX,
	md: EVP_MD ): cint {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestInit_ex2( md_ctx: EVP_MD_CTX,
	md: EVP_MD, params: OSSL_PARAM ): cint {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestUpdate( md_ctx: EVP_MD_CTX,
	data: pointer, data_len: cint ): cint {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestFinal_ex( md_ctx: EVP_MD_CTX,
	digest: pointer, digest_len: ptr cint ): cint {.importc, header: "<openssl/evp.h>".}

{.emit:"""
#include <openssl/params.h>
const size_t BLAKE2B_256BIT_LEN = 32;
const OSSL_PARAM BLAKE2B_256BIT[] = {
	OSSL_PARAM_size_t("size", &BLAKE2B_256BIT_LEN), OSSL_PARAM_END };""".}
let
	BLAKE2B = EVP_MD_fetch(nil, "BLAKE2B-512", nil)
	BLAKE2B_256BIT {.importc, nodecl.}: OSSL_PARAM


proc sz(v: int|int64): string =
	formatSize(v, includeSpace=true).replacef(re"(\.\d)\d+", "$1")
template nfmt(v: untyped): string = ($v).insertSep # format integer with digit groups

proc err_quit(s: string) = quit "ERROR: " & s
proc err_warn(s: string) = writeLine(stderr, "WARNING: " & s); flushFile(stderr)

proc main_help(err="") =
	proc print(s: string) =
		let dst = if err == "": stdout else: stderr
		write(dst, s); write(dst, "\n")
	let app = getAppFilename().lastPathPart
	if err != "": print &"ERROR: {err}"
	print &"\nUsage: {app} [options] [src-file] dst-file"
	if err != "":
		print &"Run '{app} --help' for more information"
		quit 0
	print dedent(&"""

		Incremetal Disk (or VM-image/big-file) Compare And Sync tool (idcas).
		Build/maintains hash-map of a file/dev/img blocks, to later update
			those in-place in a destination copy efficiently, as they change in source.

		Example usage:

			## Make full initial backup-copy of some virtual machine image file
			## Same thing as "cp", but also auto-generates hash-map-file while copying it
				% {app} vm.img /mnt/usb-hdd/vm.img.bak
			## ...VM runs and stuff changes in vm.img after this

			## Make date/time-suffixed btrfs copy-on-write snapshot of vm.img backup
				% cp --reflink /mnt/usb-hdd/vm.img.bak{{,.$(date -Is)}}
			## Efficiently update vm.img.bak file, overwriting only changed blocks in-place
				% {app} -v vm.img /mnt/usb-hdd/vm.img.bak
			## ...and so on - block devices or sparse files can also be used here

		Hash-map file in this example is generated/updated as /mnt/usb-hdd/vm.img.bak{IDCAS_HM_EXT}
		Hash function used in hash-map-file is always 32B BLAKE2s from OpenSSL.

		Arguments and options (in "{app} [options] [src-file] dst-file" command):

			<src-file>
				Source file to read and copy/update both hash-map-file and dst-file from.
				Always read from start to finish in a single pass, so can also be a fifo pipe.
				If omitted, hash-map-file for dst-file is created/updated, nothing copied.

			<dst-file>
				Destination file to update in-place from src-file according to hash-map-file
					(if it exists), or otherwise do a full copy from src-file to it (if specified).
				If only one file argument is passed, it is assumed to be a dst-file
					to create/update hash-map-file for, instead of copying file contents in any way.

			-m/--hash-map <hash-map-file>
				Hash-map file to read/create/update in-place, as needed.
				If not specified, default is to use file next to dst-file with {IDCAS_HM_EXT} suffix.
				Created if missing (without -M/--hash-map-update), updated in-place otherwise.

			-M/--hash-map-update
				Exit with error code and message if -m/--hash-map file does not exist or invalid.
				This is intended to be used in scripts, where missing file might indicate a bug.

			-B/--block-large <bytes>
				Block size to store/update and initially compare for performance reasons, in bytes.
				It must always be a multiple of --block-small sizes, which are
					actually compared and copied upon hash mismatch in these large blocks.
				Default: {IDCAS_LBS} ({IDCAS_LBS.sz}, compile-time IDCAS_LBS option)

			-b/--block-small <bytes>
				Smallest block size to compare and store hash for in hash-map-file.
				Hashes for these blocks are loaded and compared/updated when
					large-block hash doesn't match, to find which of those to update.
				Default: {IDCAS_SBS} bytes ({IDCAS_SBS.sz}, compile-time IDCAS_SBS option)

			-c/--check
				Check specified dst-file against hash-map-file, without
					updating it, and exit immediately on any mismatch with non-zero status.
				Only single dst-file argument is allowed with this option. No output.

			-C/--check-full
				Similar to -c/--check, but checks all hash-map blocks in the file,
					and prints stats/hashes if -v/--verbose or --print-*-hash options are also used.

			--skip-read-errors
				Skip file read errors with -b/--block-small granularity,
					putting always-invalid all-zero hashes into hash-map for those blocks.
				This can be used to best-effort-read from a faulty device/fs,
					or mark position of bad blocks in hash-map-file and make sparse-patch
					for those from another file (e.g. a backup), without comparing them directly.
				Default is to abort and exit upon encountering any I/O error.

			--print-hm-hash
				Print hex-encoded BLAKE2b 512-bit hash line (no key/salt/person) of resulting
					hash-map file to stdout, matching "b2sum" or "openssl dgst" command outputs for it.
				More efficient than doing it separately, as tool always reads hash-map file anyway.

			--print-file-hash
				Same as --print-hm-hash, but prints BLAKE2b hash for processed file(s).
				Will be calculated from src-file reads, if specified, or dst-file reads otherwise.
				If both --print-*-hash options are used, this will be second hash line on stdout.

			-v/--verbose
				Print transfer statistics to stdout before exiting.
		""")
	quit 0

proc main(argv: seq[string]) =
	var
		opt_src = ""
		opt_dst = ""
		opt_hm_file = ""
		opt_hm_update = false
		opt_lbs = IDCAS_LBS
		opt_sbs = IDCAS_SBS
		opt_verbose = false
		opt_check = false
		opt_check_full = false
		opt_hm_hash = false
		opt_file_hash = false
		opt_skip_errs = false

	block cli_parser:
		var opt_last = ""
		proc opt_fmt(opt: string): string =
			if opt.len == 1: &"-{opt}" else: &"--{opt}"
		proc opt_empty_check =
			if opt_last == "": return
			main_help &"{opt_fmt(opt_last)} option unrecognized or requires a value"
		proc opt_set(k: string, v: string) =
			if k in ["m", "hash-map"]: opt_hm_file = v
			elif k in ["B", "block-large"]: opt_lbs = parseInt(v)
			elif k in ["b", "block-small"]: opt_sbs = parseInt(v)
			else: main_help &"Unrecognized option [ {opt_fmt(k)} = {v} ]"

		for t, opt, val in getopt(argv):
			case t
			of cmdEnd: break
			of cmdShortOption, cmdLongOption:
				if opt in ["h", "help"]: main_help()
				elif opt in ["M", "hash-map-update"]: opt_hm_update = true
				elif opt in ["v", "verbose"]: opt_verbose = true
				elif opt in ["c", "check"]: opt_check = true
				elif opt in ["C", "check-full"]: opt_check_full = true
				elif opt == "print-hm-hash": opt_hm_hash = true
				elif opt == "print-file-hash": opt_file_hash = true
				elif opt == "skip-read-errors": opt_skip_errs = true
				elif val == "": opt_empty_check(); opt_last = opt
				else: opt_set(opt, val)
			of cmdArgument:
				if opt_last != "": opt_set(opt_last, opt); opt_last = ""
				elif opt_src == "": opt_src = opt
				elif opt_dst == "": opt_dst = opt
				else: main_help(&"Unrecognized argument: {opt}")
		opt_empty_check()

		if opt_src == "" and opt_dst == "":
			main_help "Missing src/dst file arguments"
		elif opt_dst == "":
			opt_dst = opt_src; opt_src = ""
		if opt_hm_file == "":
			opt_hm_file = &"{opt_dst}{IDCAS_HM_EXT}"
		if opt_lbs <= opt_sbs or opt_lbs %% opt_sbs != 0:
			main_help "Large/small block sizes mismatch - must be divisible"
		if (opt_check or opt_check_full) and opt_src != "":
			main_help "Check options only work with a single file argument"
		if opt_skip_errs and opt_lbs / opt_sbs >= 65536:
			# This is due to using set[unit16] nim bit-vector, where uint16 is the limit
			err_quit "--skip-read-errors option doesn't allow lbs / sbs >= 2^16"


	### Open hash-map / source / destination files

	var
		src: File
		dst: File # nil if only one file is specified
		dst_fd: FileHandle
		dst_sz: int64
		dst_is_dev: bool
		hm: File
		hm_fd: FileHandle

	if opt_check or opt_check_full:
		if not hm.open(opt_hm_file):
			err_quit &"Failed to read-only open hash-map-file: {opt_hm_file}"
	else:
		hm_fd = open(opt_hm_file.cstring, O_CREAT or O_RDWR, 0o600)
		if hm_fd < 0 or not hm.open( hm_fd,
				if opt_check or opt_check_full: fmRead else: fmReadWriteExisting ):
			err_quit &"Failed to open/create hash-map-file: {opt_hm_file}"
	defer: hm.close

	if opt_src != "":
		if not src.open(opt_src):
			err_quit &"Failed to open src-file: {opt_src}"
		dst_fd = open(opt_dst.cstring, O_CREAT or O_RDWR, 0o600)
		if dst_fd < 0 or not dst.open(dst_fd, fmReadWriteExisting):
			err_quit &"Failed to open dst-file: {opt_dst}"
		dst_sz = dst.getFileSize
		block dst_type_check:
			var dst_st: Stat
			if fstat(dst_fd, dst_st) != 0: err_quit &"Failed to stat dst-file: {opt_dst}"
			dst_is_dev = S_ISBLK(dst_st.st_mode)

	else:
		if not src.open(opt_dst):
			err_quit &"Failed to open dst-file: {opt_dst}"

	defer: src.close; dst.close


	### State vars get reused for all blocks

	var
		lbs: int
		sbs: int
		eof = false
		lb_buff = newSeq[byte](opt_lbs)
		lb_pos: int64 = 0
		dst_pos: int64 = -1

		bh_md = BLAKE2B
		bh_md_params = BLAKE2B_256BIT
		bh_md_len = 32
		bh_len: cint
		bh_ctx = EVP_MD_CTX_new()

		hm_bs: int
		hm_sbc = int(opt_lbs / opt_sbs)
		hm_len = bh_md_len + bh_md_len * hm_sbc
		hm_pos: int64 = clamp(hm_len, 64, 4096)
		hm_errs: set[uint16]
		hm_blk = newSeq[byte](hm_len)
		hm_blk_new = newSeq[byte](hm_len)
		hm_blk_zero = newSeq[byte](hm_len)

		hdr_magic = IDCAS_MAGIC
		hdr_len = hdr_magic.len + 11
		hdr_pad = newSeq[byte](hm_pos - hdr_len) # block alignment, if works with hm_len/fs

		hash_md = BLAKE2B
		hash_md_len = 64
		hash_hm: EVP_MD_CTX
		hash_file: EVP_MD_CTX

		st_lb_chk = 0
		st_lb_upd = 0
		st_lb_err = 0
		st_sb_chk = 0
		st_sb_upd = 0
		st_sb_err = 0

	template hash_init(ctx: EVP_MD_CTX) =
		ctx = EVP_MD_CTX_new()
		if EVP_DigestInit(ctx, hash_md) != 1'i32: err_quit "hash init failed"
	template hash_update(ctx: EVP_MD_CTX, buff: seq[byte], bs=0) =
		if EVP_DigestUpdate(
				ctx, buff[0].addr, cint(if bs != 0: bs else: buff.len) ) != 1'i32:
			err_quit "hash update failed"
	proc hash_finalize(ctx: EVP_MD_CTX): string =
		result = newString(hash_md_len)
		if EVP_DigestFinal_ex(ctx, result[0].addr, bh_len.addr) != 1'i32 or
			bh_len != hash_md_len.cint: err_quit "hash finalize failed"
		EVP_MD_CTX_free(ctx)
	if opt_hm_hash: hash_init(hash_hm)
	if opt_file_hash: hash_init(hash_file)


	### Check if header matches all options, or replace it and zap the file

	block hm_hdr_check:
		var
			hdr_str = repeat(' ', hdr_len)
			hdr_bs: uint32
		copyMem(hdr_str[0].addr, hdr_magic[0].addr, hdr_magic.len)
		hdr_bs = opt_lbs.uint32.htonl
		copyMem(hdr_str[hdr_magic.len + 1].addr, hdr_bs.addr, 4)
		hdr_bs = opt_sbs.uint32.htonl
		copyMem(hdr_str[hdr_magic.len + 6].addr, hdr_bs.addr, 4)
		var hdr_code = cast[seq[byte]](hdr_str)
		if opt_hm_hash: hash_update(hash_hm, hdr_code)

		var hdr_file = newSeq[byte](hdr_len)
		hm.setFilePos(0)
		if hm.readBytes(hdr_file, 0, hdr_len) == hdr_len and
			hdr_file == hdr_code: break hm_hdr_check

		if opt_check: quit 1
		if opt_check_full or opt_hm_update:
			err_quit &"hash-map-file header mismatch: {opt_hm_file}"

		hm.setFilePos(0)
		if hm.writeBytes(hdr_code, 0, hdr_len) != hdr_len or
				hm_fd.ftruncate(hdr_len) != 0:
			err_quit &"Failed to replace hash-map-file header: {opt_hm_file}"

	if hm.readBytes(hdr_pad, 0, hdr_pad.len) != hdr_pad.len:
		hm.setFilePos(hm_pos)
	if opt_hm_hash: hash_update(hash_hm, hdr_pad)


	### Scan and update file blocks

	template hash_same(s1, s2: byte): bool =
		cmpMem(s1.addr, s2.addr, bh_md_len) == 0
	template hash_block_op(src, src_len, dst) =
		if not (
			EVP_DigestInit_ex2(bh_ctx, bh_md, bh_md_params) == 1'i32 and
			EVP_DigestUpdate(bh_ctx, src.addr, src_len.cint) == 1'i32 and
			EVP_DigestFinal_ex(bh_ctx, dst.addr, bh_len.addr) == 1'i32 and
			bh_len == bh_md_len.cint ): err_quit "block-hash failed"
	template hash_block(src: byte, src_len: int, dst: byte) =
		hash_block_op(src, src_len, dst)
		while true: # hm_blk_zero (all-zeroes) is not used as a valid hash
			if not hash_same(dst, hm_blk_zero[0]): break
			hash_block_op(dst, bh_len, dst)

	template lb_buff_read(sz: int, offset: int, bs: int) =
		sz = src.readBytes(lb_buff, offset, bs)
		if sz < bs:
			eof = src.endOfFile
			if not eof: err_quit "File read failed"
			if sz == 0: break

	while not eof:

		# Read lb_buff, with a fallback for --skip-read-errors
		try:
			lb_buff_read(lbs, 0, opt_lbs)
			if hm_errs.card > 0: hm_errs = {}

		except IOError:
			let err = &"LB#{st_lb_chk} [{opt_lbs.sz}]" &
				&" read failed at {lb_pos} B offset [{lb_pos.sz}]"
			if not opt_skip_errs: err_quit err
			err_warn err
			st_lb_err += 1

			# Fill lb_buff by SBs, collecting failed reads in hm_errs
			lbs = 0; hm_errs = {}
			src.setFilePos(lb_pos)
			for n in 0..<hm_sbc:
				try: lb_buff_read(sbs, n * opt_sbs, opt_sbs)
				except IOError: # add to hm_errs and skip over this SB
					err_warn &"  SB#{n} [{opt_sbs.sz}]" &
						&" read failed at {lb_pos + n * opt_sbs} B offset"
					hm_errs.incl(n.uint16)
					src.setFilePos(lb_pos + (n + 1) * opt_sbs)
					sbs = opt_sbs
				lbs += sbs
			if lbs == 0: continue
			src.setFilePos(lb_pos + lbs)

		# LB hash/skip check
		if hm_errs.card == 0: hash_block(lb_buff[0], lbs, hm_blk_new[0])
		else: zeroMem(hm_blk_new[0].addr, bh_md_len)

		st_lb_chk += 1
		if opt_file_hash: hash_update(hash_file, lb_buff, lbs)

		block lb_check_update:
			hm_bs = hm.readBytes(hm_blk, 0, hm_len)
			if hm_bs == hm_len and hash_same(hm_blk[0], hm_blk_new[0]):
				if opt_hm_hash: hash_update(hash_hm, hm_blk)
				if hm_errs.card == 0: break lb_check_update # broken LBs always get re-checked
			if opt_check: quit 1
			if hm_bs < hm_len: zeroMem(hm_blk[hm_bs].addr, hm_len - hm_bs)
			st_lb_upd += 1

			# SB checks/updates
			sbs = opt_sbs
			for n in 0..<hm_sbc:
				hm_bs = bh_md_len * (n + 1)
				if lbs < 0: zeroMem(hm_blk_new[hm_bs].addr, hm_len - hm_bs)
				if lbs <= 0: break
				lbs -= opt_sbs
				if lbs < 0: sbs += lbs # short SB at EOF
				st_sb_chk += 1

				if n.uint16 in hm_errs: # broken data - no check/copy
					zeroMem(hm_blk_new[hm_bs].addr, bh_md_len)
					st_sb_err += 1
					continue

				hash_block(lb_buff[opt_sbs * n], sbs, hm_blk_new[hm_bs])
				if hash_same(hm_blk[hm_bs], hm_blk_new[hm_bs]): continue
				st_sb_upd += 1

				if dst != nil:
					let sb_pos = lb_pos + opt_sbs * n
					if sb_pos != dst_pos: dst.setFilePos(sb_pos)
					if dst.writeBytes(lb_buff, opt_sbs * n, sbs) != sbs:
						err_quit &"Failed to replace dst-file SB {st_lb_chk}.{n} [at {sb_pos}]"
					dst_pos = sb_pos + sbs

			# HM block update
			if not opt_check_full:
				hm.setFilePos(hm_pos)
				if hm.writeBytes(hm_blk_new, 0, hm_len) != hm_len:
					err_quit &"Failed to replace hash-map-file block [at {hm_pos}]"
				if opt_hm_hash: hash_update(hash_hm, hm_blk_new)

		lb_pos += opt_lbs
		hm_pos += hm_len


	### Sync file sizes, return/print results

	if opt_check: quit 0
	if not opt_check_full:
		if hm_fd.ftruncate(hm.getFilePos.int) != 0:
			err_quit "Failed to truncate hash-map-file"

	var dst_sz_diff = ""
	if dst != nil:
		let
			src_sz = src.getFilePos
			dst_sz_bs = src_sz - dst_sz
		if dst_fd.ftruncate(src_sz.int) != 0 and not dst_is_dev:
			err_quit "Failed to truncate dst-file"
		if dst_sz_bs != 0:
			dst_sz_diff = if dst_sz_bs > 0: "+" else: "-"
			dst_sz_diff = &" [{dst_sz_diff}{abs(dst_sz_bs).sz}]"

	if opt_hm_hash: echo hash_finalize(hash_hm).toHex.toLowerAscii
	if opt_file_hash:
		if st_lb_err > 0 or st_sb_err > 0:
			err_warn "Resulting file-hash will be meaningless because of read errors"
		echo hash_finalize(hash_file).toHex.toLowerAscii
	if opt_verbose:
		var errs_lb = ""; var errs_sb = ""
		if opt_skip_errs:
			if st_lb_err > 0: errs_lb = &", {st_lb_err.nfmt} with read-errors"
			if st_sb_err > 0: errs_sb = &" + {st_sb_err.nfmt} errs"
		echo(
			&"Stats: {src.getFilePos.sz} file{dst_sz_diff} + {hm.getFilePos.sz} hash-map" &
			&" :: {(st_sb_upd * opt_sbs).sz} data diffs" )
		echo(
			&"  Blocks: {st_lb_chk.nfmt} LBs, {st_lb_upd.nfmt} mismatch{errs_lb} ::" &
			&" {st_sb_chk.nfmt} SBs checked, {st_sb_upd.nfmt} updated{errs_sb}" )

	if opt_check_full and st_lb_upd > 0: quit 1

when is_main_module: main(os.commandLineParams())
