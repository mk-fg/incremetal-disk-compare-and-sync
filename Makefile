all: idcas

%: %.nim
	nim c -d:release --opt:speed $<
	strip $@

clean:
	rm -f idcas sparse_patch

test: idcas sparse_patch
	bash -m test.sh

.SUFFIXES: # to disable built-in rules for %.c and such
