set shell := ["bash", "-cu"]

default:
    mise tasks

setup:
    mise install
    mise run root:install
    mise run tui:install

fmt:
    mise run zig:fmt
    mise run ts:format

test:
    mise run test

build:
    mise run zig:build

run:
    mise run tui:start

smoke:
    mise run smoke

release:
    mise run release:check
