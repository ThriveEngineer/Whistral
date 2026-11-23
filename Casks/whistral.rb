cask "whistral" do
  version "0.5.0"
  sha256 "3cd82ef05a279ee6dec24a25fcfc294e0de84d6b3810d853d192eac7ec790bc1"

  url "https://github.com/ThriveEngineer/Whistral/releases/download/v#{version}/Whistral-#{version}.zip"
  name "Whistral"
  desc "Local, private dictation powered by on-device speech models and Apple Intelligence"
  homepage "https://github.com/ThriveEngineer/Whistral"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Whistral.app"

  zap trash: [
    "~/Library/Application Support/Whistral",
    "~/Library/Caches/com.thrive.Whistral",
    "~/Library/Preferences/com.thrive.Whistral.plist",
  ]
end
