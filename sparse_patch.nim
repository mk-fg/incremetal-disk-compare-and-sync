#? replace(sub = "\t", by = "  ")
#
# Debug build/run: nim c -w=on --hints=on -r sparse_patch.nim -h
# Final build: nim c -d:release --opt:size sparse_patch.nim && strip sparse_patch
# Usage info: ./sparse_patch -h

import std/[ parseopt, os, posix, strformat, strutils, re ]

let
	SEEK_DATA {.importc, nodecl.}: cint
	SEEK_HOLE {.importc, nodecl.}: cint
	SEEK_END {.importc, nodecl.}: cint

type coffset_t* {.importc: "off_t", header: "<sys/types.h>".} = clong
proc c_lseek(fd: FileHandle, offset: coffset_t, whence: cint):
	coffset_t {.importc: "lseek", header: "<unistd.h>".}

proc err_quit(s: string) = quit "ERROR: " & s

proc sz(v: int|int64): string =
	formatSize(v, includeSpace=true).replacef(re"(\.\d)\d+", "$1")

proc main_help(err="") =
	proc print(s: string) =
		let dst = if err == "": stdout else: stderr
		write(dst, s); write(dst, "\n")
	let app = getAppFilename().lastPathPart
	if err != "": print &"ERROR: {err}"
	print &"\nUsage: {app} [opts] src-sparse-file.patch dest-file"
	if err != "":
		print &"Run '{app} --help' for more information"
		quit 0
	print dedent(&"""

		Tool to efficiently copy non-sparse regions from src to dst file.
		Seeks over all sparse holes using linux-3.1+ whence=SEEK_DATA flag,
			without mapping all file blocks or extents using ioctl() syscalls.
		Supported options:

		 -v / --verbose
			Print number of bytes and separate data chunks found and copied.

		 -n / --dry-run
			Do not read/write data, only skim over mapped file chunks,
				printing their total count/size with -v/--verbose (if specified).
			Tool does not require destination file argument with this option.
		""")
	quit 0

proc main(argv: seq[string]) =
	var
		opt_src = ""
		opt_dst = ""
		opt_verbose = false
		opt_dry_run = false

	block cli_parser:
		var opt_last = ""
		proc opt_fmt(opt: string): string =
			if opt.len == 1: &"-{opt}" else: &"--{opt}"
		proc opt_empty_check =
			if opt_last == "": return
			main_help &"{opt_fmt(opt_last)} option unrecognized or requires a value"
		proc opt_set(k: string, v: string) =
			main_help &"Unrecognized option [ {opt_fmt(k)} = {v} ]"
		for t, opt, val in getopt(argv):
			case t
			of cmdEnd: break
			of cmdShortOption, cmdLongOption:
				if opt in ["h", "help"]: main_help()
				elif opt in ["v", "verbose"]: opt_verbose = true
				elif opt in ["n", "dry-run"]: opt_dry_run = true
				elif val == "": opt_empty_check(); opt_last = opt
				else: opt_set(opt, val)
			of cmdArgument:
				if opt_last != "": opt_set(opt_last, opt); opt_last = ""
				elif opt_src == "": opt_src = opt
				elif opt_dst == "": opt_dst = opt
				else: main_help(&"Unrecognized argument: {opt}")
		opt_empty_check()

		if opt_src == "": main_help "Missing src/dst file arguments"
		if opt_dry_run: opt_dst = ""
		elif opt_dst == "": main_help "Missing required destination-file argument"

	var
		src: File
		dst: FIle
		src_fd: FileHandle
		dst_fd: FileHandle
		pos: int64 = 0
		pos_to: int64 = 0
		buff_len: int = 65_536
		buff = newSeq[byte](buff_len)
		bs = 0
		st_bytes = 0
		st_chunks = 0

	if not src.open(opt_src):
		err_quit &"Failed to read-only open source file: {opt_src}"
	src_fd = src.getFileHandle()
	if opt_dst != "":
		dst_fd = open(opt_dst.cstring, O_CREAT or O_RDWR, 0o600)
		if dst_fd < 0 or not dst.open(dst_fd, fmReadWriteExisting):
			err_quit &"Failed to open destination file for writing: {opt_dst}"

	src.setFilePos(pos)
	while true:

		if pos_to >= 0 and pos == pos_to:
			pos = src_fd.c_lseek(pos, SEEK_DATA)
			if pos < 0: break # no more data
			st_chunks += 1
			pos_to = src_fd.c_lseek(pos, SEEK_HOLE)
			if pos_to < 0: pos_to = src_fd.c_lseek(0, SEEK_END)

		if opt_dry_run: bs = pos_to - pos
		else:
			let bs_max = min(buff_len, pos_to - pos)
			if bs_max == 0: break # shouldn't really get here
			src.setFilePos(pos)
			bs = src.readBytes(buff, 0, bs_max)
			if bs < bs_max and not src.endOfFile: err_quit &"Source-file read failed (at {pos})"
			dst.setFilePos(pos)
			if dst.writeBytes(buff, 0, bs) != bs: err_quit &"Dest-file write failed (at {pos})"

		pos += bs; st_bytes += bs

	if opt_verbose:
		echo &"Stats: copied {st_bytes.sz} in {st_chunks.intToStr.insertSep} chunks"

when is_main_module: main(os.commandLineParams())
