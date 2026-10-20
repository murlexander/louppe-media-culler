cask "louppe" do
  version "1.12.0"
  sha256 "2cd47cf21aaceeb0919b306a9b14093cb9f1ab1283dc932cc29d57eb3396c99e"

  url "https://github.com/murlexander/louppe-media-culler/releases/download/v#{version}/Louppe.zip",
      verified: "github.com/murlexander/louppe-media-culler/"
  name "Louppe"
  desc "Keyboard-first media culler"
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
