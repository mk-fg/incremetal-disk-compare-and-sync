all: idcas

idcas: idcas.nim
	nim c -d:release --opt:speed $<
	strip $@

clean:
	rm -f idcas

test: idcas
	bash -m test.sh

.SUFFIXES: # to disable built-in rules for %.c and such
