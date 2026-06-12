SCHEME = Fantastic Relay
APP = build/Build/Products/Debug/Fantastic Relay.app

.PHONY: project build run clean format format-check

project:
	xcodegen generate

build: project
	xcodebuild -project FantasticRelay.xcodeproj -scheme "$(SCHEME)" \
		-configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

run: build
	open "$(APP)"

clean:
	rm -rf build FantasticRelay.xcodeproj .build

format:
	swift-format format -i -r FantasticRelay

format-check:
	swift-format lint -r FantasticRelay
