qa:
	./scripts/qa_gate.sh

build:
	xcodebuild -project PETL.xcodeproj -scheme PETL -destination 'platform=iOS Simulator,name=iPhone 16' -quiet build

ci: qa build

.PHONY: qa build ci
