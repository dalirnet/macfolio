.PHONY: build
build:
	sh dev.sh

.PHONY: release
release:
	sh dev.sh release

.PHONY: publish
publish:
	sh dev.sh publish

.PHONY: run
run: build
	killall Macfolio 2>/dev/null || true
	sleep 0.5
	open build/Macfolio.app

.PHONY: format
format:
	swift-format format -i -r --configuration .swift-format Sources

.PHONY: clean
clean:
	rm -rf build .build
