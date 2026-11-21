cask "whistral" do
  version "0.3.3"
  sha256 "27c2f5f8ee4c79c595a371d7fd6ae529865b1d8e68ceeb689193dbe3d24be040"

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
