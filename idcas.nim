#? replace(sub = "\t", by = "  ")
#
# Debug build/run: nim c -w=on --hints=on -o=idcas -r idcas.nim -h
# Final build: nim c -d:production -o=idcas idcas.nim && strip idcas
# Usage info: ./idcas -h

import strformat, strutils, parseopt, os, posix


{.passl: "-lcrypto"}

const IDCAS_MAGIC {.strdefine.} = "idcas-hash-map-1 "
const IDCAS_HM_EXT {.strdefine.} = ".idcas" # default hashmap-file suffix
const IDCAS_LBS {.intdefine.} = 4194304 # large blocks to check for initial mismatches
const IDCAS_SBS {.intdefine.} = 32768 # blocks to compare/copy on LBS mismatch


### File readBytes/writeBytes helpers

proc arr_str(src: openArray[byte], length=0, offset=0): string =
	let len_max = src.len - offset
	result = newString(if length > 0 and length <= len_max: length else: len_max)
	copyMem(result[offset].addr, src[offset].unsafeAddr, result.len)

proc str_arr(src: string, length=0, offset=0): seq[byte] =
	let len_max = src.len - offset
	result = newSeq[byte](if length > 0 and length <= len_max: length else: len_max)
	copyMem(result[0].addr, src[offset].unsafeAddr, result.len)

proc beuint32_arr(n: int): array[4, byte] = cast[array[4, byte]](n.uint32.htonl)
proc arr_beuint32(src: openArray[byte], offset=0): int =
	result = int(src[offset]) shl 24 or int(src[offset+1]) shl 16 or int(src[offset+2]) shl 8 or int(src[offset+3])

proc beuint32_splice(n: int, s: openArray[byte], offset=0) =
	if s.len - offset < 4:
		raise newException(ValueError, &"Out-of-bounds splice ({offset}/{s.len-4})")
	var n_beuint32 = n.uint32.htonl
	copyMem(s[offset].unsafeAddr, n_beuint32.unsafeAddr, 4)


### OpenSSL BLAKE2s hash wrapper

type EVP_MD = distinct pointer
proc EVP_blake2s256: EVP_MD {.importc, header: "<openssl/evp.h>".}
proc EVP_Digest(
	data: cstring, data_len: cint, digest: cstring, digest_len: ptr cint,
	md: EVP_MD, engine: pointer ): cint {.importc, header: "<openssl/evp.h>".}

type DigestError = object of CatchableError

var # these should always be used immediately anyway
	blake2_digest = newString(32)
	blake2_len: cint = 0
	md = EVP_blake2s256()
proc blake2(data: string): string =
	let res = EVP_Digest( data.cstring, data.len.cint,
		blake2_digest.cstring, blake2_len.addr, md, nil )
	if res != 1'i32 or blake2_len != 32'i32:
		raise newException(DigestError, "EVP_Digest call failed")
	return blake2_digest


### Main routine

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
				% {app} vm.img /mnt/ext-hdd/vm.img
			## ...VM runs and stuff changes in vm.img after this

			## Make date/time-suffixed btrfs copy-on-write snapshot of vm.img backup
				% cp --reflink /mnt/ext-hdd/vm.img{{,.$(date -Is)}}
			## Efficiently update vm.img file, overwriting only changed blocks in-place
				% {app} vm.img /mnt/ext-hdd/vm.img
			## ...and so on - block devices or sparse files can also be used here

		Hash-map file in this example is generated/updated as /mnt/ext-hdd/vm.img{IDCAS_HM_EXT}
		Hash function used in hash-map-file is always 32B BLAKE2s from openssl.

		Input/output options:

			src-file
				Source file to read and copy/update both hash-map-file and dst-file from.
				Always read from start to finish in a single pass, so can also be a fifo pipe.
				If not specified, hash-map-file for dst-file is created/updated, nothing copied.

			dst-file
				Destination file to update in-place, according to hash-map-file,
					if it exists, or otherwise fully copy from src-file (if specified).
				If only one file argument is specified,
					it is assumed to be a dst-file to create/update hash-map-file for,
					instead of copying file contents in any way.

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
				Default: {IDCAS_LBS} bytes (compile-time IDCAS_LBS option)

			-b/--block-small <bytes>
				Smallest block size to compare and store hash for in hash-map-file.
				Hashes for these blocks are loaded and compared/updated when
					large-block hash doesn't match, to find which of those to update.
				Default: {IDCAS_SBS} bytes (compile-time IDCAS_SBS option)
		""")
	quit 0

proc main(argv: seq[string]) =
	var
		opt_hm_file = ""
		opt_hm_update = false
		opt_lbs = IDCAS_LBS
		opt_sbs = IDCAS_SBS
		opt_src = ""
		opt_dst = ""

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
			else: quit(&"BUG: no type info for option [ {k} = {v} ]")

		for t, opt, val in getopt(argv):
			case t
			of cmdEnd: break
			of cmdShortOption, cmdLongOption:
				if opt in ["h", "help"]: main_help()
				elif opt in ["M", "hash-map-update"]: opt_hm_update = true
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
		if opt_lbs %% opt_sbs != 0:
			main_help("Large/small block sizes mismatch - must be divisible")


	var
		# XXX: src
		dst: FIle
		hm: FIle

	let hm_fd = open(opt_hm_file, O_CREAT or O_RDWR, 0o600)
	if hm_fd < 0 or not hm.open(hm_fd, fmReadWriteExisting):
		quit(&"ERROR: Failed to open/create hash-map-file: {opt_hm_file}")
	defer: hm.close()
	if not dst.open(opt_dst): # XXX: open for writing if src is used
		quit(&"ERROR: Failed to open dst-file: {opt_dst}")
	defer: dst.close()


	# Check if header matches all options, or replace it and zap the file
	block hm_header_skip:
		hm.setFilePos(0)

		const
			n_magic = IDCAS_MAGIC.len
			n_hdr = n_magic + 10
		var hdr_code = str_arr(IDCAS_MAGIC & "=lbs =sbs ")
		beuint32_splice(opt_lbs, hdr_code, n_magic)
		beuint32_splice(opt_lbs, hdr_code, n_magic + 5)

		block hm_header_match:
			var hdr_file: array[n_hdr, byte]
			if hm.readBytes(hdr_file, 0, n_hdr) == n_hdr and
				hdr_file == hdr_code: break
			if opt_hm_update:
				quit(&"ERROR: hash-map-file header mismatch: {opt_hm_file}")

			block hm_header_replace:
				hm.setFilePos(0)
				if hm.writeBytes(hdr_code, 0, n_hdr) == n_hdr and
					ftruncate(hm_fd, n_hdr) == 0: break
				quit(&"ERROR: Failed to replace hash-map-file header: {opt_hm_file}")


	block copy_blocks:
		var
			buff_lbs = newSeq[byte](opt_lbs)
			buff_sbs = newSeq[byte](opt_sbs)
			bs = 0
		while true:
			bs = dst.readBytes(buff_lbs, 0, opt_lbs)
			if bs < opt_lbs:
				if dst.endOfFile: break
				else: quit("ERROR: File read failed")

		# XXX: read blocks, write to a file
		# XXX: maybe use mmap'ed hash-map-file
		# XXX: actually implement this

when is_main_module: main(os.commandLineParams())
