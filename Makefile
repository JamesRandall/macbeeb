.PHONY: build test test-debug bench generate beebasm

BEEBASM := .build/beebasm/beebasm

build:
	swift build

# The CPU suites run billions of cycles, so test optimised. BeebAsm is
# built for the assembler tests.
test: $(BEEBASM)
	MACBEEB_BEEBASM=$(abspath $(BEEBASM)) swift test -c release -Xswiftc -enable-testing

test-debug:
	swift test

bench:
	swift run -c release beeb-bench

# Regenerate the 6502 state machine after changing Sources/M6502GenKit.
generate:
	swift run m6502-gen

# BeebAsm (ThirdParty/beebasm, a git submodule), for the app and tests.
# UNIVERSAL=1 builds for Intel too.
beebasm: $(BEEBASM)

$(BEEBASM): $(wildcard ThirdParty/beebasm/src/*.cpp ThirdParty/beebasm/src/*.h)
	@test -f ThirdParty/beebasm/src/main.cpp || git submodule update --init ThirdParty/beebasm
	mkdir -p $(dir $(BEEBASM))
	c++ -std=c++11 -O2 -w $(if $(UNIVERSAL),-arch arm64 -arch x86_64) -o $(BEEBASM) ThirdParty/beebasm/src/*.cpp
