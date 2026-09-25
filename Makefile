# logicctl is driven by Accessibility and it captures the screen, so macOS holds a grant for each.
# Both grants key on the identity that signed the binary, so a build signed with another identity,
# or not signed at all, is a new program to macOS and loses both. The operator then gives them
# again by hand. `make sign` keeps them: it signs every build with the one identity this Mac
# granted. That name is never written into the repository. It lives in LOGICCTL_SIGN_IDENTITY, in
# the environment of this Mac.

.PHONY: sign accept

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

# `make accept PART=<n>` runs the live acceptance of one phase of the stories against the Logic on
# this Mac. It is the only run that drives the real application, so it carries the guards the
# pipeline cannot: the live suite is off unless this target turns it on, the binary it drives is
# the signed one, and a run that proves nothing says so rather than exiting zero. It builds nothing
# and signs nothing, because both grants key on the signature and a fresh build here would hand the
# suite a binary this Mac granted nothing to.

accept:
	@if [ -z "$(PART)" ]; then \
	  echo "logicctl: name the phase to accept, for example make accept PART=0"; \
	  exit 1; \
	fi
	@case "$(PART)" in \
	  0|1|2|3|4) ;; \
	  *) echo "logicctl: PART is a phase of the stories, 0 to 4, and $(PART) is not one of them"; \
	     exit 1;; \
	esac
	@binary="$$(swift build --configuration release --show-bin-path)/logicctl"; \
	if [ ! -x "$$binary" ]; then \
	  echo "logicctl: $$binary is not there, so run make sign and then run this again"; \
	  exit 1; \
	fi; \
	if ! codesign --verify "$$binary" >/dev/null 2>&1; then \
	  echo "logicctl: $$binary carries no signature, so run make sign and then run this again"; \
	  exit 1; \
	fi; \
	mkdir -p .build; \
	output=".build/accept-$(PART).txt"; \
	status=0; \
	LOGICCTL_LIVE=1 LOGICCTL_BINARY="$$binary" \
	  swift test --filter "Phase$(PART)LiveScenarios" > "$$output" 2>&1 || status=$$?; \
	cat "$$output"; \
	swiftTesting=$$(sed -n 's/.*Test run with \([0-9][0-9]*\) test.*/\1/p' "$$output" | tail -1); \
	xctest=$$(sed -n 's/.*Executed \([0-9][0-9]*\) test.*/\1/p' "$$output" | tail -1); \
	count=$$(( $${swiftTesting:-0} + $${xctest:-0} )); \
	echo "scenarios: $$count"; \
	if [ "$$count" -eq 0 ]; then \
	  echo "logicctl: no live scenario ran for phase $(PART), so this run proves nothing"; \
	  exit 1; \
	fi; \
	if [ "$$status" -ne 0 ]; then \
	  echo "logicctl: the live scenarios of phase $(PART) ran and the run went red"; \
	  exit "$$status"; \
	fi
