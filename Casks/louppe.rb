cask "louppe" do
  version "1.14.1"
  sha256 "d4766fe6272cd72868fe251c128e7d9b5c8a2aa12ef0c9d0bd4aec566acee157"

  url "https://github.com/murlexander/louppe-media-culler/releases/download/v#{version}/Louppe.zip",
      verified: "github.com/murlexander/louppe-media-culler/"
  name "Louppe"
  desc "Photo viewer and culler for local folders"
  homepage "https://louppe.eu/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Louppe.app"
end
