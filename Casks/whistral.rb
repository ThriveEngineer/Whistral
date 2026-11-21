cask "whistral" do
  version "0.4.0"
  sha256 "4c874fb25c19f449ec49e037f70aa6dccb41d9d6afad8b7b8bfa0297d4fea1dd"

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
