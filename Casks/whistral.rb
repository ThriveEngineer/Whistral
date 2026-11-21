cask "whistral" do
  version "0.3.6"
  sha256 "653d32d194515a6fa2e83b09ff36bf746d268169f41e9b11b5670a10b3b083c0"

  url "https://github.com/ThriveEngineer/Whistral/releases/download/v#{version}/Whistral-#{version}.zip"
  name "Whistral"
  desc "Local, private dictation powered by Whisper and Apple Intelligence"
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
