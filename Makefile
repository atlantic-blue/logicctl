# logicctl is driven by Accessibility and it captures the screen, so macOS holds a grant for each.
# Both grants key on the identity that signed the binary, so a build signed with another identity,
# or not signed at all, is a new program to macOS and loses both. The operator then gives them
# again by hand. `make sign` keeps them: it signs every build with the one identity this Mac
# granted. That name is never written into the repository. It lives in LOGICCTL_SIGN_IDENTITY, in
# the environment of this Mac.

.PHONY: sign

sign:
	@if [ -z "$$LOGICCTL_SIGN_IDENTITY" ]; then \
	  echo "logicctl: set LOGICCTL_SIGN_IDENTITY to the name of the identity that signs this build, and run make sign again"; \
	  exit 1; \
	fi
	swift build --configuration release
	binary="$$(swift build --configuration release --show-bin-path)/logicctl"; \
	codesign --force --sign "$$LOGICCTL_SIGN_IDENTITY" "$$binary" \
	  && codesign --verify --verbose "$$binary" \
	  && codesign -dv "$$binary"
