# Dockerfile to build statically-linked run-anywhere idcas tool binary (in current dir).
# Use with command: docker buildx build --output type=local,dest=. .
# Alpine linux is used as a slim and easy build-env. Resulting binary is ~3.2M in size.

FROM alpine:3.17 as build

RUN mkdir /build
WORKDIR /build

RUN apk add --no-cache gcc nim \
	musl-dev libc-dev openssl-dev openssl-libs-static pcre-dev

COPY idcas.nim .
RUN nim c -d:release --passL:-static --opt:speed \
		-d:usePcreHeader --passL:/usr/lib/libpcre.a idcas.nim \
	&& strip idcas && ./idcas --help >/dev/null

FROM scratch as artifact
COPY --from=build /build/idcas /
