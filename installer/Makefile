.PHONY: build test run clean lint fmt check

build:
	cargo build --release

test:
	cargo test

run:
	cargo run --

clean:
	cargo clean

lint:
	cargo clippy --all-targets -- -D warnings

fmt:
	cargo fmt

check: fmt-check lint test

fmt-check:
	cargo fmt --check
