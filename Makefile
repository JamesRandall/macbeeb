.PHONY: build test test-debug bench generate

build:
	swift build

# The CPU suites run billions of cycles, so test optimised.
test:
	swift test -c release -Xswiftc -enable-testing

test-debug:
	swift test

bench:
	swift run -c release beeb-bench

# Regenerate the 6502 state machine after changing Sources/M6502GenKit.
generate:
	swift run m6502-gen
