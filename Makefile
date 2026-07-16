.PHONY: build test app run release dmg clean dev-cert

build:
	swift build

dev-cert:
	scripts/dev-cert.sh

test:
	swift test

app:
	scripts/make-app.sh debug

release:
	scripts/make-app.sh release

dmg:
	scripts/make-dmg.sh

run: app
	open build/cclimit.app

clean:
	rm -rf .build build dist
