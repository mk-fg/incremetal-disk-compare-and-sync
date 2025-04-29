# Dockerfile to build normal and statically-linked run-anywhere idcas tool binaries.
# Command to make them into cwd: docker buildx build --output type=local,dest=. .
# Alpine linux is used as a slim and easy build-env. Static binary is ~4M in size.

FROM alpine:3.19 as build

RUN mkdir /build
WORKDIR /build

RUN apk add --no-cache gcc nim \
	musl-dev libc-dev openssl-dev openssl-libs-static pcre-dev

COPY idcas.nim .
RUN nim c -d:release -d:strip -d:lto_incremental --opt:speed -o:idcas.musl idcas.nim \
	&& ./idcas.musl --help >/dev/null
RUN nim c -d:release -d:strip -d:lto_incremental --opt:speed --passL:-static \
		-d:usePcreHeader --passL:/usr/lib/libpcre.a -o:idcas.static idcas.nim \
	&& ./idcas.static --help >/dev/null

FROM scratch as artifact
COPY --from=build /build/idcas.musl /build/idcas.static /
