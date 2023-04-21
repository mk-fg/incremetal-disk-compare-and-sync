#? replace(sub = "\t", by = "  ")
#
# Debug build/run: nim c -w=on --hints=on -r idcas.nim -h
# Final build: nim c -d:release idcas.nim && strip idcas
# Usage info: ./idcas -h

import strformat, strutils, parseopt, os, posix, re


{.passl: "-lcrypto"}

const IDCAS_MAGIC {.strdefine.} = "idcas-hash-map-1"
const IDCAS_HM_EXT {.strdefine.} = ".idcas" # default hashmap-file suffix
const IDCAS_LBS {.intdefine.} = 4161536 # <4M - large blocks to check for initial mismatches
const IDCAS_SBS {.intdefine.} = 32768 # 32K - blocks to compare/copy on LBS mismatch
# hash-map-file block = 32B lb-hash + 32B * (lbs / sbs) = neat 4K (w/ sbs=32K lbs=127*32K)

when IDCAS_LBS <= IDCAS_SBS or IDCAS_LBS %% IDCAS_SBS != 0:
	{.emit: "#error Compiled-in LB/SB size values mismatch - LBS must be larger and divisible by SBS".}


type EVP_MD = distinct pointer
proc EVP_blake2s256: EVP_MD {.importc, header: "<openssl/evp.h>".}
proc EVP_Digest(
	data: pointer, data_len: cint, digest: pointer, digest_len: ptr cint,
	md: EVP_MD, engine: pointer ): cint {.importc, header: "<openssl/evp.h>".}

