# logicctl is driven by Accessibility and it captures the screen, so macOS holds a grant for each.
# Both grants key on the identity that signed the binary, so a build signed with another identity,
# or not signed at all, is a new program to macOS and loses both. The operator then gives them
# again by hand. `make sign` keeps them: it signs every build with the one identity this Mac
# granted. That name is never written into the repository. It lives in LOGICCTL_SIGN_IDENTITY, in
# the environment of this Mac.

.PHONY: sign accept smoke

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
# pipeline cannot. The live suite is off unless this target turns it on. The binary it drives is
# the signed one, and this target builds nothing and signs nothing, because both grants key on the
# signature and a fresh build would carry neither.
#
# It counts the scenarios itself, from a line each scenario prints as it starts, and not from the
# summary of the test runner. The summary counts a scenario that was left out as a test that ran:
# adding the two live scenarios of phase 0 took a green pipeline from 92 tests to 97 while both of
# them were skipped. A phase where every scenario was left out would read there as a phase that
# passed against Logic.

accept:
	@if [ -z "$(PART)" ]; then \
	  echo "logicctl: name the phase to accept, for example make accept PART=0"; \
	  exit 1; \
	fi
	@case "$(PART)" in \
	  0|1|2|3|4|7) ;; \
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
	ran=$$(grep -c '^live scenario: ' "$$output" || true); \
	left=$$(grep -c ' skipped' "$$output" || true); \
	echo "scenarios: $$ran"; \
	if [ "$$ran" -eq 0 ]; then \
	  echo "logicctl: no live scenario ran for phase $(PART), so this run proves nothing"; \
	  exit 1; \
	fi; \
	if [ "$$left" -ne 0 ]; then \
	  echo "logicctl: phase $(PART) left $$left scenario out, so it is not accepted"; \
	  exit 1; \
	fi; \
	if [ "$$status" -ne 0 ]; then \
	  echo "logicctl: the live scenarios of phase $(PART) ran and the run went red"; \
	  exit "$$status"; \
	fi

# `make smoke PROJECT=<the copy Logic has open>` runs every command that reads Logic and changes
# nothing: status, tracks list, midi notes, automation list and plugins list. It prints the envelope
# of each one and it ends with a status that is not zero when any of them carries an error. The
# pipeline has no Logic, so this run is the only place the reads meet the real application, and its
# output goes into the pull request of the change.
#
# Logic holds the Mixer open and the Event List of the region open while it runs. A read walks to
# the project window, and the notes and the points of a region are in the Event List of that region.
# Measured on this Mac on 2026-09-25: a read of a window that is not open answers
# element_not_found and names the locator it looked for.
#
# PROJECT names the copy, because no command that reads Logic answers the path of the project it has
# open. The run resolves every link in that path and refuses any path outside /tmp, so it can never
# read the work of a person, and it then reads the window title and refuses a copy Logic does not
# have open.
#
# TRACK and REGION name the region the notes and the points come from. Both are 1 by default.
#
# It builds nothing and it signs nothing, for the reason `make accept` builds nothing: both grants
# key on the signature, so a build here would take them away and every read would answer nothing.

smoke:
	@if [ -z "$(PROJECT)" ]; then \
	  echo "logicctl: name the copy Logic has open, for example make smoke PROJECT=/tmp/logicctl-fixtures/F-T13.logicx"; \
	  exit 1; \
	fi
	@if ! command -v node >/dev/null 2>&1; then \
	  echo "logicctl: the smoke run is written in TypeScript, and this Mac has no node on the path"; \
	  exit 1; \
	fi
	@binary="$${LOGICCTL_BINARY:-.build/release/logicctl}"; \
	if [ ! -x "$$binary" ]; then \
	  echo "logicctl: $$binary is not there, so run make sign and then run this again"; \
	  exit 1; \
	fi; \
	if ! codesign --verify "$$binary" >/dev/null 2>&1; then \
	  echo "logicctl: $$binary carries no signature, so run make sign and then run this again"; \
	  exit 1; \
	fi; \
	PROJECT="$(PROJECT)" TRACK="$(TRACK)" REGION="$(REGION)" LOGICCTL_BINARY="$$binary" \
	  node --experimental-strip-types scripts/smoke.ts
