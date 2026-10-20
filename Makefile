# Local helpers (macOS with Xcode). CI does the same in .github/workflows/build.yml.

project:
	xcodegen generate

open: project
	open RepositoryManager.xcodeproj

test:
	mkdir -p build
	xcrun swiftc -parse-as-library -o build/SealedBoxTests tests/SealedBoxTests.swift RepositoryManager/Services/SealedBox.swift
	build/SealedBoxTests
	xcrun swiftc -parse-as-library -o build/MergeCheckTests tests/MergeCheckTests.swift RepositoryManager/Services/MergeCheck.swift
	build/MergeCheckTests

.PHONY: project open test
