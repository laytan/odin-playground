FROM alpine:latest

WORKDIR /odin

ENV PATH "$PATH:/usr/lib/llvm14/bin:/odin"

RUN apk add --no-cache git bash make clang14 llvm14-dev musl-dev linux-headers && \
    git clone --depth=1 https://github.com/odin-lang/Odin . && \
    LLVM_CONFIG=llvm14-config make

RUN adduser --disabled-password playground
USER playground
WORKDIR /home/playground
