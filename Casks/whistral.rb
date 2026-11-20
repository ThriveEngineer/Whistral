cask "whistral" do
  version "0.3.1"
  sha256 "9138f545c8694a6d70fa7e7c11d17d145688d0b9ec99f9f9dda5fe36018fd2d7"

  url "https://github.com/ThriveEngineer/Whistral/releases/download/v#{version}/Whistral-#{version}.zip"
  name "Whistral"
  desc "Local, private dictation app for macOS powered by Whisper and Apple Intelligence"
  homepage "https://github.com/ThriveEngineer/Whistral"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma
  depends_on arch: :arm64

  app "Whistral.app"

  zap trash: [
    "~/Library/Application Support/Whistral",
    "~/Library/Caches/com.thrive.Whistral",
    "~/Library/Preferences/com.thrive.Whistral.plist",
  ]
end
