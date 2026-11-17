cask "macmate" do
  version "1.1.0"
  sha256 "72859d0a98fcc0c597b69f2b854a8d10ae7a79090f1a9e224f03d06968c9efd2"

  url "https://github.com/PriyanshuGeTRekT/macos-all-in-one-tool/releases/download/v#{version}/MacMate-#{version}.zip"
  name "MacMate"
  desc "All-in-one menu bar utility for battery, windows, mouse, audio and cleanup"
  homepage "https://priyanshugetrekt.github.io/macos-all-in-one-tool/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "MacMate.app"

  zap trash: [
    "~/Library/Application Support/MacMate",
    "~/Library/Caches/com.macmate.app",
    "~/Library/HTTPStorages/com.macmate.app",
    "~/Library/Preferences/com.macmate.app.plist",
  ]

  caveats <<~EOS
    MacMate is not notarized by Apple, so macOS blocks it the first time it opens.
    To allow it, open MacMate once, then go to
      System Settings › Privacy & Security
    scroll down and click "Open Anyway" next to MacMate.

    Window tiling, the ⌥Tab switcher, and the mouse and keyboard features need
    Accessibility access. Turn MacMate on in
      System Settings › Privacy & Security › Accessibility
  EOS
end
