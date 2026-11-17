SENTRY_PACKAGE := tools/SentryNativeBreakpad
SENTRY_ARTIFACT := $(SENTRY_PACKAGE)/Artifacts/CSentryNative.xcframework/Info.plist

.PHONY: sentry-native
sentry-native: $(SENTRY_ARTIFACT)

$(SENTRY_ARTIFACT): $(SENTRY_PACKAGE)/build.sh
	$(SENTRY_PACKAGE)/build.sh

.PHONY: sentry-native-archive
sentry-native-archive: sentry-native
	$(SENTRY_PACKAGE)/archive.sh
