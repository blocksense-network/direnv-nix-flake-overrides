SHELL := /bin/bash

.PHONY: lint test

lint:
	shellcheck plugin/flake-overrides.bash

test:
	pytest -q
