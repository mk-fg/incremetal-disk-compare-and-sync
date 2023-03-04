#? replace(sub = "\t", by = "  ")
#
# Debug build/run: nim c -w=on --hints=on -o=idcas -r idcas.nim -h
# Final build: nim c -d:production -o=idcas idcas.nim && strip idcas
# Usage info: ./idcas -h

import strformat, strutils, parseopt, os


{.passl: "-lcrypto"}

const IDCAS_HM_EXT {.strdefine.} = ".idcas" # default hashmap-file suffix
const IDCAS_LBS {.strdefine.} = 4194304 # large blocks to check for initial mismatches
const IDCAS_SBS {.strdefine.} = 4096 # blocks to compare/copy on LBS mismatch


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
				Exit with error code and message if -m/--hash-map file does not exists.
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

	# XXX: actually implement this

when is_main_module: main(os.commandLineParams())
