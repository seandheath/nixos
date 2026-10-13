.PHONY: build test run clean lint fmt check

build:
	python3 -m py_compile installer.py

test:
	python3 -m unittest -v

# Through the package, which sets the keyboard, locale and timezone data paths.
run:
	nix run path:..#installer -- --repo ..

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

lint:
	python3 -m py_compile *.py

fmt:
	python3 -m black *.py

check: build lint test
