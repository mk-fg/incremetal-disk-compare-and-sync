all: idcas

idcas: idcas.nim
	nim c -d:release --opt:speed $<
	strip $@

clean:
	rm -f idcas

.SUFFIXES: # to disable built-in rules for %.c and such
