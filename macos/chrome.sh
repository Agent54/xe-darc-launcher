# new method!!:
/Users/jan/Library/Application\ Support/dev.xe.darc/Helium.app/Contents/MacOS/Helium \
  --headless=new \
  --user-data-dir="/Users/jan/Library/Application Support/dev.xe.darc/beat" \
  --no-first-run \
  --disable-extensions \
  --install-isolated-web-app-from-file=/Users/jan/Library/Application\ Support/dev.xe.darc/darc.swbn \
  --screenshot=/dev/null --no-first-run about:blank

mkdir -p /Users/jan/Library/Application\ Support/dev.xe.darc/beat/Default/
cp -f /Users/jan/Dev/xe/darc-launcher/macos/Preferences.json /Users/jan/Library/Application\ Support/dev.xe.darc/beat/Default/Preferences.json

/Users/jan/Library/Application\ Support/dev.xe.darc/Helium.app/Contents/MacOS/Helium \
  --user-data-dir="/Users/jan/Library/Application Support/dev.xe.darc/beat" \
  --remote-debugging-port=9226 \
  --disable-features=CADisplayLinkInBrowser \
  --remote-allow-origins=https://localhost:5194 \
  --no-default-browser-check \
  --silent-launch \
  --no-first-run \
  --headless \
  --flag-switches-begin --enable-features=AppShimNotificationAttribution,DesktopPWAsAdditionalWindowingControls,DesktopPWAsLinkCapturingWithScopeExtensions,DesktopPWAsSubApps,IsolatedWebAppDevMode,IsolatedWebApps,OverscrollEffectOnNonRootScrollers,UseAdHocSigningForWebAppShims,PwaNavigationCapturing,UnframedIwa,WebAppBorderless,WebAppPredictableAppUpdating --disable-features=CADisplayLinkInBrowser --flag-switches-end \
  --install-isolated-web-app-from-file=/Users/jan/Library/Application\ Support/dev.xe.darc/darc.swbn