proc EVP_blake2b512: EVP_MD {.importc, header: "<openssl/evp.h>".}
type EVP_MD_CTX = distinct pointer
proc EVP_MD_CTX_new: EVP_MD_CTX {.importc, header: "<openssl/evp.h>".}
proc EVP_MD_CTX_free(md_ctx: EVP_MD_CTX) {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestInit(
	md_ctx: EVP_MD_CTX, md: EVP_MD ): cint {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestUpdate( md_ctx: EVP_MD_CTX,
	data: pointer, data_len: cint ): cint {.importc, header: "<openssl/evp.h>".}
proc EVP_DigestFinal( md_ctx: EVP_MD_CTX,
	digest: pointer, digest_len: ptr cint ): cint {.importc, header: "<openssl/evp.h>".}


proc sz(v: int|int64): string =
	formatSize(v, includeSpace=true).replacef(re"(\.\d)\d+", "$1")

proc err_quit(s: string) = quit "ERROR: " & s

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
				elif val == "": opt_empty_check(); opt_last = opt
				else: opt_set(opt, val)
			of cmdArgument:
				if opt_last != "": opt_set(opt_last, opt); opt_last = ""
				elif opt_src == "": opt_src = opt
				elif opt_dst == "": opt_dst = opt
				else: main_help(&"Unrecognized argument: {opt}")
		opt_empty_check()

		if opt_src == "" and opt_dst == "":
			main_help("Missing src/dst file arguments")
		elif opt_dst == "":
			opt_dst = opt_src; opt_src = ""
		if opt_hm_file == "":
			opt_hm_file = &"{opt_dst}{IDCAS_HM_EXT}"
		if opt_lbs <= opt_sbs or opt_lbs %% opt_sbs != 0:
			main_help("Large/small block sizes mismatch - must be divisible")
		if (opt_check or opt_check_full) and opt_src != "":
			main_help("Check options only work with a single file argument")


	# Open hash-map / source / destination files

	var
		src: File
		dst: File # nil if only one file is specified
		dst_fd: FileHandle
		dst_sz: int64
		hm: File
		hm_fd: FileHandle

	hm_fd = open(opt_hm_file.cstring, O_CREAT or O_RDWR, 0o600)
	if hm_fd < 0 or not hm.open(hm_fd, fmReadWriteExisting):
		err_quit &"Failed to open/create hash-map-file: {opt_hm_file}"
	defer: hm.close

	if opt_src != "":
		if not src.open(opt_src):
			err_quit &"Failed to open src-file: {opt_src}"
		dst_fd = open(opt_dst.cstring, O_CREAT or O_RDWR, 0o600)
		if dst_fd < 0 or not dst.open(dst_fd, fmReadWriteExisting):
			err_quit &"Failed to open dst-file: {opt_dst}"
		dst_sz = dst.getFileSize

	else:
		if not src.open(opt_dst):
			err_quit &"Failed to open dst-file: {opt_dst}"

	defer: src.close; dst.close


	# State vars get reused for all blocks

	var
		lbs: int
		sbs: int
		eof = false
		lb_buff = newSeq[byte](opt_lbs)
		lb_pos: int64 = 0
		dst_pos: int64 = -1

		bh_len: cint
		bh_res: cint
		bh_md = EVP_blake2s256()
		bh_md_len = 32

		hm_bs: int
		hm_sbc = int(opt_lbs / opt_sbs)
		hm_len = bh_md_len + bh_md_len * hm_sbc
		hm_pos: int64 = clamp(hm_len, 64, 4096)
		hm_blk = newSeq[byte](hm_len)
		hm_blk_new = newSeq[byte](hm_len)
		hm_blk_zero = newSeq[byte](hm_len)

		hdr_magic = IDCAS_MAGIC
		hdr_len = hdr_magic.len + 11
		hdr_pad = newSeq[byte](hm_pos - hdr_len) # block alignment, if works with hm_len/fs

		hash_md = EVP_blake2b512()
		hash_md_len = 64
		hash_hm: EVP_MD_CTX
		hash_file: EVP_MD_CTX

		st_lb_chk = 0
		st_lb_upd = 0
		st_sb_chk = 0
		st_sb_upd = 0

	template hash_init(ctx: EVP_MD_CTX) =
		ctx = EVP_MD_CTX_new()
		bh_res = EVP_DigestInit(ctx, hash_md)
		if bh_res != 1'i32: err_quit "hash init failed"
	template hash_update(ctx: EVP_MD_CTX, buff: seq[byte], bs=0) =
		bh_res = EVP_DigestUpdate(
			ctx, buff[0].addr, cint(if bs != 0: bs else: buff.len) )
		if bh_res != 1'i32: err_quit "hash update failed"
	proc hash_finalize(ctx: EVP_MD_CTX): string =
		result = newString(hash_md_len)
		bh_res = EVP_DigestFinal(ctx, result[0].addr, bh_len.addr)
		if bh_res != 1'i32 or bh_len != hash_md_len.cint:
			err_quit "hash finalize failed"
		EVP_MD_CTX_free(ctx)
	if opt_hm_hash: hash_init(hash_hm)
	if opt_file_hash: hash_init(hash_file)


	# Check if header matches all options, or replace it and zap the file

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
			hdr_file == hdr_code: break

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


	# Scan and update file blocks

	template hash_block(src: byte, src_len: cint, dst: byte, err_msg: string) =
		bh_res = EVP_Digest(src.addr, src_len, dst.addr, bh_len.addr, bh_md, nil)
		if bh_res != 1'i32 or bh_len != bh_md_len.cint: err_quit err_msg
	template hash_cmp(s1, s2: byte): bool =
		cmpMem(s1.addr, s2.addr, bh_md_len) == 0

	while not eof:
		lbs = src.readBytes(lb_buff, 0, opt_lbs)
		if lbs < opt_lbs:
			eof = src.endOfFile
			if not eof: err_quit "File read failed"
			if lbs == 0: continue

		hash_block( lb_buff[0], lbs.cint, hm_blk_new[0],
			&"Hashing failed on LB#{st_lb_chk} [{lbs.sz} at {src.getFilePos-lbs}]" )
		st_lb_chk += 1
		if opt_file_hash: hash_update(hash_file, lb_buff, lbs)

		block lb_check_update:
			hm_bs = hm.readBytes(hm_blk, 0, hm_len)
			if hm_bs == hm_len and hash_cmp(hm_blk[0], hm_blk_new[0]):
				if opt_hm_hash: hash_update(hash_hm, hm_blk)
				break
			if opt_check: quit 1
			if hm_bs < hm_len: zeroMem(hm_blk[hm_bs].addr, hm_len - hm_bs)
			st_lb_upd += 1

			sbs = opt_sbs
			for n in 0..<hm_sbc:
				hm_bs = bh_md_len * (n + 1)
				if lbs < 0: zeroMem(hm_blk_new[hm_bs].addr, hm_len - hm_bs)
				if lbs <= 0: break
				lbs -= opt_sbs
				if lbs < 0: sbs += lbs # short SB at EOF

				hash_block( lb_buff[opt_sbs * n], sbs.cint, hm_blk_new[hm_bs],
					&"Hashing failed on SB#{n} in LB#{st_lb_chk}" )
				while true: # hm_blk_zero is used to indicate missing SB - rehash if it pops-up
					if not hash_cmp(hm_blk_new[hm_bs], hm_blk_zero[0]): break
					hash_block( hm_blk_new[hm_bs], bh_md_len.cint, hm_blk_new[hm_bs],
						&"Re-hashing failed on SB#{n} in LB#{st_lb_chk}" )
				st_sb_chk += 1

				if hash_cmp(hm_blk[hm_bs], hm_blk_new[hm_bs]): continue
				st_sb_upd += 1

				if dst != nil:
					let sb_pos = lb_pos + opt_sbs * n
					if sb_pos != dst_pos: dst.setFilePos(sb_pos)
					if dst.writeBytes(lb_buff, opt_sbs * n, sbs) != sbs:
						err_quit &"Failed to replace dst-file SB {st_lb_chk}.{n} [at {sb_pos}]"
					dst_pos = sb_pos + sbs

			if not opt_check_full:
				hm.setFilePos(hm_pos)
				if hm.writeBytes(hm_blk_new, 0, hm_len) != hm_len:
					err_quit &"Failed to replace hash-map-file block [at {hm_pos}]"
				if opt_hm_hash: hash_update(hash_hm, hm_blk_new)

		lb_pos += opt_lbs
		hm_pos += hm_len


	# Sync file sizes, return/print results

	if opt_check: quit 0
	if not opt_check_full:
		if hm_fd.ftruncate(hm.getFilePos.int) != 0:
			err_quit &"Failed to truncate hash-map-file"

	var dst_sz_diff = ""
	if dst != nil:
		let
			src_sz = src.getFilePos
			dst_sz_bs = src_sz - dst_sz
		if dst_fd.ftruncate(src_sz.int) != 0:
			err_quit &"Failed to truncate dst-file"
		if dst_sz_bs != 0:
			dst_sz_diff = if dst_sz_bs > 0: "+" else: "-"
			dst_sz_diff = &" [{dst_sz_diff}{abs(dst_sz_bs).sz}]"

	if opt_hm_hash: echo hash_finalize(hash_hm).toHex.toLowerAscii
	if opt_file_hash: echo hash_finalize(hash_file).toHex.toLowerAscii
	if opt_verbose:
		echo( &"Stats: {src.getFilePos.sz} file{dst_sz_diff}" &
			&" + {hm.getFilePos.sz} hash-map :: {st_lb_chk} LBs," &
			&" {st_lb_upd} updated :: {st_sb_chk} SBs compared," &
			&" {st_sb_upd} copied :: {(st_sb_upd * opt_sbs).sz} data diffs" )

	if opt_check_full and st_lb_upd > 0: quit 1

when is_main_module: main(os.commandLineParams())
