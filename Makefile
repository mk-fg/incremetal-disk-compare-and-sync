all: idcas

%: %.nim
	nim c -d:release -d:strip -d:lto_incremental --opt:speed $<

clean:
	rm -f idcas sparse_patch

test: idcas sparse_patch
	./test.sh

.SUFFIXES: # to disable built-in rules for %.c and such
