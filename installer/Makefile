.PHONY: build test run clean lint fmt check

build:
	python3 -m py_compile installer.py

test:
	python3 -m unittest -v

run:
	python3 installer.py --repo ..

clean:
	find . -type d -name __pycache__ -prune -exec rm -rf {} +

lint:
	python3 -m py_compile installer.py test_installer.py

fmt:
	python3 -m black installer.py test_installer.py

check: build lint test
