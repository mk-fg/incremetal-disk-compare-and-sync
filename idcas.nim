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


proc sz(v: int|int64): string =
	formatSize(v, includeSpace=true).replacef(re"(\.\d)\d+", "$1")

proc err_quit(s: string) = quit "ERROR: " & s

proc main_help(err="") =
	proc print(s: string) =
		let dst = if err == "": stdout else: stderr
		write(dst, s); write(dst, "\n")
	let app = getAppFilename().lastPathPart
	if err != "": print &"ERROR: {err}\n"
	print &"Usage: {app} [options] [src-file] dst-file"
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

		Hash-map file example is generated/updated as /mnt/usb-hdd/vm.img.bak{IDCAS_HM_EXT}
		Hash function used in hash-map-file is always 32B BLAKE2s from openssl.

		Input/output options:

			src-file
				Source file to read and copy/update both hash-map-file and dst-file from.
				Always read from start to finish in a single pass, so can also be a fifo pipe.
				If not specified, hash-map-file for dst-file is created/updated, nothing copied.

			dst-file
				Destination file to update in-place from src-file according to hash-map-file
					(if it exists), or otherwise do a full copy from src-file to it (if specified).
				If only one file argument is passed, it is assumed to be a dst-file
					to create/update hash-map-file for, instead of copying file contents in any way.

			-m/--hash-map hash-map-file
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
					and prints stats about amount of mismatches if -v/--verbose option is also used.

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

	block cli_parser:
		var opt_last = ""

		proc opt_empty_check =
			if opt_last == "": return
			let opt = if opt_last.len == 1: &"-{opt_last}" else: &"--{opt_last}"
			main_help(&"{opt} requires a value")

		proc opt_set(k: string, v: string) =
			if k in ["m", "hash-map"]: opt_hm_file = v
			elif k in ["B", "block-large"]: opt_lbs = parseInt(v)
			elif k in ["b", "block-small"]: opt_sbs = parseInt(v)
			else: quit &"BUG: no type info for option [ {k} = {v} ]"

		for t, opt, val in getopt(argv):
			case t
			of cmdEnd: break
			of cmdShortOption, cmdLongOption:
				if opt in ["h", "help"]: main_help()
				elif opt in ["M", "hash-map-update"]: opt_hm_update = true
				elif opt in ["v", "verbose"]: opt_verbose = true
				elif opt in ["c", "check"]: opt_check = true
				elif opt in ["C", "check-full"]: opt_check_full = true
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


	# Check if header matches all options, or replace it and zap the file
	block hm_hdr_check:
		var
			hdr_magic = IDCAS_MAGIC
			hdr_len = hdr_magic.len + 11
			hdr_str = repeat(' ', hdr_len)
			hdr_bs: uint32
		copyMem(hdr_str[0].addr, hdr_magic[0].addr, hdr_magic.len)
		hdr_bs = opt_lbs.uint32.htonl
		copyMem(hdr_str[hdr_magic.len + 1].addr, hdr_bs.addr, 4)
		hdr_bs = opt_sbs.uint32.htonl
		copyMem(hdr_str[hdr_magic.len + 6].addr, hdr_bs.addr, 4)
		let hdr_code = cast[seq[byte]](hdr_str)

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
	hm.setFilePos(4096) # for best alignment, if hm_blk_len is also n*4096


	# Scan and update file blocks
	var
		buff_lbs = newSeq[byte](opt_lbs)
		bs: int
		lbs_pos: int64 = 0
		sbs: int
		sbs_len: int
		eof = false

		bh_len: cint
		bh_res: cint
		bh_md = EVP_blake2s256()
		bh_md_len = 32

		hm_blk_sbc = int(opt_lbs / opt_sbs)
		hm_blk_len = bh_md_len + bh_md_len * hm_blk_sbc
		hm_blk_pos: int64 = hm.getFilePos
		hm_blk = newSeq[byte](hm_blk_len)
		hm_blk_new = newSeq[byte](hm_blk_len)
		hm_blk_zero = newSeq[byte](hm_blk_len)

		st_lb_chk = 0
		st_lb_upd = 0
		st_sb_chk = 0
		st_sb_upd = 0

	template hash_block(src: byte, src_len: cint, dst: byte, err_msg: string) =
		bh_res = EVP_Digest(src.addr, src_len, dst.addr, bh_len.addr, bh_md, nil)
		if bh_res != 1'i32 or bh_len != bh_md_len.cint: err_quit err_msg

	template hash_cmp(s1, s2: byte): bool =
		cmpMem(s1.addr, s2.addr, bh_md_len) == 0

	while not eof:
		bs = src.readBytes(buff_lbs, 0, opt_lbs)
		if bs < opt_lbs:
			eof = src.endOfFile
			if not eof: err_quit "File read failed"
			if bs == 0: continue

		hash_block( buff_lbs[0], bs.cint, hm_blk_new[0],
			&"Hashing failed on LB#{st_lb_chk} [{bs.sz} at {src.getFilePos-bs}]" )
		st_lb_chk += 1

		block lb_check_update:
			sbs = hm.readBytes(hm_blk, 0, hm_blk_len)
			if sbs == hm_blk_len and hash_cmp(hm_blk[0], hm_blk_new[0]): break
			if opt_check: quit 1
			if sbs < hm_blk_len: zeroMem(hm_blk[sbs].addr, hm_blk_len - sbs)
			st_lb_upd += 1

			sbs_len = opt_sbs
			for n in 0..<hm_blk_sbc:
				sbs = bh_md_len * (n + 1)
				if bs < 0: zeroMem(hm_blk_new[sbs].addr, hm_blk_len - sbs)
				if bs <= 0: break
				bs -= opt_sbs
				if bs < 0: sbs_len += bs # short SB at EOF

				hash_block( buff_lbs[opt_sbs * n], sbs_len.cint, hm_blk_new[sbs],
					&"Hashing failed on SB#{n} in LB#{st_lb_chk}" )
				while true: # hm_blk_zero is used to indicate missing SB - rehash if it pops-up
					if not hash_cmp(hm_blk_new[sbs], hm_blk_zero[0]): break
					hash_block( hm_blk_new[sbs], bh_md_len.cint, hm_blk_new[sbs],
						&"Re-hashing failed on SB#{n} in LB#{st_lb_chk}" )
				st_sb_chk += 1

				if hash_cmp(hm_blk[sbs], hm_blk_new[sbs]): continue
				st_sb_upd += 1

				if dst != nil:
					let sbs_pos = lbs_pos + opt_sbs * n
					dst.setFilePos(sbs_pos)
					if dst.writeBytes(buff_lbs, opt_sbs * n, sbs_len) != sbs_len:
						err_quit &"Failed to replace dst-file SB {st_lb_chk}.{n} [at {sbs_pos}]"

			if not opt_check_full:
				hm.setFilePos(hm_blk_pos)
				if hm.writeBytes(hm_blk_new, 0, hm_blk_len) != hm_blk_len:
					err_quit &"Failed to replace hash-map-file block [at {hm_blk_pos}]"

		lbs_pos += opt_lbs
		hm_blk_pos += hm_blk_len


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

	if opt_verbose:
		echo( &"Stats: {src.getFilePos.sz} file{dst_sz_diff}" &
			&" + {hm.getFilePos.sz} hash-map :: {st_lb_chk} LBs," &
			&" {st_lb_upd} updated :: {st_sb_chk} SBs compared," &
			&" {st_sb_upd} copied :: {(st_sb_upd * opt_sbs).sz} data diffs" )

	if opt_check_full and st_lb_upd > 0: quit 1

when is_main_module: main(os.commandLineParams())
